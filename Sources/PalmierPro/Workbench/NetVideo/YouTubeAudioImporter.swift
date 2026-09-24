import Foundation
import YouTubeKit

struct YouTubeAudioDownloadProgress: Sendable, Equatable {
    /// Set when the response includes a total length. Nil for chunked responses.
    var fraction: Double?
    var bytesWritten: Int64
}

enum YouTubeAudioImportProgress: Sendable {
    case extractingLocal
    case extractingRemote
    case downloading(YouTubeAudioDownloadProgress)
}

struct YouTubeAudioImportResult: Sendable {
    let fileURL: URL
    let videoID: String
    let title: String?
    let usedRemoteFallback: Bool
}

enum YouTubeAudioImportError: LocalizedError {
    case invalidURL
    case liveStreamUnsupported
    case noAudioStream
    case downloadFailed(status: Int)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Paste a public YouTube watch, Shorts, or youtu.be URL."
        case .liveStreamUnsupported:
            "Live streams are not supported. Use a finished public video."
        case .noAudioStream:
            "No downloadable audio-only stream was found for this video."
        case .downloadFailed(let status):
            "YouTube refused the audio download (HTTP \(status)). The video may be private, region-locked, or age-restricted."
        case .extractionFailed(let message):
            message
        }
    }
}

enum YouTubeAudioImporter {
    private typealias YouTubeStream = YouTubeKit.Stream

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// itag 140 is the native AAC m4a track at about 128 kbps.
    private static let preferredAudioItag = 140
    private static let targetAudioBitrate = 128_000
    /// Prefer a compact native stream while retaining playable fallbacks.
    private static let maxPreferredAudioBitrate = 160_000
    private static let requestIdleTimeout: TimeInterval = 60
    private static let minimumResourceTimeout: TimeInterval = 900
    private static let maximumResourceTimeout: TimeInterval = 2 * 60 * 60
    /// Assumed length when the container size is not known yet. Used only to size the resource timeout.
    private static let assumedDuration: TimeInterval = 12 * 60 * 60
    /// A slow but still progressing transfer can take much longer than 15 minutes.
    private static let throttleFloorBytesPerSecond = 32.0 * 1024.0

    static func importAudio(
        from rawURL: String,
        into directory: URL,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws -> YouTubeAudioImportResult {
        guard let videoID = YouTubeURL.videoID(from: rawURL) else {
            throw YouTubeAudioImportError.invalidURL
        }

        try Task.checkCancellation()
        let extraction = try await extractAudioStream(videoID: videoID, progress: progress)
        try Task.checkCancellation()

        let ext = filenameExtension(for: extraction.stream)
        let bitrate = audioBitrate(extraction.stream)
        let destination = directory
            .appendingPathComponent("\(videoID)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Log.transcription.notice(
            "YouTube audio selected videoID=\(videoID) ext=\(ext) bitrate=\(bitrate) selection=\(extraction.selection) remoteFallback=\(extraction.usedRemote)"
        )
        progress(.downloading(YouTubeAudioDownloadProgress(fraction: nil, bytesWritten: 0)))
        do {
            try await download(
                extraction.stream.url,
                bitrate: bitrate,
                to: destination,
                progress: progress
            )
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let bytesWritten = fileSize(at: destination)
        progress(.downloading(YouTubeAudioDownloadProgress(fraction: 1, bytesWritten: bytesWritten)))
        Log.transcription.notice(
            "YouTube audio imported videoID=\(videoID) remoteFallback=\(extraction.usedRemote) ext=\(ext) bitrate=\(bitrate) bytes=\(bytesWritten)"
        )
        return YouTubeAudioImportResult(
            fileURL: destination,
            videoID: videoID,
            title: extraction.title,
            usedRemoteFallback: extraction.usedRemote
        )
    }

    private struct ExtractedAudio: Sendable {
        let stream: YouTubeStream
        let title: String?
        let usedRemote: Bool
        /// "itag-140", "m4a-near-128kbps", or "m4a-low".
        let selection: String
    }

    private struct SelectedAudio: Sendable {
        let stream: YouTubeStream
        let selection: String
    }

    private static func extractAudioStream(
        videoID: String,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws -> ExtractedAudio {
        progress(.extractingLocal)
        var localFallback: ExtractedAudio?
        do {
            let local = YouTube(videoID: videoID, methods: [.local])
            let localStreams = try await local.streams
            if let selected = preferredAudioStream(from: localStreams, allowFallback: false) {
                let title = (try? await local.metadata)?.title
                return ExtractedAudio(
                    stream: selected.stream,
                    title: sanitizedTitle(title),
                    usedRemote: false,
                    selection: selected.selection
                )
            }
            if await isLivestream(local) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            if let selected = preferredAudioStream(from: localStreams, allowFallback: true) {
                let title = (try? await local.metadata)?.title
                localFallback = ExtractedAudio(
                    stream: selected.stream,
                    title: sanitizedTitle(title),
                    usedRemote: false,
                    selection: selected.selection
                )
            }
            Log.transcription.warning("YouTube local extraction returned no compact m4a, trying remote fallback")
        } catch let error as YouTubeAudioImportError {
            throw error
        } catch YouTubeKitError.liveStreamError {
            throw YouTubeAudioImportError.liveStreamUnsupported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.transcription.warning("YouTube local extraction failed: \(error.localizedDescription)")
        }

        try Task.checkCancellation()
        progress(.extractingRemote)
        do {
            let remote = YouTube(videoID: videoID, methods: [.remote])
            let remoteStreams = try await remote.streams
            if let selected = preferredAudioStream(from: remoteStreams) {
                if let localFallback,
                   selected.selection.hasSuffix("fallback"),
                   (localFallback.stream.isNativelyPlayable || !selected.stream.isNativelyPlayable),
                   audioBitrate(localFallback.stream) > 0,
                   audioBitrate(localFallback.stream) <= audioBitrate(selected.stream) {
                    return localFallback
                }
                let title = (try? await remote.metadata)?.title
                return ExtractedAudio(
                    stream: selected.stream,
                    title: sanitizedTitle(title),
                    usedRemote: true,
                    selection: selected.selection
                )
            }
            if await isLivestream(remote) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            if let localFallback { return localFallback }
            throw YouTubeAudioImportError.noAudioStream
        } catch let error as YouTubeAudioImportError {
            throw error
        } catch YouTubeKitError.liveStreamError {
            throw YouTubeAudioImportError.liveStreamUnsupported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if let localFallback { return localFallback }
            throw YouTubeAudioImportError.extractionFailed(error.localizedDescription)
        }
    }

    /// Prefer itag 140, then a similarly compact m4a. Keep a playable fallback
    /// when a video exposes only higher-bitrate or differently packaged audio.
    private static func preferredAudioStream(
        from streams: [YouTubeStream],
        allowFallback: Bool = true
    ) -> SelectedAudio? {
        let m4a = streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension == .m4a }
        if let match = m4a.stream(withITag: preferredAudioItag) {
            return SelectedAudio(stream: match, selection: "itag-140")
        }

        let listedBitrates = m4a.map { audioBitrate($0) }.sorted().map(String.init).joined(separator: ",")
        Log.transcription.notice("YouTube itag 140 missing; m4a bitrates=\(listedBitrates)")

        let nearTarget = m4a.filter { stream in
            let rate = audioBitrate(stream)
            return rate > 0 && rate <= maxPreferredAudioBitrate
        }
        if let match = nearTarget.min(by: closerToTargetBitrate) {
            let selection = audioBitrate(match) + 32_000 >= targetAudioBitrate ? "m4a-near-128kbps" : "m4a-low"
            return SelectedAudio(stream: match, selection: selection)
        }
        guard allowFallback else { return nil }
        let audioOnly = streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack }
        let playable = audioOnly.filter(\.isNativelyPlayable)
        if let match = playable.min(by: lowerBitrate) {
            return SelectedAudio(stream: match, selection: "playable-fallback")
        }
        if let match = audioOnly.min(by: lowerBitrate) {
            return SelectedAudio(stream: match, selection: "audio-fallback")
        }
        return nil
    }

    private static func lowerBitrate(_ lhs: YouTubeStream, _ rhs: YouTubeStream) -> Bool {
        let left = audioBitrate(lhs)
        let right = audioBitrate(rhs)
        if left <= 0 { return false }
        if right <= 0 { return true }
        return left < right
    }

    private static func closerToTargetBitrate(_ lhs: YouTubeStream, _ rhs: YouTubeStream) -> Bool {
        abs(audioBitrate(lhs) - targetAudioBitrate) < abs(audioBitrate(rhs) - targetAudioBitrate)
    }

    private static func audioBitrate(_ stream: YouTubeStream) -> Int {
        stream.averageBitrate ?? stream.bitrate ?? 0
    }

    private static func isLivestream(_ video: YouTube) async -> Bool {
        guard let livestreams = try? await video.livestreams else { return false }
        return !livestreams.isEmpty
    }

    private static func filenameExtension(for stream: YouTubeStream) -> String {
        let raw = stream.fileExtension.rawValue
        if raw.isEmpty || raw == YouTubeKit.FileExtension.unknown.rawValue {
            return "m4a"
        }
        return raw
    }

    private static func sanitizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bytes are unknown before the response, so the timeout is sized for a long native-m4a
    /// download at about 32 KB/s instead of a flat 15 minutes.
    private static func resourceTimeout(forBitrate bitrate: Int) -> TimeInterval {
        let bitsPerSecond = bitrate > 0 ? bitrate : targetAudioBitrate
        let estimatedBytes = Double(bitsPerSecond) / 8.0 * assumedDuration
        let timeout = estimatedBytes / throttleFloorBytesPerSecond * 1.5
        return min(maximumResourceTimeout, max(minimumResourceTimeout, timeout))
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func download(
        _ url: URL,
        bitrate: Int,
        to destination: URL,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestIdleTimeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestIdleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout(forBitrate: bitrate)
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = true

        let delegate = DownloadProgressDelegate { snapshot in
            progress(.downloading(snapshot))
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw YouTubeAudioImportError.downloadFailed(status: http.statusCode)
        }
        try FileIO.moveReplacingDestination(from: tempURL, to: destination)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (YouTubeAudioDownloadProgress) -> Void

    init(onProgress: @escaping @Sendable (YouTubeAudioDownloadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : nil
        onProgress(YouTubeAudioDownloadProgress(fraction: fraction, bytesWritten: totalBytesWritten))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
