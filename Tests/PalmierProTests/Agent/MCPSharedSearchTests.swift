import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP shared search model")
@MainActor
struct MCPSharedSearchTests {
    @Test func discoveryAndUnavailableVisualSearchPreserveMedia() async throws {
        let harness = ToolHarness()
        let asset = harness.makeAsset(name: "isolated-search-fixture", type: .image)
        let server = Server(
            name: "shared-search-test", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "shared-search-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "search_media" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["query"]?.objectValue?["type"]?.stringValue == "string")

            let result = try await client.callTool(name: "search_media", arguments: [
                "query": .string("a red scene"),
                "scope": .string("visual"),
                "mediaRef": .string(asset.id)
            ])
            #expect(result.isError != true)
            let payload = try payload(result.content)
            #expect((payload["moments"] as? [Any])?.isEmpty == true)
            let index = try #require(payload["index"] as? [String: Any])
            #expect(index["indexableAssets"] as? Int == 1)
            #expect(index["status"] as? String != "ready")
            #expect((try await client.callTool(name: "search_media", arguments: [
                "query": .string(""), "scope": .string("visual")
            ])).isError == true)
            #expect(harness.editor.mediaAssets.map(\.id) == [asset.id])
            #expect(harness.editor.mediaManifest.entries.map(\.id) == [asset.id])
            #expect(harness.editor.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func payload(_ content: [Tool.Content]) throws -> [String: Any] {
        for item in content {
            if case .text(let text, _, _) = item {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
