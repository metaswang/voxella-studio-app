import Foundation
import Testing
@testable import PalmierPro

@Suite("First-run setup")
@MainActor
struct OnboardingTests {
    @Test func cancellingPendingFeaturesIsIndependentAndRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalModelDownloadAuthorizationStore(rootURL: root)
        let manager = LocalModelManager(restoreDownloads: false, authorizationStore: store)
        manager.prepareFeatures([.search, .knowledgeRanking])
        #expect(manager.preparationStatus(for: .search).isBusy)
        #expect(manager.preparationStatus(for: .knowledgeRanking).isBusy)

        manager.cancelFeature(.search)
        #expect(!manager.preparationStatus(for: .search).isBusy)
        #expect(manager.preparationStatus(for: .knowledgeRanking).isBusy)
        #expect(manager.state(for: SearchIndexConfig.modelID).isBusy)
        manager.prepareFeatures([.search])
        #expect(manager.preparationStatus(for: .search).isBusy)
        manager.cancelFeature(.knowledgeRanking)
        #expect(manager.preparationStatus(for: .search).isBusy)
        #expect(!manager.preparationStatus(for: .knowledgeRanking).isBusy)
        manager.cancelFeature(.search)
        #expect(!manager.state(for: SearchIndexConfig.modelID).isBusy)
        // Let authorization continuations run: a cancelled request must never enqueue itself.
        for _ in 0..<20 { await Task.yield() }
        #expect(!manager.state(for: SearchIndexConfig.modelID).isBusy)
        #expect(try await store.records().isEmpty)
    }

    @Test func cancellingSetupPreservesExplicitTaskDemand() {
        let manager = LocalModelManager(restoreDownloads: false, authorizationStore: LocalModelDownloadAuthorizationStore(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        manager.prepareFeatures([.search])
        manager.download(SearchIndexConfig.modelID)
        manager.cancelFeature(.search)
        #expect(manager.state(for: SearchIndexConfig.modelID).isBusy)
        #expect(!manager.preparationStatus(for: .search).isBusy)
        manager.cancel(SearchIndexConfig.modelID)
    }

    @Test func allDownloadsCanBeSkippedAndRequestedLater() throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = LocalModelManager(restoreDownloads: false, authorizationStore: LocalModelDownloadAuthorizationStore(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        let setup = OnboardingState(defaults: defaults)
        setup.showSelection()
        setup.prepare(startDownloads: manager.prepareFeatures)
        for feature in LocalPreparationFeature.allCases { manager.cancelFeature(feature) }
        #expect(LocalPreparationFeature.allCases.allSatisfy { !manager.preparationStatus(for: $0).isBusy })
        setup.complete()
        #expect(setup.isComplete)
        #expect(OnboardingState(defaults: defaults).isComplete)
        manager.download(SearchIndexConfig.modelID)
        #expect(manager.state(for: SearchIndexConfig.modelID).isBusy)
        manager.cancel(SearchIndexConfig.modelID)
    }

    @Test func selectedFeaturesReuseTaskDependenciesAndDeduplicateSharedResources() {
        let features: Set<LocalPreparationFeature> = [.transcription, .dubbing]
        let ids = LocalPreparationFeature.requiredIDs(for: features, asrModelID: .whisperLargeV3Turbo8Bit)
        let transcription = LocalModelInstallPlan.requiredModelIDs(languageCode: nil, speakerCount: nil, asrModelID: .whisperLargeV3Turbo8Bit)
        let dubbing = LocalModelInstallPlan.dubPlan(modelID: .qwenTTS17B, isInstalled: { _ in false }).items.map(\.id)
        #expect(Set(ids) == Set(transcription + dubbing))
        #expect(ids.count == Set(ids).count)
        #expect(!ids.contains(.weMMEmbedding2B4Bit))
        #expect(!ids.contains(.sortformerDiarization))
    }

    @Test func removingDubbingPreservesResourcesUsedByReadyTranscription() {
        let ids = LocalPreparationFeature.removableIDs(for: .dubbing, asrModelID: .whisperLargeV3Turbo8Bit) { _ in true }
        #expect(ids == [.qwenTTS17B])
    }

    @Test func removingTranscriptionPreservesDefaultAndSharedSpeechResources() {
        let ids = LocalPreparationFeature.removableIDs(for: .transcription, asrModelID: .whisperLargeV3Turbo8Bit) { _ in true }
        #expect(!ids.contains(.whisperLargeV3Turbo8Bit))
        #expect(!ids.contains(.forcedAligner))
        #expect(ids.contains(.parakeetTDT06Bv3))
    }

    @Test func removingUnpreparedFeatureIsANoOp() {
        #expect(LocalPreparationFeature.removableIDs(for: .dubbing, asrModelID: .whisperLargeV3Turbo8Bit) { _ in false }.isEmpty)
    }

    @Test func emptySelectionDoesNotRequestDownloads() {
        #expect(LocalPreparationFeature.requiredIDs(for: [], asrModelID: .whisperLargeV3Turbo8Bit).isEmpty)
    }

    @Test func dubbingDoesNotPrepareTranscription() {
        #expect(LocalPreparationFeature.dubbing.requiredIDs(asrModelID: .whisperLargeV3Turbo8Bit) == [.qwenTTS17B, .forcedAligner])
    }

    @Test func knowledgeRankingPreparesAllKnowledgeQADependencies() {
        #expect(LocalPreparationFeature.knowledgeRanking.requiredIDs(
            asrModelID: .whisperLargeV3Turbo8Bit
        ) == [.weMMEmbedding2B4Bit, .qwen3Reranker06B4Bit])
    }

    @Test func firstRunFeatureSelectionIncludesKnowledgeRanking() {
        #expect(LocalPreparationFeature.allCases.contains(.knowledgeRanking))
        #expect(LocalPreparationFeature.requiredIDs(
            for: [.knowledgeRanking],
            asrModelID: .whisperLargeV3Turbo8Bit
        ) == [.weMMEmbedding2B4Bit, .qwen3Reranker06B4Bit])
    }

    @Test func setupPersistsSelectionButRequiresExplicitCompletion() throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let setup = OnboardingState(defaults: defaults)
        #expect(!setup.isComplete)
        #expect(setup.selectedFeatures == Set(LocalPreparationFeature.allCases))
        setup.selectedFeatures = [.dubbing]
        setup.showSelection()
        var requests: [Set<LocalPreparationFeature>] = []
        setup.prepare { requests.append($0) }
        setup.prepare { requests.append($0) }
        #expect(requests == [[.dubbing]])
        #expect(setup.step == .preparation)
        let reopened = OnboardingState(defaults: defaults)
        #expect(!reopened.isComplete)
        #expect(reopened.selectedFeatures == [.dubbing])
        setup.complete()
        #expect(OnboardingState(defaults: defaults).isComplete)
        setup.replay()
        #expect(!setup.isComplete)
        #expect(setup.step == .features)
        #expect(OnboardingState(defaults: defaults).isComplete)
    }

    @Test func explicitlyEmptySelectionIsPreserved() throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set([], forKey: OnboardingState.selectionKey)

        #expect(OnboardingState(defaults: defaults).selectedFeatures.isEmpty)
    }

    @Test func unknownSavedFeaturesAreIgnored() throws {
        let name = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["future-feature", "dubbing"], forKey: OnboardingState.selectionKey)
        #expect(OnboardingState(defaults: defaults).selectedFeatures == [.dubbing])
    }

    @Test func installedResourcesDoNotIncreaseDownloadEstimate() {
        let ids: [LocalModelID] = [.qwenTTS17B, .forcedAligner, .forcedAligner]
        let status = LocalPreparationStatus(ids: ids, catalog: LocalModelManager.catalog) {
            $0 == .forcedAligner ? .installed : .failed("private repository detail")
        }
        #expect(!status.isReady)
        #expect(status.hasFailure)
        #expect(!status.isBusy)
        #expect(status.remainingBytes == LocalModelManager.catalog.first { $0.id == .qwenTTS17B }?.byteSize)
    }

    @Test(arguments: [Double.nan, .infinity, -1, 2])
    func progressRemainsFiniteAndBounded(fraction: Double) {
        let status = LocalPreparationStatus(ids: [.qwenTTS17B], catalog: LocalModelManager.catalog) { _ in
            .downloading(progress: fraction, message: "private filename")
        }
        #expect(status.progress.isFinite)
        #expect((0...1).contains(status.progress))
        #expect(status.isBusy)
        #expect(!status.isReady)
    }

    @Test func readinessRequiresEveryResource() {
        let ids: [LocalModelID] = [.qwenTTS17B, .forcedAligner]
        let waiting = LocalPreparationStatus(ids: ids, catalog: LocalModelManager.catalog) {
            $0 == .forcedAligner ? .installed : .notInstalled
        }
        #expect(!waiting.isReady)
        let ready = LocalPreparationStatus(ids: ids, catalog: LocalModelManager.catalog) { _ in .installed }
        #expect(ready.isReady)
        #expect(ready.progress == 1)
        #expect(ready.remainingBytes == 0)
    }
}
