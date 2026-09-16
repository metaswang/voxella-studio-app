#if BUNDLED_SPEECH
import Foundation
import Synchronization
import Testing
@testable import PalmierPro

@Suite("Opt-in diarization cancellation", .serialized)
struct DiarizationCancellationIntegrationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["VOXELLA_DIARIZATION_CANCELLATION"] == "1"),
        arguments: [DiarizationStage.preparing, .diarizing]
    )
    func cancellationUnwindsBeforeGatedModelReuse(stage: DiarizationStage) async throws {
        try await Self.run(stage: stage)
    }

    @concurrent
    private static func loadEngine() async throws -> MLXStreamingSortformerEngine {
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let descriptor = try #require(LocalModelManager.catalog.first { $0.id == .sortformerDiarization })
        return try MLXStreamingSortformerEngine(
            modelDirectory: LocalModelManager.directory(for: .sortformerDiarization),
            modelRevision: descriptor.revision
        )
    }

    @concurrent
    private static func run(stage: DiarizationStage) async throws {
        let engine = try await loadEngine()
        let audio = [Float](repeating: 0, count: 16_000 * 31)
        let events = Mutex<[DiarizationStage]>([])
        let cancelled = try await Task.detached {
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            do {
                _ = try await engine.diarize(
                    audio: audio, sampleRate: 16_000,
                    speechRanges: [.init(start: 0, end: 31)],
                    policy: .standard(requestedSpeakerCount: 2)
                ) { update in
                    events.withLock { $0.append(update.stage) }
                    if update.stage == stage {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                return false
            } catch is CancellationError {
                return true
            }
        }.value
        #expect(cancelled)
        #expect(events.withLock { $0 } == (stage == .preparing ? [.preparing] : [.preparing, .diarizing]))

        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let reused = try await engine.diarize(
            audio: audio, sampleRate: 16_000,
            speechRanges: [.init(start: 0, end: 31)],
            policy: .standard(requestedSpeakerCount: 2), progress: { _ in }
        )
        #expect(reused.diagnostics.processedChunks == 3)
        #expect(reused.probabilities.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        print("DIARIZATION_CANCEL stage=\(stage) cancelled=true reuseChunks=\(reused.diagnostics.processedChunks)")
    }
}
#endif
