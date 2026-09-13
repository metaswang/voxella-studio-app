import Foundation
import Testing
@testable import PalmierPro

@Suite("Dub session visibility")
struct DubSessionVisibilityTests {
    @Test func untouchedDraftIsNotARecentSession() {
        var draft = WorkbenchDubJob()
        draft.segments = [DubSegmentPayload(index: 0, text: "")]

        #expect(!WorkbenchStore.shouldIncludeStandaloneDubInSessions(draft))
    }

    @Test func submittedOrAuthoredDubRemainsARecentSession() {
        var authored = WorkbenchDubJob()
        authored.script = "Narration"
        authored.segments = [DubSegmentPayload(index: 0, text: "Narration")]

        var submitted = WorkbenchDubJob()
        submitted.state = .running
        submitted.segments = [DubSegmentPayload(index: 0, text: "")]

        #expect(WorkbenchStore.shouldIncludeStandaloneDubInSessions(authored))
        #expect(WorkbenchStore.shouldIncludeStandaloneDubInSessions(submitted))
    }

    @Test func authoredStandaloneDraftReopensInTheDubComposer() {
        var draft = WorkbenchDubJob()
        draft.script = "Narration"
        draft.segments = [DubSegmentPayload(index: 0, text: "Narration")]

        #expect(WorkbenchStore.shouldOpenStandaloneDubComposer(draft))
    }

    @Test func generatedOrTranscriptLinkedDubDoesNotReopenInTheComposer() {
        var generated = WorkbenchDubJob()
        generated.outputPath = "/tmp/narration.m4a"

        var transcriptLinked = WorkbenchDubJob()
        transcriptLinked.sourceTranscriptionID = UUID()

        #expect(!WorkbenchStore.shouldOpenStandaloneDubComposer(generated))
        #expect(!WorkbenchStore.shouldOpenStandaloneDubComposer(transcriptLinked))
    }
}
