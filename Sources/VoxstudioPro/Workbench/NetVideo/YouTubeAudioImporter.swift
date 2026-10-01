import AVFoundation
import Foundation
import YouTubeKit

struct YouTubeAudioDownloadProgress: Sendable, Equatable {
    enum Component: Sendable, Equatable {
        case videoTrack
        case audioTrack
    }

    /// Set when the response includes a total length. Nil for chunked responses.
    var fraction: Double?
    var bytesWritten: Int64
    var component: Component? = nil
}

enum YouTubeAudioImportProgress: Sendable {
    case extractingLocal
    case extractingRemote
    case downloading(YouTubeAudioDownloadProgress)
    case preparing
}

struct YouTubeVideoQualityList: Sendable, Equatable {
    /// Distinct playable resolutions, highest first.
    var resolutions: [Int]
    var defaultResolution: Int
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
    case noVideoStream
    case downloadFailed(status: Int, media: String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Paste a public YouTube watch, Shorts, or youtu.be URL."
        case .liveStreamUnsupported:
            "Live streams are not supported. Use a finished public video."
        case .noAudioStream:
            "No downloadable audio-only stream was found for this video."
        case .noVideoStream:
            "No downloadable video was found for this link."
        case .downloadFailed(let status, let media):
            "YouTube refused the \(media) download (HTTP \(status)). The video may be private, region-locked, or age-restricted."
        case .extractionFailed(let message):
            message
        }
    }
}

enum YouTubeAudioImporter {
    private typealias YouTubeStream = YouTubeKit.Stream

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// Prefer 1080p when the video publishes that tier.
    static let preferredVideoResolution = 1_080
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

    /// Playable H.264 resolutions for this video. Local extraction first.
    static func listVideoQualities(from rawURL: String) async throws -> YouTubeVideoQualityList {
        guard YouTubeURL.videoID(from: rawURL) != nil else {
            throw YouTubeAudioImportError.invalidURL
        }
        let resolved = try await resolveVideoStreams(from: rawURL, progress: { _ in })
        let resolutions = videoResolutions(from: resolved.streams)
        guard let defaultResolution = defaultVideoResolution(from: resolutions) else {
            throw YouTubeAudioImportError.noVideoStream
        }
        return YouTubeVideoQualityList(resolutions: resolutions, defaultResolution: defaultResolution)
    }

    /// Downloads an mp4 that already contains an audio track.
    /// `resolution` nil uses 1080p, else the highest tier below it, else the lowest available.
    static func importVideo(
        from rawURL: String,
        into directory: URL,
        resolution: Int?,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws -> YouTubeAudioImportResult {
        guard let videoID = YouTubeURL.videoID(from: rawURL) else {
            throw YouTubeAudioImportError.invalidURL
        }
        let resolved = try await resolveVideoStreams(from: rawURL, progress: progress)
        let resolutions = videoResolutions(from: resolved.streams)
        let target = selectedVideoResolution(requested: resolution, available: resolutions)
        guard let target else { throw YouTubeAudioImportError.noVideoStream }
        guard let video = preferredVideoStream(from: resolved.streams, resolution: target) else {
            throw YouTubeAudioImportError.noVideoStream
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent("\(videoID)-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        if video.includesVideoAndAudioTrack {
            progress(.downloading(YouTubeAudioDownloadProgress(fraction: nil, bytesWritten: 0)))
            do {
                try await download(video.url, bitrate: videoBitrate(video), to: destination, media: "video", progress: progress)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            let bytesWritten = fileSize(at: destination)
            progress(.downloading(YouTubeAudioDownloadProgress(fraction: 1, bytesWritten: bytesWritten)))
            Log.transcription.notice(
                "YouTube video imported videoID=\(videoID) resolution=\(target) muxed=false remoteFallback=\(resolved.usedRemote) bytes=\(bytesWritten)"
            )
            return YouTubeAudioImportResult(
                fileURL: destination,
                videoID: videoID,
                title: resolved.title,
                usedRemoteFallback: resolved.usedRemote
            )
        }

        guard let audio = preferredMuxAudioStream(from: resolved.streams) else {
            throw YouTubeAudioImportError.noAudioStream
        }
        let videoPart = directory
            .appendingPathComponent("\(videoID)-\(UUID().uuidString)-v")
            .appendingPathExtension("mp4")
        let audioPart = directory
            .appendingPathComponent("\(videoID)-\(UUID().uuidString)-a")
            .appendingPathExtension(filenameExtension(for: audio))
        defer {
            try? FileManager.default.removeItem(at: videoPart)
            try? FileManager.default.removeItem(at: audioPart)
        }
        do {
            progress(.downloading(YouTubeAudioDownloadProgress(fraction: nil, bytesWritten: 0, component: .videoTrack)))
            try await download(video.url, bitrate: videoBitrate(video), to: videoPart, media: "video") { update in
                guard case .downloading(let snapshot) = update else { return }
                progress(.downloading(YouTubeAudioDownloadProgress(
                    fraction: snapshot.fraction,
                    bytesWritten: snapshot.bytesWritten,
                    component: .videoTrack
                )))
            }
            try Task.checkCancellation()
            progress(.downloading(YouTubeAudioDownloadProgress(fraction: nil, bytesWritten: 0, component: .audioTrack)))
            try await download(audio.url, bitrate: audioBitrate(audio), to: audioPart, media: "audio") { update in
                guard case .downloading(let snapshot) = update else { return }
                progress(.downloading(YouTubeAudioDownloadProgress(
                    fraction: snapshot.fraction,
                    bytesWritten: snapshot.bytesWritten,
                    component: .audioTrack
                )))
            }
            try Task.checkCancellation()
            progress(.preparing)
            try await mux(videoURL: videoPart, audioURL: audioPart, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let bytesWritten = fileSize(at: videoPart) + fileSize(at: audioPart)
        progress(.downloading(YouTubeAudioDownloadProgress(fraction: 1, bytesWritten: bytesWritten)))
        Log.transcription.notice(
            "YouTube video imported videoID=\(videoID) resolution=\(target) muxed=true remoteFallback=\(resolved.usedRemote) downloadBytes=\(bytesWritten) outputBytes=\(fileSize(at: destination))"
        )
        return YouTubeAudioImportResult(
            fileURL: destination,
            videoID: videoID,
            title: resolved.title,
            usedRemoteFallback: resolved.usedRemote
        )
    }

    static func defaultVideoResolution(from resolutions: [Int]) -> Int? {
        let unique = Set(resolutions.filter { $0 > 0 })
        guard !unique.isEmpty else { return nil }
        if unique.contains(preferredVideoResolution) { return preferredVideoResolution }
        if let below = unique.filter({ $0 < preferredVideoResolution }).max() { return below }
        return unique.min()
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

    private struct ResolvedVideo: Sendable {
        let streams: [YouTubeStream]
        let title: String?
        let usedRemote: Bool
    }

    private static func resolveVideoStreams(
        from rawURL: String,
        progress: @escaping @Sendable (YouTubeAudioImportProgress) -> Void
    ) async throws -> ResolvedVideo {
        guard let videoID = YouTubeURL.videoID(from: rawURL) else {
            throw YouTubeAudioImportError.invalidURL
        }
        progress(.extractingLocal)
        var localFallback: ResolvedVideo?
        do {
            let local = YouTube(videoID: videoID, methods: [.local])
            let streams = try await local.streams
            if !videoResolutions(from: streams).isEmpty {
                let title = (try? await local.metadata)?.title
                return ResolvedVideo(streams: streams, title: sanitizedTitle(title), usedRemote: false)
            }
            if await isLivestream(local) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            if !streams.isEmpty {
                let title = (try? await local.metadata)?.title
                localFallback = ResolvedVideo(streams: streams, title: sanitizedTitle(title), usedRemote: false)
            }
            Log.transcription.warning("YouTube local extraction returned no playable H.264 video, trying remote fallback")
        } catch let error as YouTubeAudioImportError {
            throw error
        } catch YouTubeKitError.liveStreamError {
            throw YouTubeAudioImportError.liveStreamUnsupported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.transcription.warning("YouTube local video extraction failed: \(error.localizedDescription)")
        }

        try Task.checkCancellation()
        progress(.extractingRemote)
        do {
            let remote = YouTube(videoID: videoID, methods: [.remote])
            let streams = try await remote.streams
            if !videoResolutions(from: streams).isEmpty {
                let title = (try? await remote.metadata)?.title
                return ResolvedVideo(streams: streams, title: sanitizedTitle(title), usedRemote: true)
            }
            if await isLivestream(remote) {
                throw YouTubeAudioImportError.liveStreamUnsupported
            }
            if let localFallback { return localFallback }
            throw YouTubeAudioImportError.noVideoStream
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

    private static func selectedVideoResolution(requested: Int?, available: [Int]) -> Int? {
        if let requested { return available.contains(requested) ? requested : nil }
        return defaultVideoResolution(from: available)
    }

    /// Descending playable H.264 resolutions. Progressive and video-only both count.
    private static func videoResolutions(from streams: [YouTubeStream]) -> [Int] {
        let hasMuxAudio = preferredMuxAudioStream(from: streams) != nil
        let values = streams.compactMap { stream -> Int? in
            guard isImportableVideo(stream), let resolution = stream.videoResolution, resolution > 0 else { return nil }
            if stream.includesAudioTrack {
                guard isAAC(stream.audioCodec) else { return nil }
            } else if !hasMuxAudio {
                return nil
            }
            return resolution
        }
        return Array(Set(values)).sorted(by: >)
    }

    private static func preferredVideoStream(from streams: [YouTubeStream], resolution: Int) -> YouTubeStream? {
        let matches = streams.filter { isImportableVideo($0) && $0.videoResolution == resolution }
        let progressive = matches.filter { $0.includesVideoAndAudioTrack && isAAC($0.audioCodec) }
        if let match = progressive.max(by: { videoBitrate($0) < videoBitrate($1) }) {
            return match
        }
        return matches.filter { !$0.includesAudioTrack }.max(by: { videoBitrate($0) < videoBitrate($1) })
    }

    private static func isImportableVideo(_ stream: YouTubeStream) -> Bool {
        stream.includesVideoTrack
            && stream.isNativelyPlayable
            && stream.fileExtension == .mp4
            && isH264(stream.videoCodec)
    }

    private static func isH264(_ codec: YouTubeKit.VideoCodec?) -> Bool {
        switch codec {
        case .avc1: true
        default: false
        }
    }

    private static func isAAC(_ codec: YouTubeKit.AudioCodec?) -> Bool {
        switch codec {
        case .mp4a: true
        default: false
        }
    }

    private static func videoBitrate(_ stream: YouTubeStream) -> Int {
        stream.averageBitrate ?? stream.bitrate ?? 0
    }

    private static func preferredMuxAudioStream(from streams: [YouTubeStream]) -> YouTubeStream? {
        let aac = streams.filter {
            $0.includesAudioTrack && !$0.includesVideoTrack
                && $0.fileExtension == .m4a
                && $0.isNativelyPlayable
                && isAAC($0.audioCodec)
        }
        return preferredAudioStream(from: aac)?.stream
    }

    private static func mux(videoURL: URL, audioURL: URL, to destination: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw YouTubeAudioImportError.noVideoStream
        }
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw YouTubeAudioImportError.extractionFailed("Could not combine the video and audio tracks.")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        guard videoRange.duration.isNumeric, videoRange.duration.seconds > 0,
              audioRange.duration.isNumeric, audioRange.duration.seconds > 0 else {
            throw YouTubeAudioImportError.extractionFailed("Could not combine the video and audio tracks.")
        }
        try compositionVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )
        try? FileManager.default.removeItem(at: destination)
        do {
            try await exportComposition(composition, preset: AVAssetExportPresetPassthrough, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destination)
            try await exportComposition(composition, preset: AVAssetExportPresetHighestQuality, to: destination)
        }
    }

    private static func exportComposition(
        _ composition: AVMutableComposition,
        preset: String,
        to destination: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw YouTubeAudioImportError.extractionFailed("Could not combine the video and audio tracks.")
        }
        try await session.export(to: destination, as: .mp4)
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

    static func download(
        _ url: URL,
        bitrate: Int,
        to destination: URL,
        media: String = "audio",
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

        let delegate = DownloadProgressDelegate(destination: destination, media: media) { snapshot in
            progress(.downloading(snapshot))
        }
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let media: String
    private let onProgress: @Sendable (YouTubeAudioDownloadProgress) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var downloadResult: Result<Void, Error>?

    init(
        destination: URL,
        media: String,
        onProgress: @escaping @Sendable (YouTubeAudioDownloadProgress) -> Void
    ) {
        self.destination = destination
        self.media = media
        self.onProgress = onProgress
    }

    /// Installed before the task starts; subsequent callbacks use a serial delegate queue.
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
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
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw YouTubeAudioImportError.downloadFailed(status: response.statusCode, media: media)
            }
            // URLSession deletes this temporary file after the callback returns.
            try FileIO.moveReplacingDestination(from: location, to: destination)
            downloadResult = .success(())
        } catch {
            downloadResult = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else {
            continuation.resume(with: downloadResult ?? .failure(
                YouTubeAudioImportError.extractionFailed("Download completed without a file.")
            ))
        }
    }
}
