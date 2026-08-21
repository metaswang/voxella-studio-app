import Foundation
import Testing
@testable import PalmierPro

@Suite("Task-level transcription placement")
struct TaskPlacementTests {
    @Test func defaultsToThisMacForStorageAndCompute() {
        let placement = TranscriptionPlacement.localDefault
        #expect(placement.storage == .local)
        #expect(placement.compute == .local)
        #expect(TranscriptionPlacementRouter.requiresAuthentication(placement) == false)
        #expect(TranscriptionPlacementRouter.shouldRunLocalPipeline(placement))
        #expect(TranscriptionPlacementRouter.shouldStartCloudPipeline(placement) == false)
        #expect(TranscriptionPlacementRouter.remotePersistenceScope(placement) == nil)
        #expect(TranscriptionPlacementRouter.remoteClientCompute(placement) == nil)
    }

    @Test func routesAllFourStorageAndComputeCombinations() {
        let localLocal = TranscriptionPlacement(storage: .local, compute: .local)
        #expect(TranscriptionPlacementRouter.shouldRunLocalPipeline(localLocal))
        #expect(TranscriptionPlacementRouter.shouldStartCloudPipeline(localLocal) == false)
        #expect(TranscriptionPlacementRouter.shouldSyncLocalResults(localLocal) == false)
        #expect(TranscriptionPlacementRouter.shouldSyncCloudEdits(localLocal) == false)
        #expect(TranscriptionPlacementRouter.shouldConfirmEphemeralDelete(localLocal) == false)

        let localCloud = TranscriptionPlacement(storage: .local, compute: .cloud)
        #expect(TranscriptionPlacementRouter.requiresAuthentication(localCloud))
        #expect(TranscriptionPlacementRouter.shouldStartCloudPipeline(localCloud))
        #expect(TranscriptionPlacementRouter.shouldConfirmEphemeralDelete(localCloud))
        #expect(TranscriptionPlacementRouter.shouldSyncCloudEdits(localCloud) == false)
        #expect(TranscriptionPlacementRouter.remotePersistenceScope(localCloud) == .temporary)
        #expect(TranscriptionPlacementRouter.remoteClientCompute(localCloud) == .cloud)

        let cloudLocal = TranscriptionPlacement(storage: .cloud, compute: .local)
        #expect(TranscriptionPlacementRouter.requiresAuthentication(cloudLocal))
        #expect(TranscriptionPlacementRouter.shouldRunLocalPipeline(cloudLocal))
        #expect(TranscriptionPlacementRouter.shouldSyncLocalResults(cloudLocal))
        #expect(TranscriptionPlacementRouter.shouldSyncCloudEdits(cloudLocal))
        #expect(TranscriptionPlacementRouter.remotePersistenceScope(cloudLocal) == .persistent)
        #expect(TranscriptionPlacementRouter.remoteClientCompute(cloudLocal) == .local)

        let cloudCloud = TranscriptionPlacement(storage: .cloud, compute: .cloud)
        #expect(TranscriptionPlacementRouter.requiresAuthentication(cloudCloud))
        #expect(TranscriptionPlacementRouter.shouldStartCloudPipeline(cloudCloud))
        #expect(TranscriptionPlacementRouter.shouldSyncCloudEdits(cloudCloud))
        #expect(TranscriptionPlacementRouter.shouldConfirmEphemeralDelete(cloudCloud) == false)
        #expect(TranscriptionPlacementRouter.remotePersistenceScope(cloudCloud) == .persistent)
        #expect(TranscriptionPlacementRouter.remoteClientCompute(cloudCloud) == .cloud)
    }

    @Test func cancellationPreservesPersistentCloudSessionsButDeletesTransientOnes() {
        let transientCloud = TranscriptionPlacement(storage: .local, compute: .cloud)
        #expect(!TranscriptionPlacementRouter.shouldPreserveRemoteSessionAfterCancellation(transientCloud))
        #expect(!TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
            transientCloud,
            hasRemoteSession: true
        ))

        let persistentCloud = TranscriptionPlacement(storage: .cloud, compute: .cloud)
        #expect(TranscriptionPlacementRouter.shouldPreserveRemoteSessionAfterCancellation(persistentCloud))
        #expect(TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
            persistentCloud,
            hasRemoteSession: false
        ))

        let localComputeWithExistingSession = TranscriptionPlacement(storage: .cloud, compute: .local)
        #expect(TranscriptionPlacementRouter.shouldPreserveRemoteSessionAfterCancellation(localComputeWithExistingSession))
        #expect(TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
            localComputeWithExistingSession,
            hasRemoteSession: true
        ))
        #expect(!TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
            localComputeWithExistingSession,
            hasRemoteSession: false
        ))
    }

    @Test func cancelledAuthenticationKeepsTheSelectedChoices() {
        let current = TranscriptionPlacement(storage: .cloud, compute: .cloud)
        let next = TranscriptionPlacementRouter.placement(afterCancelledAuthentication: current)
        #expect(next == current)
    }

    @Test func copyUsesTaskFactsInsteadOfModeLabels() {
        #expect(TaskPlacementCopy.keepSessionTitle == "Keep this session in VoxStudio Cloud")
        #expect(TaskPlacementCopy.processWithTitle == "Process with VoxStudio Cloud")
        #expect(TaskPlacementCopy.thisMac == "This Mac")
        #expect(TaskPlacementCopy.voxStudioCloud == "VoxStudio Cloud")
        #expect(
            TaskPlacementCopy.summaryLine(storage: .local, compute: .cloud)
                == "Keep this session in VoxStudio Cloud: This Mac  ·  Process with VoxStudio Cloud: VoxStudio Cloud"
        )
    }

    @Test func sessionPlacementTooltipsExplainStorageAndProcessingLocations() {
        #expect(TaskPlacementCopy.storageTooltip(for: .local) == "Session stored on This Mac")
        #expect(TaskPlacementCopy.storageTooltip(for: .cloud) == "Session stored in VoxStudio Cloud")
        #expect(TaskPlacementCopy.computeTooltip(for: .local) == "Processing on This Mac")
        #expect(TaskPlacementCopy.computeTooltip(for: .cloud) == "Processing in VoxStudio Cloud")
    }

    @Test func cloudQuotaWarnsOnlyWhenTheNextSubmissionLeavesLittleTime() {
        let ample = CloudTranscriptionQuota(
            durationSeconds: 10 * 60,
            estimatedCredits: 2,
            availableCredits: 10,
            creditsPerSecond: 0.002,
            canAfford: true
        )
        #expect(ample.remainingMediaSecondsAfterSubmission == 4_000)
        #expect(!ample.shouldShowLowBalanceNotice)

        let low = CloudTranscriptionQuota(
            durationSeconds: 10 * 60,
            estimatedCredits: 8.5,
            availableCredits: 10,
            creditsPerSecond: 0.002,
            canAfford: true
        )
        #expect(low.remainingMediaSecondsAfterSubmission == 750)
        #expect(low.shouldShowLowBalanceNotice)
    }

    @Test func cloudNoticePolicyKeepsPaidUsersUndisturbedWhenCreditsAreAmple() {
        let ample = CloudTranscriptionQuota(
            durationSeconds: 5 * 60,
            estimatedCredits: 1,
            availableCredits: 10,
            creditsPerSecond: 0.002,
            canAfford: true
        )
        #expect(CloudTranscriptionNoticePolicy.notice(
            isSignedIn: true,
            isPaid: true,
            quota: ample
        ) == .none)
        #expect(CloudTranscriptionNoticePolicy.notice(
            isSignedIn: true,
            isPaid: false,
            quota: ample
        ) == .freeUpgrade)
    }

    @Test func cloudNoticePolicyUsesQuotaForBlockingAndLowBalanceStates() {
        let insufficient = CloudTranscriptionQuota(
            durationSeconds: 10 * 60,
            estimatedCredits: 4,
            availableCredits: 1,
            creditsPerSecond: 0.002,
            canAfford: false
        )
        #expect(CloudTranscriptionNoticePolicy.notice(
            isSignedIn: true,
            isPaid: false,
            quota: insufficient
        ) == .insufficientCredits)

        let low = CloudTranscriptionQuota(
            durationSeconds: 10 * 60,
            estimatedCredits: 8.5,
            availableCredits: 10,
            creditsPerSecond: 0.002,
            canAfford: true
        )
        #expect(CloudTranscriptionNoticePolicy.notice(
            isSignedIn: true,
            isPaid: true,
            quota: low
        ) == .lowBalance(remainingSeconds: 750))
    }

    @Test func routedAccessUsesLocalPipelineUnlessCloudComputeIsSelected() async throws {
        let local = RecordingTranscriptionAccess()
        let cloud = RecordingTranscriptionAccess()
        let routed = RoutedTranscriptionTaskAccess(local: local, cloud: cloud)
        let localRequest = Self.request(placement: .localDefault)
        for await _ in routed.events(for: localRequest) {}
        #expect(local.eventsCalled == 1)
        #expect(cloud.eventsCalled == 0)

        let cloudRequest = Self.request(placement: TranscriptionPlacement(storage: .local, compute: .cloud))
        for await _ in routed.events(for: cloudRequest) {}
        #expect(local.eventsCalled == 1)
        #expect(cloud.eventsCalled == 1)

        try await routed.cancel(UUID())
        #expect(local.cancelCalled == 1)
        #expect(cloud.cancelCalled == 1)

        let remoteID = UUID()
        _ = try await routed.persistCloudCopyIfNeeded(Self.syncRequest(
            placement: TranscriptionPlacement(storage: .cloud, compute: .local),
            remoteSessionID: remoteID
        ))
        #expect(cloud.persistCalled == 1)

        _ = try await routed.persistCloudCopyIfNeeded(Self.syncRequest(
            placement: .localDefault,
            remoteSessionID: remoteID
        ))
        #expect(cloud.persistCalled == 1)
    }

    @Test func cloudResultSyncNeverOverwritesCloudComputedResults() {
        #expect(CloudResultSyncPolicy.destination(for: .local) == .updateExisting)
        #expect(CloudResultSyncPolicy.destination(for: .cloud) == .createNew)
        #expect(CloudResultSyncPolicy.destination(for: nil) == .createNew)
    }

    @Test func dubCreditNoticePolicyCoversSignInFreeLowAndBlockedStates() {
        #expect(CloudCreditNoticePolicy.notice(
            isSignedIn: false,
            isPaid: false,
            estimate: nil
        ) == .signIn)

        let freeEstimate = CloudUsageEstimate(
            mediaDurationSeconds: 120,
            estimatedCostPoints: 2,
            remainingCreditsPoints: 10,
            maxDurationSecWithRemainingQuota: 600,
            canAfford: true
        )
        #expect(CloudCreditNoticePolicy.notice(
            isSignedIn: true,
            isPaid: false,
            estimate: freeEstimate
        ) == .freeUpgrade)

        let lowEstimate = CloudUsageEstimate(
            durationSeconds: 600,
            estimatedCredits: 8.5,
            availableCredits: 10,
            creditsPerSecond: 0.002,
            canAfford: true
        )
        #expect(CloudCreditNoticePolicy.notice(
            isSignedIn: true,
            isPaid: true,
            estimate: lowEstimate
        ) == .lowBalance(remainingSeconds: 750))

        let blockedEstimate = CloudUsageEstimate(
            mediaDurationSeconds: 900,
            estimatedCostPoints: 12,
            remainingCreditsPoints: 4,
            maxDurationSecWithRemainingQuota: 300,
            canAfford: false
        )
        #expect(CloudCreditNoticePolicy.notice(
            isSignedIn: true,
            isPaid: true,
            estimate: blockedEstimate
        ) == .insufficient(mediaDuration: 900, availableDuration: 300))
    }

    @Test func dubJobWithoutPlacementFieldsDecodesToLocalDefaults() throws {
        let encoded = try JSONEncoder().encode(WorkbenchDubJob())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        [
            "storage",
            "compute",
            "remoteSessionID",
            "remoteGenerationID",
            "clientRequestID",
            "localCachePath",
            "cloudSyncState",
            "remoteResultVersion",
            "pendingCloudSyncError",
        ].forEach { object.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkbenchDubJob.self, from: legacyData)
        #expect(decoded.placement == .localDefault)
        #expect(decoded.resolvedCloudSyncState == .none)
    }

    @Test func dubSubmissionCarriesTheSelectedPlacement() {
        let placement = TaskPlacement(storage: .cloud, compute: .local)
        #expect(DubSubmission(placement: placement).placement == placement)
    }

    private static func request(placement: TranscriptionPlacement) -> TranscriptionTaskRequest {
        TranscriptionTaskRequest(
            jobID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
            originalFilename: "sample.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 12,
            durationHintSec: 1,
            options: TranscriptionProcessingOptions(),
            placement: placement,
            flowRequest: MediaFlowRequest(
                id: UUID(),
                input: .media(URL(fileURLWithPath: "/tmp/sample.m4a")),
                steps: []
            ),
            remoteSessionID: nil,
            shouldReuseRemoteSession: false
        )
    }

    private static func syncRequest(
        placement: TranscriptionPlacement,
        remoteSessionID: UUID
    ) -> TranscriptionResultSyncRequest {
        TranscriptionResultSyncRequest(
            jobID: UUID(),
            remoteSessionID: remoteSessionID,
            sourceURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
            originalFilename: "sample.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 12,
            options: TranscriptionProcessingOptions(),
            placement: placement,
            result: TranscriptionResult(text: "hello", language: "en", words: [], segments: []),
            subtitleTrack: nil,
            translationTracks: []
        )
    }
}

final class RecordingTranscriptionAccess: TranscriptionTaskAccessing, @unchecked Sendable {
    var eventsCalled = 0
    var persistCalled = 0
    var cancelCalled = 0

    func events(for request: TranscriptionTaskRequest) -> AsyncStream<MediaJobEvent> {
        eventsCalled += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func cancel(_ id: UUID) async throws {
        cancelCalled += 1
    }

    func persistCloudCopyIfNeeded(_ request: TranscriptionResultSyncRequest) async throws -> UUID? {
        persistCalled += 1
        return request.remoteSessionID
    }

    func confirmEphemeralDeletionIfNeeded(remoteSessionID: UUID) async throws {}
}
