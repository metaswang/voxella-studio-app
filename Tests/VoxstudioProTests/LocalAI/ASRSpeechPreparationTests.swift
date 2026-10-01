import Foundation
import Testing
@testable import VoxstudioPro

@Suite("ASR speech preparation")
struct ASRSpeechPreparationTests {
    private static let hop = LocalSpeechVAD.chunkSize
    private static let sampleRate = LocalSpeechVAD.sampleRate

    @Test func sustainedLowProbabilityAudioSkipsRecognition() {
        let frames = 8
        let result = ASRSpeechPreparation.make(
            sampleCount: frames * Self.hop,
            originalProbabilities: Array(repeating: 0.02, count: frames)
        )

        #expect(!result.hasPotentialSpeech)
        #expect(result.excludedRanges == [.init(start: 0, end: Double(frames * Self.hop) / Double(Self.sampleRate))])
    }

    @Test func ambiguousAudioIsRejectedWithoutSileroAnchor() {
        var probabilities = Array(repeating: Float(0.02), count: 8)
        probabilities[4] = 0.20

        let result = ASRSpeechPreparation.make(
            sampleCount: 8 * Self.hop,
            originalProbabilities: probabilities
        )

        #expect(!result.hasPotentialSpeech)
        #expect(result.confidentSpeechRanges.isEmpty)
    }

    @Test func oneFrameShortSpeechIsNotDiscarded() {
        var probabilities = Array(repeating: Float(0.02), count: 8)
        probabilities[4] = 0.80

        let result = ASRSpeechPreparation.make(
            sampleCount: 8 * Self.hop,
            originalProbabilities: probabilities
        )

        #expect(result.hasPotentialSpeech)
        #expect(result.confidentSpeechRanges.count == 1)
    }

    @Test func rescueCannotBypassOriginalGate() {
        let frames = 4
        let result = ASRSpeechPreparation.make(
            sampleCount: frames * Self.hop,
            originalProbabilities: Array(repeating: 0.02, count: frames),
            rescuedProbabilities: Array(repeating: 0.60, count: frames)
        )

        #expect(!result.hasPotentialSpeech)
        #expect(result.confidentSpeechRanges.isEmpty)
    }

    @Test func chunkContextDoesNotCrossExcludedAudio() throws {
        let allowed = [ASRSpeechRange(start: 2, end: 5)]
        let chunks = ASRChunkPlanner.chunks(
            speechRanges: [ASRSpeechRange(start: 1, end: 6)],
            audioDuration: 10,
            configuration: .init(
                maximumWindowDuration: 30,
                boundaryContextDuration: 1,
                maximumMergeGap: 0
            ),
            allowedRanges: allowed
        )

        let chunk = try #require(chunks.first)
        #expect(chunks.count == 1)
        #expect(chunk.inputStart == 2)
        #expect(chunk.inputEnd == 5)
        #expect(chunk.ownershipStart == 2)
        #expect(chunk.ownershipEnd == 5)
    }

    #if BUNDLED_SPEECH
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"))
    func installed16kSileroCheckpointLoadsAndRuns() async throws {
        let samples = [Float](repeating: 0, count: Self.sampleRate)
        let probabilities = try await SpeechAnalysisService.shared.probabilities(
            samples: samples,
            progress: { _, _, _ in }
        )

        #expect(probabilities.count == LocalSpeechVAD.chunkCount(for: samples.count))
        #expect(probabilities.allSatisfy { $0.isFinite })
    }
    #endif
}
