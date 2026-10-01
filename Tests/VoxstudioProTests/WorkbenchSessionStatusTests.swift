import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Workbench session status")
struct WorkbenchSessionStatusTests {
    @Test func completedTaskWithoutCommittedResultIsNotReady() {
        let status = WorkbenchSessionStatus(
            hasUsableResult: false,
            taskState: .completed,
            hasAdditionalFailure: false
        )

        #expect(status.primaryLabel == "Status unknown")
        #expect(!status.hasUsableResult)
        #expect(status.needsAttention)
    }

    @Test func stateMachineRejectsSkippingQueueAndRestartsThroughQueue() {
        #expect(WorkbenchJobState.notStarted.canTransition(to: .queued))
        #expect(!WorkbenchJobState.notStarted.canTransition(to: .running))
        #expect(WorkbenchJobState.failed.canTransition(to: .queued))
        #expect(!WorkbenchJobState.failed.canTransition(to: .completed))
    }

    @Test func legacyReadyDecodesAsNotStarted() throws {
        let decoded = try JSONDecoder().decode(
            WorkbenchJobState.self,
            from: #""ready""#.data(using: .utf8)!
        )

        #expect(decoded == .notStarted)
    }

    @Test func remoteStateRequiresRecognizedReadiness() {
        #expect(WorkbenchStore.remoteState(status: "completed", resultReady: true) == .completed)
        #expect(WorkbenchStore.remoteState(status: "completed", resultReady: false) == .running)
        #expect(WorkbenchStore.remoteState(status: "completed", resultReady: nil) == .unknown)
        #expect(WorkbenchStore.remoteState(status: "mystery", resultReady: nil) == .unknown)
    }

    @Test func translationSnapshotShowsStageProgressAndTarget() {
        let job = WorkbenchTranscriptionJob(
            sourcePath: "/tmp/recording.m4a",
            state: .running,
            targetLanguageCode: "zh-CN",
            progress: 0.62,
            progressMessage: "Translating subtitle windows…",
            flowProgressStage: .translation,
            progressCompleted: 8,
            progressTotal: 13,
            compute: .cloud
        )

        let snapshot = SessionProcessingSnapshot(job: job)

        #expect(snapshot.kind == .translation)
        #expect(snapshot.fraction == 0.62)
        #expect(snapshot.resolvedStageTitle == "Translation")
        #expect(snapshot.progressDetail == "8 of 13 batches · Target zh")
        #expect(snapshot.locationLabel == "VoxStudio Cloud")
    }

    @Test func snapshotNormalizesInvalidProgressAndEmptyMessage() {
        let job = WorkbenchTranscriptionJob(
            sourcePath: "/tmp/recording.m4a",
            progress: .infinity,
            progressMessage: "   ",
            progressCompleted: -1,
            progressTotal: 0
        )

        let snapshot = SessionProcessingSnapshot(job: job)

        #expect(snapshot.fraction == 0)
        #expect(snapshot.message == "Processing media…")
        #expect(snapshot.progressDetail == nil)
    }
}
