import AVFoundation
import Foundation

/// Sequential 16 kHz mono CAF shared by transcription, waveforms, and playback.
enum DecodedAudioCache {
    static let cache = DiskCache(named: "DecodedAudio")
    static let sampleRate: Double = 16_000

    private static let gate = AsyncSemaphore(value: 2)
    private static let inflight = InflightDecode()

    static var pcmOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Returns a file whose sample timeline matches ASR (`sampleIndex / 16_000`).
    @concurrent
    static func file(for sourceURL: URL, range: ClosedRange<Double>? = nil) async throws -> URL {
        if !requiresSequentialDecode(sourceURL) {
            guard let range else { return sourceURL }
            return try await cachedSlice(of: sourceURL, range: range)
        }
        let full = try await cachedFullDecode(of: sourceURL)
        guard let range else { return full }
        return try await cachedSlice(of: full, range: range)
    }

    static func requiresSequentialDecode(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "wav", "caf", "aiff", "aif": false
        default: true
        }
    }

    private static func cachedFullDecode(of sourceURL: URL) async throws -> URL {
        let tag = await DiskCache.loadSizeMtimeTag(for: sourceURL)
        let name = cacheFileName(sourceURL: sourceURL, tag: tag, range: nil)
        return try await inflight.value(for: name) {
            try await decodeFullFile(sourceURL: sourceURL, fileName: name)
        }
    }

    private static func cachedSlice(of sourceURL: URL, range: ClosedRange<Double>) async throws -> URL {
        let tag = await DiskCache.loadSizeMtimeTag(for: sourceURL)
        let name = cacheFileName(sourceURL: sourceURL, tag: tag, range: range)
        return try await inflight.value(for: name) {
            try await slicePCM(sourceURL: sourceURL, range: range, fileName: name)
        }
    }

    private static func decodeFullFile(sourceURL: URL, fileName: String) async throws -> URL {
        let destination = cache.directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try await gate.wait()
        defer { Task { await gate.signal() } }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let tempURL = cache.directory.appendingPathComponent(".writing-\(UUID().uuidString).caf")
        var audioFile: AVAudioFile?
        do {
            try await AudioTrackReader.read(
                from: sourceURL,
                outputSettings: pcmOutputSettings
            ) { pcm in
                try Task.checkCancellation()
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: tempURL,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcm)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        guard audioFile != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTrackReader.ReadError.readFailed("No audio samples in \(sourceURL.lastPathComponent)")
        }
        try FileIO.moveReplacingDestination(from: tempURL, to: destination)
        return destination
    }

    private static func slicePCM(sourceURL: URL, range: ClosedRange<Double>, fileName: String) async throws -> URL {
        let destination = cache.directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try await gate.wait()
        defer { Task { await gate.signal() } }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw AudioTrackReader.ReadError.readFailed("Empty audio in \(sourceURL.lastPathComponent)")
        }
        let startFrame = AVAudioFramePosition((range.lowerBound * sampleRate).rounded(.down))
        let endFrame = AVAudioFramePosition((range.upperBound * sampleRate).rounded(.up))
        let clampedStart = min(max(0, startFrame), file.length)
        let clampedEnd = min(max(clampedStart + 1, endFrame), file.length)
        file.framePosition = clampedStart
        let frameCount = AVAudioFrameCount(clampedEnd - clampedStart)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioTrackReader.ReadError.readFailed("Could not allocate PCM slice")
        }
        try file.read(into: buffer, frameCount: frameCount)

        let tempURL = cache.directory.appendingPathComponent(".writing-\(UUID().uuidString).caf")
        do {
            let out = try AVAudioFile(
                forWriting: tempURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try out.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try FileIO.moveReplacingDestination(from: tempURL, to: destination)
        return destination
    }

    private static func cacheFileName(sourceURL: URL, tag: String, range: ClosedRange<Double>?) -> String {
        let stem = sourceURL.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        var name = "\(stem)_\(tag)_16kmono"
        if let range {
            let startMs = Int((range.lowerBound * 1000).rounded(.down))
            let endMs = Int((range.upperBound * 1000).rounded(.up))
            name += "_\(startMs)_\(endMs)"
        }
        return name + ".caf"
    }
}

private actor InflightDecode {
    private var tasks: [String: Task<URL, Error>] = [:]

    func value(for key: String, produce: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task.detached { try await produce() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
