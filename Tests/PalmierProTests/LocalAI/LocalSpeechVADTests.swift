import Foundation
import Testing
@testable import PalmierPro

@Suite("Local speech VAD")
struct LocalSpeechVADTests {
    @Test func speechRegionAnalysisRoundTripsCodable() throws {
        let value = SpeechRegionAnalysis(
            sampleRate: 16_000,
            chunkCount: 12,
            segments: [SpeechRegion(startTime: 0.32, endTime: 1.28)],
            backend: .coreML,
            modelRevision: "revision"
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SpeechRegionAnalysis.self, from: data)

        #expect(decoded == value)
    }

    @Test(arguments: [0, 1, 4_095, 4_096, 4_097, 8_192])
    func chunkCountPreserves256msResolution(sampleCount: Int) {
        let expected = sampleCount == 0 ? 0 : ((sampleCount - 1) / 4_096) + 1
        #expect(LocalSpeechVAD.chunkCount(for: sampleCount) == expected)
    }

    #if BUNDLED_SPEECH
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"))
    func coreMLSpeechAnalysisCompletes() async throws {
        let descriptor = try #require(
            LocalModelManager.catalog.first { $0.id == .sileroVAD }
        )
        #expect(LocalModelManager.isInstalled(descriptor))

        let samples = (0..<16_000).map { index in
            Float(sin(Double(index) * 2 * .pi * 220 / 16_000)) * 0.05
        }
        let analysis = try await SpeechAnalysisService.shared.analyze(
            samples: samples,
            progress: { _, _, _ in }
        )

        #expect(analysis.backend == .coreML)
        #expect(analysis.chunkCount == LocalSpeechVAD.chunkCount(for: samples.count))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_RUN_LONG_VAD"] == "1"))
    func coreMLSpeechAnalysisCompletesForLongAudio() async throws {
        let sampleCount = 32_000_000
        let samples = [Float](repeating: 0.01, count: sampleCount)
        let analysis = try await SpeechAnalysisService.shared.analyze(
            samples: samples,
            progress: { _, _, _ in }
        )

        #expect(analysis.backend == .coreML)
        #expect(analysis.chunkCount == LocalSpeechVAD.chunkCount(for: sampleCount))
    }
    #endif
}
