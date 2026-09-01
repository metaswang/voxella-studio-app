import Testing
@testable import PalmierPro

@Suite("Workbench session status")
struct WorkbenchSessionStatusTests {
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
