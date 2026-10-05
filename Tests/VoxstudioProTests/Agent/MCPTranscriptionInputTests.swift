import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("MCP prompt transcription inputs")
@MainActor
struct MCPTranscriptionInputTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mcp-ui/preview/fixture-audio.m4a")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForJob(_ extensions: MCPOpenAIExtensions, id: String) async throws -> CallTool.Result {
        for _ in 0..<100 {
            let result = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(id)]))
            if result.isError == true || result.structuredContent?.objectValue?["session_id"] != nil { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPDocumentError("test_timeout", "Job did not resolve")
    }

    @Test func advertisesPromptPathsAndCompleteChatGPTFileInput() throws {
        let tool = try #require(MCPOpenAIExtensions.tools.first { $0.name == "app_transcription" })
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(properties["path"]?.objectValue?["type"] == "string")
        #expect(properties["start"]?.objectValue?["default"] == false)
        #expect(tool.annotations.readOnlyHint == false)
        #expect(tool.annotations.idempotentHint == false)
        #expect(tool._meta?["openai/fileParams"] == ["attachment"])
        let file = try #require(properties["attachment"]?.objectValue)
        #expect(file["properties"]?.objectValue?.keys.sorted() == ["download_url", "file_id", "file_name", "mime_type"])
        #expect(file["required"] == ["download_url", "file_id"])
    }

    @Test func autoLanguageIsDetectionInsteadOfLiteralLanguageCode() {
        #expect(MCPMediaTools.sourceLanguage(nil) == nil)
        #expect(MCPMediaTools.sourceLanguage("auto") == nil)
        #expect(MCPMediaTools.sourceLanguage(" AUTO ") == nil)
        #expect(MCPMediaTools.sourceLanguage("zh") == "zh")
    }

    @Test func suppliedPathStartsOnceWithoutFormOrPicker() async throws {
        var submissions: [[String: Any]] = []
        let sessionID = UUID().uuidString
        let server = Server(name: "test", version: "1")
        let extensions = MCPOpenAIExtensions(server: server, mediaExecutor: { name, args in
            #expect(name == "transcription.create")
            submissions.append(args)
            return .ok("{\"session_id\":\"\(sessionID)\",\"status\":\"running\",\"title\":\"An automatically generated title\"}")
        })
        extensions.initialize(.init(extensions: ["openai/elicitation": .object(["form": .object([:])])]))
        let result = await extensions.execute(.init(name: "app_transcription", arguments: ["path": .string(fixture.path), "start": true]))
        #expect(result.isError != true)
        let data = try #require(result.structuredContent?.objectValue)
        #expect(data["view"] == "transcription")
        #expect(data["name"] == "fixture-audio.m4a")
        #expect(data["session_id"] == .string(sessionID))
        #expect(data["title"] == "An automatically generated title")
        #expect(data["next_call"]?.objectValue?["tool"] == "media.status")
        #expect(data["result_call"]?.objectValue?["arguments"]?.objectValue?["session_id"] == .string(sessionID))
        let jobID = try #require(data["job_id"]?.stringValue)
        let ready = try await waitForJob(extensions, id: jobID)
        #expect(ready.structuredContent?.objectValue?["session_id"] == .string(sessionID))
        #expect(submissions.count == 1)
        #expect(submissions.first?["path"] as? String == fixture.path)
        #expect(submissions.first?["language"] == nil)
        #expect(submissions.first?["speakers"] == nil)
        #expect(submissions.first?["start"] == nil)
    }

    @Test func preselectionKeepsOriginalNameAndNeverSubmits() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), inputRoot: root, mediaExecutor: { _, _ in
            count += 1; return .error("Unexpected submission")
        })
        let result = await extensions.execute(.init(name: "app_transcription", arguments: ["path": .string(fixture.path), "start": false]))
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["job_id"] == nil)
        let input = try #require(result.structuredContent?.objectValue?["input"]?.objectValue)
        let id = try #require(input["asset_id"]?.stringValue)
        var ready = false
        for _ in 0..<100 {
            let status = await extensions.execute(.init(name: "media.input_status", arguments: ["asset_id": .string(id)]))
            #expect(status.structuredContent?.objectValue?["name"] == "fixture-audio.m4a")
            if status.structuredContent?.objectValue?["status"] == "ready" { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready)
        #expect(count == 0)
    }

    @Test func missingAmbiguousAndInvalidInputsCreateNoWork() async {
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"))
        let cases: [[String: Value]] = [
            ["start": true],
            ["path": "relative.wav", "start": true],
            ["path": "/tmp/missing-voxstudio-input.wav", "start": true],
            ["path": "/tmp/file.wav", "attachment": .object([:]), "start": true],
            ["attachment": .object(["download_url": "file:///tmp/file.wav", "file_id": "file_1"]), "start": true],
            ["attachment": .object(["download_url": "https://example.com/media", "file_id": .int(1)]), "start": true],
        ]
        for args in cases {
            let result = await extensions.execute(.init(name: "app_transcription", arguments: args))
            #expect(result.isError == true)
            #expect(result.structuredContent?.objectValue?["job_id"] == nil)
        }
    }

    @Test func promptAttachmentDownloadsAndSubmitsManagedMediaWithAutoDefaults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var submissions: [[String: Any]] = []
        let sessionID = UUID().uuidString
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), inputRoot: root.appendingPathComponent("inputs"), attachmentDownloader: { request in
            #expect(request.url?.absoluteString == "https://example.com/host-attachment")
            let temporary = root.appendingPathComponent("download")
            try FileManager.default.copyItem(at: fixture, to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mp4"])!)
        }, mediaExecutor: { _, args in
            submissions.append(args)
            return .ok("{\"session_id\":\"\(sessionID)\",\"status\":\"running\"}")
        })
        let result = await extensions.execute(.init(name: "app_transcription", arguments: [
            "attachment": .object(["download_url": "https://example.com/host-attachment", "file_id": "file_123", "file_name": "Interview.m4a"]), "start": true,
        ]))
        #expect(result.isError != true)
        let jobID = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        let ready = try await waitForJob(extensions, id: jobID)
        #expect(ready.structuredContent?.objectValue?["session_id"] == .string(sessionID))
        #expect(submissions.count == 1)
        let path = try #require(submissions.first?["path"] as? String)
        #expect(path.hasPrefix(root.appendingPathComponent("inputs").path + "/"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(submissions.first?["language"] == nil)
        #expect(submissions.first?["attachment"] == nil)
    }

    @Test func expiredAttachmentFailsWithoutSubmitting() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), inputRoot: root.appendingPathComponent("inputs"), attachmentDownloader: { request in
            let temporary = root.appendingPathComponent("download"); try Data().write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }, mediaExecutor: { _, _ in count += 1; return .error("Unexpected submission") })
        let result = await extensions.execute(.init(name: "app_transcription", arguments: [
            "attachment": .object(["download_url": "https://example.com/expired", "file_id": "file_123"]), "start": true,
        ]))
        let jobID = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        let failed = try await waitForJob(extensions, id: jobID)
        #expect(failed.isError == true)
        #expect(failed.structuredContent?.objectValue?["error"]?.stringValue?.contains("fresh attachment") == true)
        #expect(count == 0)
    }

    @Test func attachmentNamesAreSanitizedAndMissingExtensionsUseMediaType() throws {
        let descriptor = try MCPOpenAIExtensions.promptAttachment(["download_url": "https://example.com/media", "file_id": "file_1", "file_name": "../../Interview.WAV"])
        #expect(descriptor.name == "Interview.WAV")
        #expect(try MCPOpenAIExtensions.attachmentName(nil, mimeType: "audio/wav") == "Attached media.wav")
        #expect(throws: (any Error).self) { try MCPOpenAIExtensions.attachmentName("document.txt", mimeType: "text/plain") }
    }

    @Test func pickerReturnsBeforeUserInteractionAndCancellationCreatesNothing() async throws {
        var selection: CheckedContinuation<URL?, Never>?
        var submissions = 0
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), mediaExecutor: { _, _ in
            submissions += 1; return .error("Unexpected transcription")
        }, fileChooser: { media in
            #expect(media)
            return await withCheckedContinuation { selection = $0 }
        })
        // execute must return even though the chooser cannot complete yet.
        let result = await extensions.execute(.init(name: "media.choose_local_file"))
        #expect(result.structuredContent?.objectValue?["status"] == "selecting")
        let id = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        for _ in 0..<100 where selection == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(id)]))
        #expect(pending.structuredContent?.objectValue?["status"] == "selecting")
        #expect(pending.structuredContent?.objectValue?["asset_id"] == nil)
        let continuation = try #require(selection)
        continuation.resume(returning: nil)
        var cancelled = false
        for _ in 0..<100 {
            let status = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(id)]))
            if status.structuredContent?.objectValue?["status"] == "cancelled" {
                #expect(status.isError != true)
                #expect(status.structuredContent?.objectValue?["asset_id"] == nil)
                cancelled = true; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelled)
        #expect(submissions == 0)
    }

    @Test func pickerSelectionImportsReadyAssetWithoutTranscription() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var submissions = 0
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), inputRoot: root, mediaExecutor: { _, _ in
            submissions += 1; return .error("Unexpected transcription")
        }, fileChooser: { _ in fixture })
        let result = await extensions.execute(.init(name: "media.choose_local_file"))
        let id = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        var inputID: String?
        for _ in 0..<100 {
            let status = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(id)]))
            inputID = status.structuredContent?.objectValue?["asset_id"]?.stringValue
            if inputID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let assetID = try #require(inputID)
        var ready = false
        for _ in 0..<100 {
            let status = await extensions.execute(.init(name: "media.input_status", arguments: ["asset_id": .string(assetID)]))
            if status.structuredContent?.objectValue?["status"] == "ready" {
                #expect(status.structuredContent?.objectValue?["name"] == "fixture-audio.m4a")
                ready = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready)
        #expect(submissions == 0)
        let other = MCPOpenAIExtensions(server: Server(name: "other", version: "1"))
        let denied = await other.execute(.init(name: "media.input_status", arguments: ["asset_id": .string(assetID)]))
        #expect(denied.isError == true)
    }

    @Test func busyPickerReportsFailureWithoutCreatingAnInput() async throws {
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), fileChooser: { _ in
            throw MCPDocumentError("picker_busy", "A file picker is already open")
        })
        let result = await extensions.execute(.init(name: "media.choose_local_file"))
        let id = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        let failed = try await waitForJob(extensions, id: id)
        #expect(failed.isError == true)
        #expect(failed.structuredContent?.objectValue?["outcome"] == "picker_busy")
        #expect(failed.structuredContent?.objectValue?["asset_id"] == nil)
    }

    @Test func documentPickerResolvesToReadableManagedDocument() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("Selected document".utf8).write(to: file)
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), documentStore: MCPDocumentStore(root: root.appendingPathComponent("managed")), fileChooser: { media in
            #expect(!media)
            return file
        })
        let result = await extensions.execute(.init(name: "documents.choose_local_file"))
        let id = try #require(result.structuredContent?.objectValue?["job_id"]?.stringValue)
        var documentID: String?
        for _ in 0..<100 {
            let status = await extensions.execute(.init(name: "voxstudio.job_status", arguments: ["job_id": .string(id)]))
            documentID = status.structuredContent?.objectValue?["document_id"]?.stringValue
            if documentID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let granted = try #require(documentID)
        let read = await extensions.execute(.init(name: "documents.read", arguments: ["document_id": .string(granted)]))
        #expect(read.isError != true)
        #expect(read.structuredContent?.objectValue?["text"] == "Selected document")
    }

    @Test func slowSubmissionKeepsExactJobToSessionCorrelationWithoutRetry() async throws {
        var pending: CheckedContinuation<ToolResult, Never>?
        var submissions = 0
        let sessionID = UUID().uuidString
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), mediaExecutor: { _, _ in
            submissions += 1
            return await withCheckedContinuation { pending = $0 }
        })
        let result = await extensions.execute(.init(name: "app_transcription", arguments: ["path": .string(fixture.path), "start": true]))
        let initial = try #require(result.structuredContent?.objectValue)
        let id = try #require(initial["job_id"]?.stringValue)
        #expect(initial["session_id"] == nil)
        #expect(initial["next_call"]?.objectValue?["tool"] == "voxstudio.job_status")
        #expect(initial["next_call"]?.objectValue?["arguments"]?.objectValue?["job_id"] == .string(id))
        let continuation = try #require(pending)
        continuation.resume(returning: .ok("{\"session_id\":\"\(sessionID)\",\"status\":\"running\",\"title\":\"Renamed after import\"}"))
        let resolved = try await waitForJob(extensions, id: id)
        let data = try #require(resolved.structuredContent?.objectValue)
        #expect(data["job_id"] == .string(id))
        #expect(data["session_id"] == .string(sessionID))
        #expect(data["title"] == "Renamed after import")
        #expect(data["next_call"]?.objectValue?["arguments"]?.objectValue?["session_id"] == .string(sessionID))
        #expect(data["result_call"]?.objectValue?["arguments"]?.objectValue?["session_id"] == .string(sessionID))
        #expect(submissions == 1)
    }

    @Test func fastCreationFailureIsReportedBySubmissionItself() async throws {
        let extensions = MCPOpenAIExtensions(server: Server(name: "test", version: "1"), mediaExecutor: { _, _ in
            .error("Content admission unavailable")
        })
        let result = await extensions.execute(.init(name: "app_transcription", arguments: ["path": .string(fixture.path), "start": true]))
        #expect(result.isError == true)
        #expect(result.structuredContent?.objectValue?["error"]?.stringValue?.contains("Content admission unavailable") == true)
        #expect(result.structuredContent?.objectValue?["next_call"] == nil)
    }
}
