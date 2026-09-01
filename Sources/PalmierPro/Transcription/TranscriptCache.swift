import CryptoKit
import Foundation

struct LocalTranscriptCacheConfiguration: Codable, Equatable, Sendable {
    var languageCode: String?
    var speakerCount: Int?

    static let automatic = LocalTranscriptCacheConfiguration(languageCode: nil, speakerCount: nil)

    var identity: String {
        let language = languageCode?.lowercased() ?? "auto"
        let speakers = speakerCount.map(String.init) ?? "auto-1-4"
        return "language=\(language)|speakers=\(speakers)"
    }
}

/// Disk + memory cache for local and cloud transcripts, keyed by file identity so edits invalidate naturally.
actor TranscriptCache {
    static let shared = TranscriptCache()
    static let localPipelineSchemaVersion = 6
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Transcripts", isDirectory: true)

    private var memory: [String: TranscriptionResult] = [:]
    private static let memoryMax = 4

    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        // When a locale is forced, bypass the cache — locale variants must not overwrite the auto-detected entry.
        if let preferredLocale {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, preferredLocale: preferredLocale, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, preferredLocale: preferredLocale, sourceRange: range)
        }
        // Cache full transcripts only; windowed calls filter the cached result for consistency.
        let key = Self.key(for: url, variant: .localLatest)
        let full: TranscriptionResult
        if let key, let cached = cached(key) {
            full = cached
        } else {
            full = isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url)
                : try await Transcription.transcribe(fileURL: url)
            if let key { store(full, key: key) }
        }
        return range.map { Self.filter(full, to: $0) } ?? full
    }

    /// Stores a complete local transcript produced by the Workbench so the
    /// editor caption flow reuses the same words, speakers, and timestamps.
    func storeLocalTranscript(
        _ result: TranscriptionResult,
        for url: URL,
        configuration: LocalTranscriptCacheConfiguration = .automatic,
        publishAsLatest: Bool = true
    ) {
        guard let exactKey = Self.key(for: url, variant: .local(configuration)) else { return }
        store(result, key: exactKey)
        if publishAsLatest,
           let latestKey = Self.key(for: url, variant: .localLatest),
           latestKey != exactKey {
            store(result, key: latestKey)
        }
    }

    func cachedLocalTranscript(
        for url: URL,
        range: ClosedRange<Double>? = nil,
        configuration: LocalTranscriptCacheConfiguration? = nil
    ) -> TranscriptionResult? {
        let variant: CacheVariant = configuration.map(CacheVariant.local) ?? .localLatest
        guard let key = Self.key(for: url, variant: variant), let result = cached(key) else { return nil }
        return range.map { Self.filter(result, to: $0) } ?? result
    }

    nonisolated static func hasCachedOnDisk(for url: URL) -> Bool {
        guard let key = key(for: url, variant: .localLatest) else { return false }
        return FileManager.default.fileExists(atPath: diskURL(key).path)
    }

    /// Disk-only read
    nonisolated static func cachedOnDisk(for url: URL) -> TranscriptionResult? {
        guard let key = key(for: url, variant: .localLatest),
              let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(TranscriptionResult.self, from: data)
    }

    static func filter(_ r: TranscriptionResult, to range: ClosedRange<Double>) -> TranscriptionResult {
        let segments = r.segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        let words = r.words.filter { w in
            guard let s = w.start, let e = w.end else { return false }
            return e > range.lowerBound && s < range.upperBound
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: r.language,
            words: words,
            segments: segments,
            asrEngine: r.asrEngine
        )
    }

    func cachedCloudTranscript(
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) -> TranscriptionResult? {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return nil }
        return cached(key)
    }

    func hasCachedCloudTranscript(
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) -> Bool {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return false }
        return memory[key] != nil || FileManager.default.fileExists(atPath: Self.diskURL(key).path)
    }

    func storeCloudTranscript(
        _ result: TranscriptionResult,
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return }
        store(result, key: key)
    }

    /// Drop in-memory entries so a disk clear isn't shadowed by the memory cache.
    func clearMemory() { memory.removeAll() }

    private func cached(_ key: String) -> TranscriptionResult? {
        if let r = memory[key] { return r }
        guard let data = try? Data(contentsOf: Self.diskURL(key)),
              let r = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else { return nil }
        remember(r, key: key)
        return r
    }

    private func store(_ result: TranscriptionResult, key: String) {
        remember(result, key: key)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: Self.diskURL(key))
        }
    }

    private func remember(_ result: TranscriptionResult, key: String) {
        if memory.count >= Self.memoryMax { memory.removeAll() }
        memory[key] = result
    }

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    nonisolated static func localPipelineFingerprint(
        configuration: LocalTranscriptCacheConfiguration
    ) -> String {
        let whisperFallbackModelID = LocalModelManager.preferredWhisperFallbackModelID()
        let relevant: [LocalModelID] = [
            .qwen3ASR17B8Bit,
            .parakeetTDT06Bv3,
            whisperFallbackModelID,
            .spokenLanguageID,
            .forcedAligner,
            .sileroVAD,
            .sortformerDiarization,
        ]
        let revisions = relevant.compactMap { id in
            LocalModelManager.catalog.first(where: { $0.id == id }).map {
                "\(id.rawValue)@\($0.revision)"
            }
        }.joined(separator: "|")
        return "schema=\(localPipelineSchemaVersion)|whisper=\(whisperFallbackModelID.rawValue)|\(configuration.identity)|\(revisions)"
    }

    private static func key(for url: URL, variant: CacheVariant) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let base = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        let identity = variant.prefix.map { "\($0)|\(base)" } ?? base
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private enum CacheVariant {
        case local(LocalTranscriptCacheConfiguration)
        case localLatest
        case cloud(range: ClosedRange<Double>?, language: String?)

        var prefix: String? {
            switch self {
            case .local(let configuration):
                return "local|\(TranscriptCache.localPipelineFingerprint(configuration: configuration))"
            case .localLatest:
                return "local-latest|\(TranscriptCache.localPipelineFingerprint(configuration: .automatic))"
            case .cloud(let range, let language):
                let lang = language ?? "auto"
                guard let range else { return "cloud|\(lang)|full" }
                return String(format: "cloud|%@|%.3f...%.3f", lang, range.lowerBound, range.upperBound)
            }
        }
    }

}
