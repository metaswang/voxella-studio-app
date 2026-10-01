import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@MainActor
struct MCPMediaToolsTests {
    @Test func rejectsMalformedRequestsBeforeMutatingWorkbench() {
        let cases: [(String, [String: Any])] = [
            ("media.status", ["session_id": "invalid"]),
            ("media.preview", ["session_id": UUID().uuidString, "duration": 0]),
            ("media.preview", ["session_id": UUID().uuidString, "duration": 31]),
            ("media.preview", ["session_id": UUID().uuidString, "play": "true"]),
            ("transcription.create", ["path": "/tmp/test.m4a", "start": 1]),
            ("transcription.create", ["path": "/tmp/test.m4a", "start": -1, "end": 3]),
            ("transcription.create", ["path": "/tmp/test.m4a", "start": 2, "end": 2]),
            ("transcription.create", ["path": "/tmp/test.m4a", "segment_subtitles": 1]),
            ("transcription.translate", ["session_id": UUID().uuidString, "target_languages": []]),
            ("transcription.translate", ["session_id": UUID().uuidString, "target_languages": ["en", "en"]]),
            ("transcription.translate", ["session_id": UUID().uuidString, "target_languages": ["English"]]),
            ("dubbing.create", ["text": " ", "voice_id": UUID().uuidString]),
            ("voice.list", ["delete": true]),
        ]
        for (name, args) in cases {
            #expect(throws: (any Error).self, "\(name): \(args)") { try MCPMediaTools.validate(args, name: name) }
        }
    }

    @Test func returnsActionableToolErrors() async {
        let result = await MCPMediaTools.execute(name: "media.preview", args: ["session_id": UUID().uuidString, "duration": 31])
        #expect(result.isError)
        guard case let .text(message) = result.content.first else { Issue.record("Missing error"); return }
        #expect(message == "duration must be >0 and <=30 seconds")
    }

    @Test func chainedOperationWaitsForCompletedFlowToReleaseReservation() async throws {
        var busy = true
        var returned = false
        let waiter = Task { @MainActor in
            try await MCPMediaTools.waitUntilReady(pollInterval: .milliseconds(1)) {
                (.completed, busy, nil)
            }
            returned = true
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!returned)
        busy = false
        try await waiter.value
        #expect(returned)
    }

    @Test func chainedOperationPropagatesFailureInsteadOfContinuing() async {
        await #expect(throws: (any Error).self) {
            try await MCPMediaTools.waitUntilReady(pollInterval: .milliseconds(1)) {
                (.failed, false, "ASR unavailable")
            }
        }
    }

    @Test func acceptsMultilingualClipAndBoundedPreview() throws {
        try MCPMediaTools.validate(["path": "~/Downloads/test.m4a", "start": 0.0, "end": 12.5, "segment_subtitles": true, "target_languages": ["zh", "en", "pt-BR"]], name: "transcription.create")
        try MCPMediaTools.validate(["session_id": UUID().uuidString, "duration": 30, "play": true], name: "media.preview")
    }

    @Test func previewTrackSelectionPreservesSourceAndOtherLanguages() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/source.m4a")
        job.result = .init(text: "Hello", language: "en", words: [], segments: [.init(text: "Hello", start: 0, end: 2, speaker: nil)])
        let zh = SubtitleTrack(sourceLanguage: "en", language: "zh", cues: [.init(id: 0, sourceIDs: [0], text: "你好", start: 0, end: 2, speaker: nil)])
        let ja = SubtitleTrack(sourceLanguage: "en", language: "ja", cues: [.init(id: 0, sourceIDs: [0], text: "こんにちは", start: 0, end: 2, speaker: nil)])
        job.upsertTranslation(zh, languageCode: "zh")
        job.upsertTranslation(ja, languageCode: "ja")
        job.selectedTrack = .translation
        #expect(try MCPMediaTools.track(job, language: nil)?.text == "こんにちは")
        #expect(MCPMediaTools.selectedLanguage(job) == "ja")
        #expect(try MCPMediaTools.track(job, language: "zh")?.text == "你好")
        #expect(try MCPMediaTools.track(job, language: "source")?.text == "Hello")
        #expect(throws: (any Error).self) { try MCPMediaTools.track(job, language: "fr") }
        #expect(job.translationTracks.count == 2)
        #expect(job.result?.text == "Hello")
        job.selectedTrack = .source
        #expect(MCPMediaTools.selectedLanguage(job) == "en")
        #expect(job.selectedTranslationLanguageCode == "ja")
    }

    @Test func serverAnnouncesMediaToolsWithoutProject() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let executor = await ToolExecutor(projectProvider: { nil })
            let server = Server(name: "test", version: "1", capabilities: .init(tools: .init()))
            await MCPService.registerTools(on: server, executor: executor)
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let session = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"))
        request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        for name in ["voice.create", "dubbing.create", "transcription.create", "transcription.translate", "transcription.segment", "transcription.select_track", "media.preview", "media.status"] {
            #expect(body.contains(name))
        }
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"media.preview","arguments":{"session_id":"invalid"}}}"#.utf8)
        let (invalid, _) = try await URLSession.shared.data(for: request)
        #expect(String(decoding: invalid, as: UTF8.self).contains("Invalid session UUID"))
    }
}
