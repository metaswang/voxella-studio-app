import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("App access MCP")
@MainActor
struct AppAccessMCPTests {
    @Test func expiredAccessRefusesGenerationWithoutMutation() async throws {
        let harness = ToolHarness()
        let executor = ToolExecutor(editor: harness.editor, requireNewContentAccess: { throw AppAccessError.trialExpired })
        let server = Server(name: "app-access-test", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "app-access-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "generate_image" })
            let result = try await client.callTool(name: "generate_image", arguments: ["prompt": .string("isolated fixture")])
            #expect(result.isError == true)
            #expect(result.content.contains { if case .text(let value, _, _) = $0 { return value == "trial_expired" }; return false })
            #expect(harness.editor.mediaAssets.isEmpty)
            #expect(harness.editor.mediaManifest.entries.isEmpty)
            #expect(harness.editor.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
