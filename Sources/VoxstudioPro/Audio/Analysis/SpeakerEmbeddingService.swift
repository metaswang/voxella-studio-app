import Foundation
#if BUNDLED_SPEECH
import WeSpeakerEmbedding
#endif

/// The single WeSpeaker embedding path used by reference voiceprints,
/// transcription identity matching and editor speaker linking.
actor SpeakerEmbeddingService {
    static let shared = SpeakerEmbeddingService()

    /// Changes whenever weights or front end change; voiceprints from another
    /// version are rebuilt from their source audio.
    static var version: String {
        let revision = LocalModelManager.catalog.first { $0.id == .weSpeaker }?.revision ?? "unknown"
        #if BUNDLED_SPEECH
        return "wespeaker-resnet34@\(revision)|\(KaldiFbankOptions.frontEndVersion)|pool-unbiased"
        #else
        return "wespeaker-resnet34@\(revision)|unavailable"
        #endif
    }

    static let sampleRate = 16_000

    #if BUNDLED_SPEECH
    private var embedder: WeSpeakerEmbedder?
    #endif

    /// Prepares the model (license record, download, verification) if needed.
    func prepare() async throws {
        #if BUNDLED_SPEECH
        try await LocalModelManager.shared.ensureSpeakerEmbeddingModel()
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    /// Embeds each window of `url` separately. Windows that fail (too short,
    /// unreadable, degenerate output) are skipped rather than failing the batch.
    func segments(url: URL, windows: [SpeechTimeRange]) async throws -> [VoiceprintSegment] {
        guard !windows.isEmpty else { return [] }
        try await prepare()
        var result: [VoiceprintSegment] = []
        for window in windows {
            try Task.checkCancellation()
            guard let samples = try? await AudioTrackReader.readMonoFloats(
                from: url, sampleRate: Double(Self.sampleRate), range: window.start...window.end
            ) else { continue }
            if let vector = try? await embed(samples) {
                result.append(VoiceprintSegment(vector: vector, duration: Double(samples.count) / Double(Self.sampleRate)))
            }
        }
        return result
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        #if BUNDLED_SPEECH
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }
        if embedder == nil {
            embedder = try WeSpeakerEmbedder(modelDirectory: LocalModelManager.directory(for: .weSpeaker))
        }
        return try embedder!.embed(samples)
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    func release() {
        #if BUNDLED_SPEECH
        embedder = nil
        #endif
    }
}
