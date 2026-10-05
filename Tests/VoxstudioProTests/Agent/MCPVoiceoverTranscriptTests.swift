import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("MCP voiceover transcript and subtitles")
@MainActor
struct MCPVoiceoverTranscriptTests {
    private func job() -> WorkbenchDubJob {
        var job = WorkbenchDubJob()
        job.title = "The Red Umbrella"
        job.script = "A red umbrella brings strangers together."
        job.language = "en"
        job.state = .completed
        job.outputPath = "/tmp/mcp-voiceover-fixture.m4a"
        job.alignedTranscript = .init(text: job.script, language: "en", words: [],
            segments: [.init(text: job.script, start: 0, end: 39, speaker: "Narrator")])
        job.subtitleTrack = .init(sourceLanguage: "en", language: "en", cues: [
            .init(id: 7, sourceIDs: [0], text: "A red umbrella", start: 0, end: 12, speaker: "Narrator"),
            .init(id: 8, sourceIDs: [0], text: "brings strangers together.", start: 12, end: 39, speaker: "Narrator")])
        return job
    }

    private func session(_ job: WorkbenchDubJob) throws -> WorkbenchSession {
        try #require(WorkbenchStore.localSessions(transcriptions: [], dubs: [job]).first)
    }

    @Test func voiceoverDetailsSelectTranscriptAndKeepSubtitlesSeparate() throws {
        let job = job(), source = try session(job)
        #expect(source.transcript == nil && source.subtitleTrack == nil)
        let details = MCPOpenAIExtensions.sessionDetails(source)
        #expect(details["text"] as? String == job.script)
        #expect(details["has_transcript"] as? Bool == true)
        #expect(details["language"] as? String == "en")
        #expect(details["content_role"] as? String == "voiceover")
        #expect(details["text_complete"] as? Bool == true)
        let transcript = try MCPOpenAIExtensions.readableTrack(source, scope: "transcript", language: nil)
        let subtitles = try MCPOpenAIExtensions.readableTrack(source, scope: "source", language: nil)
        #expect(transcript.cues.map(\.text) == [job.script])
        #expect(subtitles.cues.map(\.id) == [7, 8])
        #expect(subtitles.cues.last?.end == 39)
    }

    @Test func subtitleFallbackCloudFieldsAndLongTextAreReadable() throws {
        var job = job()
        job.alignedTranscript = nil
        var source = try session(job)
        #expect(MCPOpenAIExtensions.sessionDetails(source)["content_provenance"] as? String == "subtitle_fallback")
        #expect(MCPOpenAIExtensions.sessionDetails(source)["text"] as? String == job.script)
        source.transcript = .init(text: "Current cloud revision", language: "zh", words: [], segments: [])
        source.subtitleTrack = job.subtitleTrack
        #expect(MCPOpenAIExtensions.sessionDetails(source)["text"] as? String == "Current cloud revision")
        #expect(try MCPOpenAIExtensions.readableTrack(source, scope: "transcript", language: nil).cues.first?.text == "Current cloud revision")
        source.transcript = .init(text: String(repeating: "字", count: 16_001), language: "zh", words: [], segments: [])
        let long = MCPOpenAIExtensions.sessionDetails(source)
        #expect((long["text"] as? String)?.count == 16_000)
        #expect(long["text_complete"] as? Bool == false)
        #expect(long["transcript_tool"] as? String == "session.get_segments")
    }

    @Test func originalSessionDoesNotBorrowLinkedVoiceover() throws {
        var source = try session(job())
        source.source = .media; source.sessionType = .upload
        #expect(MCPOpenAIExtensions.sessionDetails(source)["text"] as? String == "")
        #expect(MCPOpenAIExtensions.sessionDetails(source)["has_transcript"] as? Bool == false)
        #expect(try MCPOpenAIExtensions.readableTrack(source, scope: "source", language: nil).cues.isEmpty)
        source.transcript = .init(text: "Original recording", language: "en", words: [], segments: [])
        #expect(MCPOpenAIExtensions.sessionDetails(source)["text"] as? String == "Original recording")
    }

    @Test func transcriptOnlySessionKeepsSubtitlesAbsent() throws {
        var source = try session(job())
        source.source = .media; source.sessionType = .upload
        source.transcript = .init(text: "A full transcript without subtitle cuts", language: "en", words: [], segments: [])
        let transcript = try MCPOpenAIExtensions.readableTrack(source, scope: "transcript", language: nil)
        #expect(transcript.cues.first?.text == "A full transcript without subtitle cuts")
        #expect(try MCPOpenAIExtensions.readableTrack(source, scope: "source", language: nil).cues.isEmpty)
        source.source = .standaloneDub; source.sessionType = .dub
        source.dubSubtitleTrack = nil
        #expect(try MCPOpenAIExtensions.readableTrack(source, scope: "source", language: nil).cues.isEmpty)
        #expect(!transcript.cues.isEmpty)
    }

    @Test func transcriptReaderGroupsParagraphsAndSubtitleReaderDoesNotInventCuts() async throws {
        let store = WorkbenchStore.shared
        for _ in 0..<100 {
            if !store.isHydrating { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/mcp-transcript-only-fixture.wav")
        job.state = .completed
        job.result = .init(text: "First sentence. Second sentence. Another speaker.", language: "en", words: [], segments: [
            .init(text: "First sentence.", start: 0, end: 3, speaker: "Speaker 1"),
            .init(text: "Second sentence.", start: 3, end: 7, speaker: "Speaker 1"),
            .init(text: "Another speaker.", start: 7, end: 10, speaker: "Speaker 2")])
        store.transcriptions.append(job)
        defer { store.transcriptions.removeAll { $0.id == job.id } }
        let extensions = MCPOpenAIExtensions(server: Server(name: "transcript-test", version: "1"))
        let id = Value.string(job.id.uuidString)
        let transcript = await extensions.execute(.init(name: "session.editor.read", arguments: ["session_id": id, "scope": "transcript"]))
        #expect(transcript.isError != true)
        #expect(transcript.structuredContent?.objectValue?["cues"]?.arrayValue?.count == 3)
        let paragraphs = try #require(transcript.structuredContent?.objectValue?["paragraphs"]?.arrayValue)
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.objectValue?["text"]?.stringValue == "First sentence. Second sentence.")
        let subtitles = await extensions.execute(.init(name: "session.editor.read", arguments: ["session_id": id, "scope": "source"]))
        #expect(subtitles.isError != true)
        #expect(subtitles.structuredContent?.objectValue?["available"]?.boolValue == false)
        #expect(subtitles.structuredContent?.objectValue?["editable"]?.boolValue == false)
        #expect(subtitles.structuredContent?.objectValue?["cues"]?.arrayValue?.isEmpty == true)
        #expect(store.transcriptions.first { $0.id == job.id }?.subtitleTrack == nil)
    }

    @Test func panelResourceAndCueToolReturnVoiceoverButCommitRemainsGuarded() async throws {
        let store = WorkbenchStore.shared
        for _ in 0..<100 {
            if !store.isHydrating { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let job = job()
        store.dubs.append(job)
        defer { store.dubs.removeAll { $0.id == job.id } }
        let extensions = MCPOpenAIExtensions(server: Server(name: "voiceover-test", version: "1"))
        let id = Value.string(job.id.uuidString)
        for name in ["app_session", "voxstudio.session_panel"] {
            let result = await extensions.execute(.init(name: name, arguments: ["session_id": id]))
            #expect(result.isError != true)
            #expect(result.structuredContent?.objectValue?["text"]?.stringValue == job.script)
        }
        let resource = try await extensions.readResource("voxstudio://sessions/\(job.id.uuidString)")
        let text = try #require(resource.contents.first?.text)
        let content = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(content.objectValue?["text"]?.stringValue == job.script)
        let read = await extensions.execute(.init(name: "session.editor.read", arguments: ["session_id": id, "scope": "source"]))
        #expect(read.isError != true)
        #expect(read.structuredContent?.objectValue?["editable"]?.boolValue == false)
        #expect(read.structuredContent?.objectValue?["cues"]?.arrayValue?.count == 2)
        let revision = try #require(read.structuredContent?.objectValue?["revision"])
        let commit = await extensions.execute(.init(name: "session.editor.commit", arguments: [
            "session_id": id, "expected_revision": revision, "request_id": "voiceover-test",
            "operations": [.object(["type": "text", "cue_id": 7, "text": "Changed"])]]))
        #expect(commit.isError == true)
        #expect(store.dubs.first { $0.id == job.id }?.script == job.script)
    }
}
