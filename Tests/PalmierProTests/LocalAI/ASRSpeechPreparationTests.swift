import Foundation
import Testing
@testable import PalmierPro

@Suite("ASR speech preparation")
struct ASRSpeechPreparationTests {
    @Test func sustainedLowProbabilityAudioSkipsRecognition() {
        let result = ASRSpeechPreparation.make(
            sampleCount: 64 * 512,
            originalProbabilities: Array(repeating: 0.02, count: 64)
        )

        #expect(!result.hasPotentialSpeech)
        #expect(result.excludedRanges == [.init(start: 0, end: 2.048)])
    }

    @Test func ambiguousAudioIsPreservedWithBoundaryProtection() throws {
        var probabilities = Array(repeating: Float(0.02), count: 64)
        probabilities[30] = 0.20

        let result = ASRSpeechPreparation.make(
            sampleCount: 64 * 512,
            originalProbabilities: probabilities
        )

        let range = try #require(result.recognitionRanges.first)
        #expect(result.recognitionRanges.count == 1)
        #expect(range.start == 0.704)
        #expect(range.end == 1.376)
        #expect(result.confidentSpeechRanges.isEmpty)
    }

    @Test func oneFrameShortSpeechIsNotDiscarded() {
        var probabilities = Array(repeating: Float(0.02), count: 64)
        probabilities[30] = 0.80

        let result = ASRSpeechPreparation.make(
            sampleCount: 64 * 512,
            originalProbabilities: probabilities
        )

        #expect(result.hasPotentialSpeech)
        #expect(result.confidentSpeechRanges.count == 1)
    }

    @Test func rescueCanOnlyIncreaseSpeechProbability() {
        let result = ASRSpeechPreparation.make(
            sampleCount: 32 * 512,
            originalProbabilities: Array(repeating: 0.02, count: 32),
            rescuedProbabilities: Array(repeating: 0.60, count: 32)
        )

        #expect(result.hasPotentialSpeech)
        #expect(result.confidentSpeechRanges == [.init(start: 0, end: 1.024)])
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
        let probabilities = try await ASRSpeechProbabilityService.shared.probabilities(
            samples: Array(repeating: 0, count: 16_000),
            progress: { _, _, _ in }
        )

        #expect(probabilities.count == 32)
        #expect(probabilities.allSatisfy { $0.isFinite })
    }
    #endif
}
