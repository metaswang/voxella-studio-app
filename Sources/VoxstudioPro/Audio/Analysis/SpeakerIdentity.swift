import AVFoundation
#if BUNDLED_SPEECH
import SpeechVAD
#endif

/// Identifies voices across files so the same speaker gets the same label everywhere.
enum SpeakerIdentity {
    static let cache = DiskCache(named: "SpeakerVoices")

    struct Turn {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// Merges consecutive same-speaker words (gaps under 1 s) into turns.
    static func turns(from transcript: TranscriptionResult) -> [Turn] {
        var turns: [Turn] = []
        for word in transcript.words {
            guard let speaker = word.speaker, let start = word.start, let end = word.end else { continue }
            if let last = turns.last, last.speaker == speaker, start - last.end < 1.0 {
                turns[turns.count - 1] = Turn(speaker: speaker, start: last.start, end: end)
            } else {
                turns.append(Turn(speaker: speaker, start: start, end: end))
            }
        }
        return turns
    }

    /// Similarity floor of the retired front end, used only to map legacy
    /// fingerprints onto legacy centroids within that same embedding space.
    private static let legacySimilarityFloor: Float = 0.45
    private static let maxSnippetSeconds = 6.0
    private static let maxSnippetsPerSpeaker = 3
    private static let turnEdgeTrim = 0.25

    struct RegistryCentroid: Sendable {
        var id: Int
        var centroid: [Float]
        /// nil for centroids saved before embeddings were versioned.
        var version: String?
    }

    struct Assignments {
        var byFileLocal: [String: [String: Int]] = [:]
        var newEntries: [(id: Int, centroid: [Float])] = []
        /// Stale centroids rebuilt from source audio that is still available.
        var rebuiltEntries: [(id: Int, centroid: [Float])] = []
        /// Stale entries with no source audio left; they keep their names.
        var needsSamples: [Int] = []
    }

    /// Assigns local speaker labels to global speaker ids by matching voiceprints to centroids; new speakers get new ids.
    static func assignments(
        files: [(mediaRef: String, url: URL, turns: [Turn])],
        registry: [RegistryCentroid],
        calibration: SpeakerMatchCalibration = .current
    ) async -> Assignments {
        var out = Assignments()
        let version = SpeakerEmbeddingService.version
        var prints: [(mediaRef: String, local: String, print: SpeakerVoiceprint)] = []
        for file in files where !file.turns.isEmpty {
            for (local, print) in await voiceprints(url: file.url, mediaRef: file.mediaRef, turns: file.turns)
                .sorted(by: { $0.key < $1.key }) {
                prints.append((file.mediaRef, local, print))
            }
        }

        var current = registry.filter { $0.version == version && !$0.centroid.isEmpty }
        let stale = registry.filter { $0.version != version && !$0.centroid.isEmpty }
        if !stale.isEmpty {
            let rebuilt = await rebuild(stale: stale, files: files, prints: prints, version: version)
            out.rebuiltEntries = rebuilt.map { ($0.id, $0.centroid) }
            out.needsSamples = stale.map(\.id).filter { id in !rebuilt.contains { $0.id == id } }
            current += rebuilt
        }
        guard !prints.isEmpty else { return out }

        var clusters: [(id: Int, centroid: [Float], refs: Set<String>, isNew: Bool)] =
            current.map { ($0.id, $0.centroid, [], false) }
        var nextId = (registry.map(\.id).max() ?? 0) + 1
        for item in prints {
            var best = -1
            var bestScore = calibration.acceptThreshold
            for (index, cluster) in clusters.enumerated() where !cluster.refs.contains(item.mediaRef) {
                let score = Double(SpeakerVoiceprintPolicy.cosine(item.print.vector, cluster.centroid))
                if score >= bestScore { best = index; bestScore = score }
            }
            if best < 0 || item.print.effectiveDuration < calibration.minimumEvidence {
                clusters.append((nextId, item.print.vector, [], true))
                nextId += 1
                best = clusters.count - 1
            }
            clusters[best].refs.insert(item.mediaRef)
            out.byFileLocal[item.mediaRef, default: [:]][item.local] = clusters[best].id
        }
        out.newEntries = clusters.filter(\.isNew).map { ($0.id, $0.centroid) }
        return out
    }

    /// Maps each file voice to a stale centroid in the legacy embedding space,
    /// then rebuilds that centroid from the voices' current-version prints.
    private static func rebuild(
        stale: [RegistryCentroid],
        files: [(mediaRef: String, url: URL, turns: [Turn])],
        prints: [(mediaRef: String, local: String, print: SpeakerVoiceprint)],
        version: String
    ) async -> [RegistryCentroid] {
        var members: [Int: [VoiceprintSegment]] = [:]
        for file in files where !file.turns.isEmpty {
            let legacy = await legacyFingerprints(url: file.url, mediaRef: file.mediaRef, turns: file.turns)
            for (local, vector) in legacy {
                guard let entry = stale.max(by: {
                    SpeakerVoiceprintPolicy.cosine(vector, $0.centroid) < SpeakerVoiceprintPolicy.cosine(vector, $1.centroid)
                }), SpeakerVoiceprintPolicy.cosine(vector, entry.centroid) >= legacySimilarityFloor,
                   let fresh = prints.first(where: { $0.mediaRef == file.mediaRef && $0.local == local })?.print else {
                    continue
                }
                members[entry.id, default: []].append(
                    VoiceprintSegment(vector: fresh.vector, duration: fresh.effectiveDuration)
                )
            }
        }
        return members.compactMap { id, segments in
            SpeakerVoiceprintPolicy.aggregate(segments, version: version).map {
                RegistryCentroid(id: id, centroid: $0.vector, version: version)
            }
        }
    }

    /// Current-version voiceprint per local speaker, from clean speech of its longest turns.
    private static func voiceprints(url: URL, mediaRef: String, turns: [Turn]) async -> [String: SpeakerVoiceprint] {
        let version = SpeakerEmbeddingService.version
        let cacheURL = cache.directory.appendingPathComponent(
            "\(mediaRef)_\(DiskCache.sizeMtimeTag(for: url))_\(stableTag(version))_prints.json"
        )
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: SpeakerVoiceprint].self, from: data) {
            return cached
        }
        var prints: [String: SpeakerVoiceprint] = [:]
        for (speaker, ranges) in await snippetRanges(url: url, mediaRef: mediaRef, turns: turns) {
            let windows = SpeakerVoiceprintPolicy.windows(for: ranges)
            guard let segments = try? await SpeakerEmbeddingService.shared.segments(url: url, windows: windows),
                  let print = SpeakerVoiceprintPolicy.aggregate(segments, version: version) else { continue }
            prints[speaker] = print
        }
        // Empty prints usually mean a transient failure (model preparation) — don't cache them.
        if !prints.isEmpty, let data = try? JSONEncoder().encode(prints) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return prints
    }

    /// Fingerprints in the retired embedding space: the unversioned cache when
    /// present, otherwise recomputed with the retired front end.
    private static func legacyFingerprints(url: URL, mediaRef: String, turns: [Turn]) async -> [String: [Float]] {
        let cacheURL = cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: url))_voices.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            return cached
        }
        #if BUNDLED_SPEECH
        var prints: [String: [Float]] = [:]
        for (speaker, ranges) in await snippetRanges(url: url, mediaRef: mediaRef, turns: turns) {
            var sum: [Float]?
            for range in ranges {
                guard let samples = try? await AudioTrackReader.readMonoFloats(
                    from: url, sampleRate: 16_000, range: range.start...range.end
                ), samples.count >= 8_000, let vector = try? await legacyModel.embed(samples) else { continue }
                sum = sum.map { zip($0, vector).map(+) } ?? vector
            }
            if let sum, let unit = SpeakerVoiceprintPolicy.normalized(sum) { prints[speaker] = unit }
        }
        return prints
        #else
        return [:]
        #endif
    }

    #if BUNDLED_SPEECH
    private static let legacyModel = LegacyModelBox()

    /// The retired speech-swift front end, kept only to bridge old centroids.
    private actor LegacyModelBox {
        private var model: WeSpeakerModel?
        func embed(_ samples: [Float]) async throws -> [Float] {
            try await LocalModelManager.shared.ensureSpeakerEmbeddingModel()
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            defer { MLXRuntime.releaseActivations() }
            if model == nil {
                let descriptor = LocalModelManager.catalog.first { $0.id == .weSpeaker }!
                model = try await WeSpeakerModel.fromPretrained(
                    modelId: descriptor.repository,
                    cacheDir: LocalModelManager.directory(for: .weSpeaker),
                    offlineMode: true
                )
            }
            return model!.embed(audio: samples, sampleRate: 16000)
        }
    }
    #endif

    /// Up to three longest turns per speaker, trimmed and restricted to detected speech.
    private static func snippetRanges(url: URL, mediaRef: String, turns: [Turn]) async -> [String: [SpeechTimeRange]] {
        var bySpeaker: [String: [Turn]] = [:]
        for turn in turns where turn.end - turn.start >= 1.0 {
            bySpeaker[turn.speaker, default: []].append(turn)
        }
        var result: [String: [SpeechTimeRange]] = [:]
        for (speaker, all) in bySpeaker {
            let picks = all.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(maxSnippetsPerSpeaker)
            for turn in picks {
                result[speaker, default: []] += await speechSpans(in: turn, url: url, mediaRef: mediaRef)
                    .map { SpeechTimeRange(start: $0.lowerBound, end: $0.upperBound) }
            }
        }
        return result
    }

    static func speechConfirmed(_ turns: [Turn], url: URL, mediaRef: String) async -> [Turn] {
        guard let analysis = try? await VoiceActivity.analysis(for: url, mediaRef: mediaRef),
              !analysis.segments.isEmpty else { return [] }
        return turns.filter { turn in
            analysis.segments.contains { min(turn.end, $0.end) - max(turn.start, $0.start) >= 0.3 }
        }
    }

    /// Skips silence and trims edges before embedding.
    private static func speechSpans(in turn: Turn, url: URL, mediaRef: String) async -> [ClosedRange<Double>] {
        let start = turn.start + turnEdgeTrim
        let end = min(turn.end, turn.start + maxSnippetSeconds) - turnEdgeTrim
        guard end - start >= 0.5 else { return [] }
        // Compute-or-cache; a fresh import gets real spans (and dead-air marking inherits the sidecar).
        guard let analysis = try? await VoiceActivity.analysis(for: url, mediaRef: mediaRef), !analysis.segments.isEmpty else {
            return [start...end]
        }
        var spans: [ClosedRange<Double>] = []
        for segment in analysis.segments {
            let lo = max(start, segment.start)
            let hi = min(end, segment.end)
            if hi - lo >= 0.3 { spans.append(lo...hi) }
        }
        return spans
    }

    /// Stable across launches (unlike `hashValue`), for cache file names.
    private static func stableTag(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
