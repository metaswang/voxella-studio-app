import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("MCP prompt voiceover inputs")
@MainActor
struct MCPDubbingInputTests {
    private let text = "Make Your Own Lemonade” is about turning life’s setbacks into chances for practical action and growth. It encourages acknowledging what’s hard, then choosing a next step—such as addressing worry, protecting your health or finances, and finding small things to be grateful for."
    private let voiceID = UUID().uuidString

    @Test func schemaAcceptsPromptAndMarksCreationAsWrite() throws {
        let tool = try #require(MCPOpenAIExtensions.tools.first { $0.name == "app_dubbing" })
        #expect(tool.annotations.readOnlyHint == false)
        #expect(tool.inputSchema.objectValue?["required"]?.arrayValue == [])
        #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.sorted() == ["language", "session_id", "start", "text", "title", "voice_id"])
        #expect(MCPMutationReceipts.tool(tool).inputSchema.objectValue?["required"]?.arrayValue == ["request_id"])
    }

    @Test func draftRetainsExactPromptWithoutCreatingJob() async throws {
        var calls: [String] = []
        let extensions = MCPOpenAIExtensions(server: Server(name: "draft-test", version: "1"), mediaExecutor: { name, _ in
            calls.append(name)
            return .ok("{\"voices\":[]}")
        })
        let result = await extensions.execute(.init(name: "app_dubbing", arguments: ["text": .string(text), "title": "Make Your Own Lemonade", "start": false]))
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["options"]?.objectValue?["text"]?.stringValue == text)
        #expect(result.structuredContent?.objectValue?["options"]?.objectValue?["title"] == "Make Your Own Lemonade")
        #expect(result.structuredContent?.objectValue?["voices"]?.arrayValue == [])
        #expect(calls == ["voice.list"])
        #expect(result.structuredContent?.objectValue?["job_id"] == nil)
        let encoded = try #require(result.content.first)
        if case .text(let content, _, _) = encoded { #expect(content.contains("options")) }
    }

    @Test func delayedStartCreatesOnceAndKeepsStableJobIdentityAndScript() async throws {
        let sessionID = UUID().uuidString
        var submissions = 0, script: String?
        let extensions = MCPOpenAIExtensions(server: Server(name: "start-test", version: "1"), mediaExecutor: { name, args in
            if name == "voice.list" { return .ok("{\"voices\":[]}") }
            #expect(name == "dubbing.create")
            submissions += 1; script = args["text"] as? String
            try? await Task.sleep(for: .milliseconds(1_100))
            return .ok("{\"session_id\":\"\(sessionID)\",\"kind\":\"dubbing\",\"status\":\"queued\"}")
        })
        let started = await extensions.execute(.init(name: "app_dubbing", arguments: ["text": .string(text), "voice_id": .string(voiceID), "start": true]))
        #expect(started.isError != true)
        #expect(started.structuredContent?.objectValue?["view"] == "dubbing")
        #expect(started.structuredContent?.objectValue?["options"]?.objectValue?["text"]?.stringValue == text)
        let jobID = try #require(started.structuredContent?.objectValue?["job_id"]?.stringValue)
        var ready = started
        for _ in 0..<30 {
            ready = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(jobID)]))
            if ready.structuredContent?.objectValue?["session_id"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready.structuredContent?.objectValue?["session_id"]?.stringValue == sessionID)
        #expect(ready.structuredContent?.objectValue?["job_id"]?.stringValue == jobID)
        #expect(submissions == 1)
        #expect(script == text)
    }

    @Test func invalidInputsNeverSubmit() async {
        var calls = 0
        let extensions = MCPOpenAIExtensions(server: Server(name: "invalid-test", version: "1"), mediaExecutor: { _, _ in calls += 1; return .ok("{}") })
        let cases: [[String: Value]] = [
            ["start": true, "text": .string(text)],
            ["start": true, "voice_id": .string(voiceID)],
            ["text": "   "],
            ["text": .string(String(repeating: "x", count: 12_001))],
            ["voice_id": "made-up"],
            ["language": "unsupported"],
            ["session_id": .string(UUID().uuidString), "text": .string(text)],
        ]
        for args in cases {
            let result = await extensions.execute(.init(name: "app_dubbing", arguments: args))
            #expect(result.isError == true)
        }
        #expect(calls == 0)
    }

    @Test func reopenUsesSavedScriptWithoutAnotherCreation() async throws {
        let store = WorkbenchStore.shared
        for _ in 0..<100 {
            if !store.isHydrating { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var job = WorkbenchDubJob()
        job.script = text; job.title = "Make Your Own Lemonade"; job.language = "en"; job.state = .completed
        store.dubs.append(job)
        defer { store.dubs.removeAll { $0.id == job.id } }
        var calls: [String] = []
        let extensions = MCPOpenAIExtensions(server: Server(name: "reopen-test", version: "1"), mediaExecutor: { name, args in
            calls.append(name)
            if name == "voice.list" { return .ok("{\"voices\":[]}") }
            #expect(args["session_id"] as? String == job.id.uuidString)
            return .ok("{\"session_id\":\"\(job.id.uuidString)\",\"status\":\"completed\"}")
        })
        let result = await extensions.execute(.init(name: "app_dubbing", arguments: ["session_id": .string(job.id.uuidString)]))
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["options"]?.objectValue?["text"]?.stringValue == text)
        #expect(result.structuredContent?.objectValue?["status"] == "completed")
        #expect(calls == ["voice.list", "media.status"])
    }

    @Test func cancelledReadIsAnActionableErrorInsteadOfEmptySuccessOrSwiftError() async throws {
        let extensions = MCPOpenAIExtensions(server: Server(name: "cancel-test", version: "1"))
        let read = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await extensions.execute(.init(name: "session.editor.read", arguments: ["session_id": .string(UUID().uuidString), "scope": "transcript"]))
        }
        let result = await read.value
        #expect(result.isError == true)
        #expect(result.structuredContent?.objectValue?["outcome"] == "request_cancelled")
        #expect(result.structuredContent?.objectValue?["error"]?.stringValue?.contains("Retry") == true)
        let knowledge = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MCPKnowledgeBaseTools.execute(name: "fetch", args: [:])
        }
        let knowledgeResult = await knowledge.value
        #expect(knowledgeResult.isError == true)
        #expect(knowledgeResult.structuredContent?.objectValue?["code"] == "request_cancelled")
        let workspace = MCPWorkspaceTools(store: MCPWorkspaceStore())
        let shared = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await workspace.execute(.init(name: "app_session", arguments: ["session_id": .string(UUID().uuidString)]))
        }
        let sharedResult = await shared.value
        #expect(sharedResult.isError == true)
        #expect(sharedResult.structuredContent?.objectValue?["code"] == "request_cancelled")
        let preview = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MCPMediaTools.execute(name: "media.preview", args: ["session_id": UUID().uuidString])
        }
        let response = await preview.value
        #expect(response.isError)
        let adapted = MCPOpenAIExtensions.adapted(response)
        if case .text(let content, _, _) = try #require(adapted.content.first) {
            #expect(content.contains("cancelled"))
            #expect(!content.contains("Swift.CancellationError"))
        }
    }
}
