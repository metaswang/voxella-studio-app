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
    @Test func taskDetailsKeepTheFailedStageAndSavedReason() {
        let job = WorkbenchTranscriptionJob(
            sourcePath: "/tmp/audio.wav", state: .failed,
            flowProgressStage: .translation, errorMessage: "  API quota exceeded  "
        )
        let task = SessionTaskDetail(job: job)
        #expect(task.title == "Translation")
        #expect(task.statusLabel == "Failed")
        #expect(task.diagnostic == "API quota exceeded")
        #expect(!task.nextStep.isEmpty)
    }

    @Test func missingDiagnosticsAndInterruptedTasksExplainWhatIsKnown() {
        let failed = SessionTaskDetail(title: "Summary", state: .failed, errorMessage: " ", nextStep: "Retry")
        let interrupted = SessionTaskDetail(title: "Voiceover", state: .interrupted, errorMessage: nil, nextStep: "Retry")
        #expect(failed.diagnostic == "This task failed, but no error details were saved.")
        #expect(interrupted.diagnostic == "This task stopped before it finished.")
        let succeeded = SessionTaskDetail(title: "Summary", state: .completed, errorMessage: "Stale error", nextStep: "Retry")
        #expect(succeeded.diagnostic == nil)
    }

    @Test func readySessionKeepsDistinctSummaryAndSyncFailureReasons() {
        let session = WorkbenchSession(
            id: UUID(), title: "Saved session", createdAt: Date(), modifiedAt: Date(),
            state: .completed, source: .media, sessionType: .upload,
            transcriptionID: UUID(), dubID: nil, sourceURL: nil, outputURL: nil,
            transcript: TranscriptionResult(text: "Saved result", language: nil, words: [], segments: []),
            subtitleTrack: nil, translationTracks: [], selectedTranslationLanguageCode: nil,
            summaryMarkdown: nil, summaryTemplateID: nil, summaryTemplateName: nil,
            summaryState: .failed, summaryErrorMessage: "AI service is not configured",
            sessionTag: nil, dubTranscript: nil, dubSubtitleTrack: nil, dubSegments: [],
            cloudSyncState: .failed, cloudSyncError: "Network unavailable"
        )
        let status = session.status
        #expect(status.hasUsableResult)
        #expect(status.needsAttention)
        let issues = status.tasks.filter { $0.state.needsAttention }
        #expect(issues.map(\.title) == ["Summary", "Cloud sync"])
        #expect(issues.map(\.diagnostic) == ["AI service is not configured", "Network unavailable"])
    }
}
