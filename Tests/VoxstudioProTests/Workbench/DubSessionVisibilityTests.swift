import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Dub session visibility")
struct DubSessionVisibilityTests {
    private func completedDub(sourceID: UUID? = nil) -> WorkbenchDubJob {
        var job = WorkbenchDubJob()
        job.title = "现实的本质与订阅提醒"
        job.sourceTranscriptionID = sourceID
        job.state = .completed
        job.script = "他们看得懂眼前的世界吗？"
        job.outputPath = "/tmp/generated-voiceover.wav"
        job.renderedSegments = [
            .init(index: 0, text: job.script, start: 0, end: 4, speaker: "ABC")
        ]
        job.summaryMarkdown = "Voiceover summary"
        job.summaryState = .completed
        return job
    }

    @Test @MainActor func importedVoiceoverHasItsOwnRecentSessionAndGeneratedContent() throws {
        var source = WorkbenchTranscriptionJob(sourcePath: "/tmp/source.mp4")
        source.customTitle = "Original video"
        source.state = .completed
        source.summaryMarkdown = "Original summary"
        source.result = .init(
            text: "Original transcript", language: "en", words: [],
            segments: [.init(text: "Original transcript", start: 80.8, end: 324.84, speaker: "Host")]
        )
        let job = completedDub(sourceID: source.id)
        let sessions = WorkbenchStore.localSessions(transcriptions: [source], dubs: [job])
        let recent = WorkbenchStore.recentDubSessions(from: sessions, jobs: [job])
        let session = try #require(recent.first)

        #expect(sessions.count == 2)
        #expect(recent.count == 1)
        #expect(session.id == job.id)
        #expect(session.id != source.id)
        #expect(session.title == job.title)
        #expect(session.source == .standaloneDub)
        #expect(session.sessionType == .dub)
        #expect(session.transcriptionID == nil)
        #expect(session.dubID == job.id)
        #expect(session.sourceURL == nil)
        #expect(session.outputURL == job.outputURL)
        #expect(session.summaryMarkdown == job.summaryMarkdown)
        #expect(session.duration == 4)
        #expect(session.dubSegments == job.renderedSegments)
        #expect(session.hasDub)
        #expect(!WorkbenchStore.shouldOpenStandaloneDubComposer(job))
        #expect(sessions.first { $0.id == source.id }?.dubID == job.id)
        #expect(job.sourceTranscriptionID == source.id)
    }

    @Test @MainActor func allVoiceoversRemainVisibleWithoutDuplicatingTheirSourceOrEmptyDrafts() {
        let source = WorkbenchTranscriptionJob(sourcePath: "/tmp/source.mp4")
        let first = completedDub(sourceID: source.id)
        var second = completedDub(sourceID: source.id)
        second.title = "Another voiceover"
        let standalone = completedDub()
        let emptyDraft = WorkbenchDubJob()
        let jobs = [first, second, standalone, emptyDraft]
        let sessions = WorkbenchStore.localSessions(transcriptions: [source], dubs: jobs)
        let recent = WorkbenchStore.recentDubSessions(from: sessions, jobs: jobs)

        #expect(sessions.count == 4)
        #expect(Set(recent.map(\.id)) == Set([first.id, second.id, standalone.id]))
        #expect(recent.count == 3)
        #expect(!recent.contains { $0.id == source.id || $0.id == emptyDraft.id })
    }

    @Test @MainActor func existingImportedResultsAppearAfterReloadAndRevisionsKeepOneSession() throws {
        let source = WorkbenchTranscriptionJob(sourcePath: "/tmp/source.mp4")
        let original = completedDub(sourceID: source.id)
        var restored = try JSONDecoder().decode(
            WorkbenchDubJob.self, from: JSONEncoder().encode(original)
        )
        for state in [WorkbenchJobState.completed, .running, .completed] {
            restored.state = state
            let sessions = WorkbenchStore.localSessions(transcriptions: [source], dubs: [restored])
            let recent = WorkbenchStore.recentDubSessions(from: sessions, jobs: [restored])
            #expect(recent.count == 1)
            #expect(recent.first?.id == original.id)
            #expect(recent.first?.state == state)
            #expect(recent.first?.title == original.title)
        }
    }

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
