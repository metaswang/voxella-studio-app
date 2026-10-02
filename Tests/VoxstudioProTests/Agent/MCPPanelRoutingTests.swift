import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("MCP focused panel routing")
struct MCPPanelRoutingTests {
    @Test func taskPanelsAreIndependentAndDataReadsDoNotOpenUI() throws {
        let names = ["app_workbench", "app_transcription", "app_session", "app_dubbing"]
        let tools = MCPOpenAIExtensions.tools
        let uris = try names.map { name in
            let tool = try #require(tools.first { $0.name == name })
            return try #require(tool._meta?["ui"]?.objectValue?["resourceUri"]?.stringValue)
        }
        #expect(Set(uris).count == names.count)
        #expect(Set(uris) == Set(MCPOpenAIExtensions.uiResources.map(\.uri)))
        let dataTool = try #require(tools.first { $0.name == "voxstudio.sessions" })
        #expect(dataTool._meta?["ui"]?.objectValue?["resourceUri"] == nil)
        #expect(dataTool._meta?["ui"]?.objectValue?["visibility"] == ["app"])
    }
    @Test func videoEditingUsesNativeToolsWithoutHTML() {
        #expect(MCPOpenAIExtensions.panelURI(for: "app_video_editor") == nil)
        #expect(!MCPOpenAIExtensions.uiResources.contains { $0.uri.contains("/video/") })
        #expect(!MCPOpenAIExtensions.tools.contains { $0.name == "app_video_editor" })
        let native = Set(ToolDefinitions.mcpServer.map { $0.name.rawValue })
        #expect(Set(["manage_project", "get_timeline", "import_media", "set_clip_properties", "split_clips", "export_project", "undo"]).isSubset(of: native))
    }
    @Test func linkedVoiceoverDoesNotHideTranscriptAndDurationMatchesNativeSession() {
        let id = UUID()
        var session = WorkbenchSession(id: id, title: "Transcript with voiceover", createdAt: Date(), modifiedAt: Date(),
            state: .completed, source: .media, sessionType: .upload, transcriptionID: id, dubID: UUID(),
            sourceURL: nil, outputURL: nil,
            transcript: .init(text: "A recorded conversation", language: "en", words: [],
                segments: [.init(text: "A recorded conversation", start: 0, end: 18)]),
            subtitleTrack: nil, translationTracks: [], selectedTranslationLanguageCode: nil,
            summaryMarkdown: nil, summaryTemplateID: nil, summaryTemplateName: nil, summaryState: nil,
            summaryErrorMessage: nil, sessionTag: nil, dubTranscript: nil, dubSubtitleTrack: nil, dubSegments: [],
            remoteSessionID: nil, cloudSyncError: nil)
        let transcript = MCPOpenAIExtensions.sessionSummary(session)
        #expect(transcript["kind"] as? String == "transcription")
        #expect(transcript["session_id"] as? String == id.uuidString)
        #expect(transcript["duration"] as? Double == 18)
        session.source = .standaloneDub
        #expect(MCPOpenAIExtensions.sessionSummary(session)["kind"] as? String == "dubbing")
    }
    @Test @MainActor func sessionPanelRejectsMissingOrUnknownSessionAndInputGrants() async throws {
        let server = Server(name: "test", version: "1")
        let extensions = MCPOpenAIExtensions(server: server)
        let missing = await extensions.execute(.init(name: "app_session", arguments: [:]))
        #expect(missing.isError == true)
        let unknown = await extensions.execute(.init(name: "app_session", arguments: ["session_id": .string(UUID().uuidString)]))
        #expect(unknown.isError == true)
        let cancelFreeEntry = await extensions.execute(.init(name: "app_transcription", arguments: [:]))
        #expect(cancelFreeEntry.isError != true)
        #expect(cancelFreeEntry.structuredContent?.objectValue?["view"] == "transcription")
    }
}
