import Foundation
import YouTubeKit

enum YouTubeAudioImportProgress: Sendable {
    case extractingLocal
    case extractingRemote
    case downloading(Double)
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
    private static let preferredExtensions: [YouTubeKit.FileExtension] = [.m4a, .mp4, .aac, .mp3]

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
        let destination = directory
            .appendingPathComponent("\(videoID)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        progress(.downloading(0))
        try await download(extraction.stream.url, to: destination, progress: progress)
        Log.transcription.notice(
            "YouTube audio imported videoID=\(videoID) remoteFallback=\(extraction.usedRemote) ext=\(ext)"
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
    }

    private static func extractAudioStream(
        videoID: String,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws -> ExtractedAudio {
        progress(.extractingLocal)
        do {
            let local = YouTube(videoID: videoID, methods: [.local])
            let localStreams = try await local.streams
            if let stream = preferredAudioStream(from: localStreams) {
                let title = (try? await local.metadata)?.title
                return ExtractedAudio(stream: stream, title: sanitizedTitle(title), usedRemote: false)
            }
            if await isLivestream(local) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            Log.transcription.warning("YouTube local extraction returned no audio-only stream, trying remote fallback")
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
            if let stream = preferredAudioStream(from: remoteStreams) {
                let title = (try? await remote.metadata)?.title
                return ExtractedAudio(stream: stream, title: sanitizedTitle(title), usedRemote: true)
            }
            if await isLivestream(remote) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            throw YouTubeAudioImportError.noAudioStream
        } catch let error as YouTubeAudioImportError {
            throw error
        } catch YouTubeKitError.liveStreamError {
            throw YouTubeAudioImportError.liveStreamUnsupported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubeAudioImportError.extractionFailed(error.localizedDescription)
        }
    }

    private static func preferredAudioStream(from streams: [YouTubeStream]) -> YouTubeStream? {
        let audioOnly = streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack }
        for fileExtension in preferredExtensions {
            if let match = audioOnly
                .filter({ $0.fileExtension == fileExtension })
                .max(by: lowerAudioBitrate) {
                return match
            }
        }
        if let native = audioOnly.filter(\.isNativelyPlayable).max(by: lowerAudioBitrate) {
            return native
        }
        return audioOnly.max(by: lowerAudioBitrate)
    }

    private static func lowerAudioBitrate(_ lhs: YouTubeStream, _ rhs: YouTubeStream) -> Bool {
        audioBitrate(lhs) < audioBitrate(rhs)
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

    private static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = true

        let delegate = DownloadProgressDelegate { fraction in
            progress(.downloading(fraction))
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw YouTubeAudioImportError.downloadFailed(status: http.statusCode)
        }
        try FileIO.moveReplacingDestination(from: tempURL, to: destination)
        progress(.downloading(1))
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
