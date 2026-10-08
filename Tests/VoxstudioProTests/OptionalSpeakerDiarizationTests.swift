import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Optional speaker recognition")
struct OptionalSpeakerDiarizationTests {
    private struct PreparationFailed: Error {}

    @Test func disabledSpeakerIdentificationDoesNotPrepareOrLoadAModel() async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 0,
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2,
            prepare: { Issue.record("Disabled speaker identification must not download a model") }
        ) {
            Issue.record("Disabled speaker identification must not load a model")
            throw URLError(.unknown)
        }
        #expect(result.diagnostics.backend == .disabled)
        #expect(result.diagnostics.warnings.isEmpty)
    }

    @Test(arguments: [nil, 2, 4, 8] as [Int?])
    func failedPreparationPreservesUnattributedTimeline(count: Int?) async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: count,
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2,
            prepare: { throw PreparationFailed() }
        ) {
            Issue.record("A model that failed to prepare must not be loaded")
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
            requestedSpeakerCount: 1,
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2,
            prepare: { Issue.record("Single speaker must not download a model") }
        ) {
            Issue.record("Single speaker must not load a model")
            throw URLError(.unknown)
        }
        #expect(result.diagnostics.backend == .singleSpeaker)
        #expect(result.speakerForWord(start: 0.1, end: 1) == 0)
    }

    @Test func modelIsRequiredOnlyWhenSpeakersAreIdentified() {
        #expect(!OptionalSpeakerDiarization.requiresModel(requestedSpeakerCount: 0))
        #expect(!OptionalSpeakerDiarization.requiresModel(requestedSpeakerCount: 1))
        #expect(OptionalSpeakerDiarization.requiresModel(requestedSpeakerCount: nil))
        #expect(OptionalSpeakerDiarization.requiresModel(requestedSpeakerCount: 8))
    }

    @Test func failedModelReturnsWarningWithoutLabels() async throws {
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 2, speechRanges: [], audioDuration: 2, prepare: {}
        ) { throw CocoaError(.fileReadCorruptFile) }
        #expect(result.diagnostics.warnings == [OptionalSpeakerDiarization.failedMessage])
        #expect(result.intervals.isEmpty)
    }

    @Test func cancellationDuringRecognitionDoesNotReturnPartialSuccess() async {
        await #expect(throws: CancellationError.self) {
            try await OptionalSpeakerDiarization.resolve(
                requestedSpeakerCount: 2, speechRanges: [], audioDuration: 2, prepare: {}
            ) { throw CancellationError() }
        }
    }

    @Test func cancellationDuringPreparationPropagates() async {
        await #expect(throws: CancellationError.self) {
            try await OptionalSpeakerDiarization.resolve(
                requestedSpeakerCount: 2, speechRanges: [], audioDuration: 2,
                prepare: { throw CancellationError() }
            ) { Issue.record("Cancelled preparation must not recognize"); throw URLError(.unknown) }
        }
    }

    @Test func preparedModelKeepsItsResult() async throws {
        let expected = SpeakerActivityPostprocessor.singleSpeaker(
            speechRanges: [.init(start: 0, end: 2)], audioDuration: 2
        )
        let result = try await OptionalSpeakerDiarization.resolve(
            requestedSpeakerCount: 2, speechRanges: [], audioDuration: 2, prepare: {}
        ) { expected }
        #expect(result == expected)
    }

    @Test func nemotronLicenseIsRecordedPerLicenseVersion() throws {
        let model = try #require(LocalModelManager.catalog.first { $0.id == .nemotron3Diarization })
        #expect(model.needsLicenseAcceptance(accepted: false))
        #expect(!model.needsLicenseAcceptance(accepted: true))
        #expect(model.license == "OpenMDW-1.1")
        let key = LocalModelManager.licenseRecordKey(for: model)
        #expect(key.contains("nemotron3Diarization"))
        #expect(key.contains("a435e9867d79e789e90053f9b6d6834053af564a"))
    }

    @Test func cacheSeparatesAbsentInstalledAndUpdatedModels() {
        let absent = TranscriptCache.localPipelineFingerprint(configuration: .automatic)
        let installed = TranscriptCache.localPipelineFingerprint(configuration: .automatic, speakerModelRevision: "a")
        let updated = TranscriptCache.localPipelineFingerprint(configuration: .automatic, speakerModelRevision: "b")
        #expect(Set([absent, installed, updated]).count == 3)
        #expect(OptionalSpeakerDiarization.cacheIdentity(requestedSpeakerCount: 1, modelRevision: nil)
            == OptionalSpeakerDiarization.cacheIdentity(requestedSpeakerCount: 1, modelRevision: "a"))
        let identity = OptionalSpeakerDiarization.cacheIdentity(requestedSpeakerCount: nil, modelRevision: "a")
        #expect(identity.contains("nemotron3-int8"))
        #expect(identity.contains(OptionalSpeakerDiarization.processingIdentity))
    }

    @Test(arguments: [nil, 1, 2, 4, 8] as [Int?])
    func diarizationNeverBlocksTheRecognitionPlan(count: Int?) {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "en", speakerCount: count, asrModelID: .whisperLargeV3Turbo8Bit,
            isInstalled: { $0 != .nemotron3Diarization }
        )
        #expect(plan.missingItems.isEmpty)
        #expect(plan.additionalBytes == 0)
        #expect(LocalModelManager.catalog.first { $0.id == .nemotron3Diarization }?.isRecommended == false)
    }

    @Test func retiredSortformerIsOutOfTheCatalogButStillDecodes() throws {
        #expect(!LocalModelManager.catalog.contains { $0.id == .sortformerDiarization })
        let decoded = try JSONDecoder().decode(LocalModelID.self, from: Data("\"sortformerDiarization\"".utf8))
        #expect(decoded == .sortformerDiarization)
        let retired = try #require(LocalModelManager.retiredModels.first { $0.id == .sortformerDiarization })
        #expect(retired.repository == "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16")
        #expect(retired.replacement == .nemotron3Diarization)
    }

    @Test func pruningNeverDeletesUnknownOrCurrentRepositories() {
        // A repository this build does not know may belong to a newer build.
        #expect(!LocalModelManager.shouldPrune(repository: "someone/future-model", pendingRetirements: []))
        for model in LocalModelManager.catalog {
            #expect(!LocalModelManager.shouldPrune(repository: model.repository, pendingRetirements: []))
        }
        #expect(!LocalModelManager.shouldPrune(repository: LocalModelManager.ttsTokenizerRepository, pendingRetirements: []))
        let sortformer = "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16"
        #expect(LocalModelManager.shouldPrune(repository: sortformer, pendingRetirements: []))
        // Retired weights stay until their replacement is installed.
        #expect(!LocalModelManager.shouldPrune(repository: sortformer, pendingRetirements: [sortformer]))
        #expect(LocalModelManager.shouldPrune(repository: "aufklarer/Pyannote-Segmentation-MLX", pendingRetirements: []))
        #expect(LocalModelManager.isRunningTests)
    }

    @Test func legacyBackendsDecodeAsLegacyModel() throws {
        for raw in ["mlxStreamingSortformer", "pyannoteWeSpeaker"] {
            let backend = try JSONDecoder().decode(DiarizationBackend.self, from: Data("\"\(raw)\"".utf8))
            #expect(backend == .legacyModel)
            #expect(backend.producesSpeakerActivity)
        }
        let current = try JSONDecoder().decode(DiarizationBackend.self, from: Data("\"nemotron3\"".utf8))
        #expect(current == .nemotron3)
    }

    @Test func nemotronCatalogEntryMatchesPinnedExport() throws {
        let model = try #require(LocalModelManager.catalog.first { $0.id == .nemotron3Diarization })
        #expect(model.repository == "aufklarer/Nemotron-3-Diarization-100M-MLX-INT8")
        #expect(model.revision == "8be6cfb8a8009b1e11419208c819f6e20c94b4a3")
        #expect(model.weightByteSize == 106_541_384)
        #expect(model.weightSHA256 == "78b2131bbfdccdd6e3b440a96c5e5e3b12a80dbeda14e988dde8024affb67ac3")
        #expect(Set(model.requiredArtifacts.map(\.filename)) == ["config.json", "LICENSE", "NOTICE"])
        #expect(model.byteSize == model.weightByteSize + model.requiredArtifacts.reduce(0) { $0 + $1.byteSize })
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
