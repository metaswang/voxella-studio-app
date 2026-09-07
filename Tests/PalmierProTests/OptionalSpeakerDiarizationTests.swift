import Foundation
import Testing
@testable import PalmierPro

@Suite("Optional speaker recognition")
struct OptionalSpeakerDiarizationTests {
    @Test(arguments: [nil, 2, 4] as [Int?])
    func missingModelPreservesUnattributedTimeline(count: Int?) async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: count, isInstalled: false,
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2
        ) {
            Issue.record("Missing model must not be loaded")
            throw URLError(.unknown)
        }
        #expect(result.audioDuration == 2)
        #expect(result.speakerCount == 0)
        #expect(result.speakerForWord(start: 0.1, end: 1) == nil)
        #expect(result.diagnostics.backend == .unavailable)
        #expect(result.diagnostics.warnings == [OptionalSpeakerDiarization.unavailableMessage])
    }

    @Test func singleSpeakerNeedsNoModel() async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 1, isInstalled: false,
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2
        ) {
            Issue.record("Single speaker must not load a model")
            throw URLError(.unknown)
        }
        #expect(result.diagnostics.backend == .singleSpeaker)
        #expect(result.speakerForWord(start: 0.1, end: 1) == 0)
    }

    @Test func failedModelReturnsWarningWithoutLabels() async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 2, isInstalled: true, speechRanges: [], audioDuration: 2
        ) { throw CocoaError(.fileReadCorruptFile) }
        #expect(result.diagnostics.warnings == [OptionalSpeakerDiarization.failedMessage])
        #expect(result.intervals.isEmpty)
    }

    @Test func cancellationDoesNotReturnPartialSuccess() async {
        await #expect(throws: CancellationError.self) {
            try await OptionalSpeakerDiarization.resolve(
                requestedSpeakerCount: 2, isInstalled: true, speechRanges: [], audioDuration: 2
            ) { throw CancellationError() }
        }
    }

    @Test func installedModelKeepsItsResult() async throws {
        let expected = SpeakerActivityPostprocessor.singleSpeaker(
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2
        )
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 2, isInstalled: true, speechRanges: [], audioDuration: 2
        ) { expected }
        #expect(result == expected)
    }

    @Test func acceptedLicenseDoesNotRequireAnotherReview() throws {
        let model = try #require(LocalModelManager.catalog.first { $0.id == .sortformerDiarization })
        #expect(model.needsLicenseAcceptance(accepted: false))
        #expect(!model.needsLicenseAcceptance(accepted: true))
    }

    @Test func cacheSeparatesAbsentInstalledAndUpdatedModels() {
        let absent = TranscriptCache.localPipelineFingerprint(configuration: .automatic)
        let installed = TranscriptCache.localPipelineFingerprint(configuration: .automatic, speakerModelRevision: "a")
        let updated = TranscriptCache.localPipelineFingerprint(configuration: .automatic, speakerModelRevision: "b")
        #expect(Set([absent, installed, updated]).count == 3)
        #expect(OptionalSpeakerDiarization.cacheIdentity(requestedSpeakerCount: 1, modelRevision: nil)
            == OptionalSpeakerDiarization.cacheIdentity(requestedSpeakerCount: 1, modelRevision: "a"))
    }

    @Test(arguments: [nil, 1, 2, 4] as [Int?])
    func sortformerNeverBlocksInstallationPlan(count: Int?) {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "en", speakerCount: count, asrModelID: .whisperLargeV3Turbo8Bit,
            isInstalled: { $0 != .sortformerDiarization }
        )
        #expect(plan.missingItems.isEmpty)
        #expect(!plan.requiresLicenseAcceptance)
        #expect(plan.additionalBytes == 0)
        #expect(LocalModelManager.catalog.first { $0.id == .sortformerDiarization }?.isRecommended == false)
    }
}

#if BUNDLED_SPEECH
import AudioCommon

extension OptionalSpeakerDiarizationTests {
    @Test func unlabeledWordsRetainTextAndTimestampsThroughSegmentation() {
        let aligned = [
            AlignedWord(text: "Hello", startTime: 0, endTime: 1),
            AlignedWord(text: "world.", startTime: 1, endTime: 2)
        ]
        let words = LexicalSpeakerResolver.wordsWithoutSpeakerAttribution(to: aligned, audioDuration: 2)
        #expect(words.map(\.text) == ["Hello", "world."])
        #expect(words.map(\.start) == [0, 1])
        #expect(words.map(\.end) == [1, 2])
        #expect(words.allSatisfy { $0.speaker == nil && $0.speakerConfidence == nil })
        let segments = LocalSpeechPipeline.makeSegments(from: words)
        #expect(!segments.isEmpty)
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == 2)
    }
}
#endif
