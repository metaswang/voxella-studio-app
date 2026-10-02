import Foundation
import Testing
@testable import MCP

@Suite("VoxStudio outgoing extensions")
struct VoxStudioExtensionsTests {
    @Test func nestedCapabilitiesRoundtrip() throws {
        let data = Data(#"{"extensions":{"openai/elicitation":{"form":{}}},"experimental":{"unknown":{"nested":[true,2,"x"]}}}"#.utf8)
        let client = try JSONDecoder().decode(Client.Capabilities.self, from: data)
        #expect(client.extensions?["openai/elicitation"]?.objectValue?["form"]?.objectValue != nil)
        #expect(try JSONDecoder().decode(Client.Capabilities.self, from: JSONEncoder().encode(client)) == client)
        let old = try JSONDecoder().decode(Client.Capabilities.self, from: Data("{}".utf8))
        #expect(old.extensions == nil)
        let server = Server.Capabilities(extensions: ["test": .object(["nested": true])])
        #expect(try JSONDecoder().decode(Server.Capabilities.self, from: JSONEncoder().encode(server)) == server)
    }
    @Test(arguments: ["cancel", "timeout", "stop", "disconnect", "send_failure"])
    func waitingEnds(_ kind: String) async throws {
        let transport = MockTransport(), server = Server(name: "test", version: "1")
        try await server.start(transport: transport)
        if kind == "send_failure" { await transport.setFailSend(true) }
        let request = Ping.request()
        let context = try await server.sendRequest(request, timeout: kind == "timeout" ? .milliseconds(1) : .seconds(1))
        if kind == "cancel" { try await server.cancelRequest(request.id) }
        if kind == "stop" { await server.stop() }
        if kind == "disconnect" { await transport.disconnect() }
        do { _ = try await context.value; Issue.record("Pending request unexpectedly succeeded") } catch {}
        await server.stop()
    }
    @Test func successfulAndDuplicateResponses() async throws {
        let transport = MockTransport(), server = Server(name: "test", version: "1")
        try await server.start(transport: transport)
        let request = Ping.request()
        let context = try await server.sendRequest(request, timeout: .seconds(1))
        while await transport.sentData.isEmpty { await Task.yield() }
        let response = Ping.response(id: request.id, result: Empty())
        try await transport.queue(response: response)
        _ = try await context.value
        try await transport.queue(response: response)
        await server.stop()
    }
    @Test func parentCancellationUnblocks() async throws {
        let transport = MockTransport(), server = Server(name: "test", version: "1")
        try await server.start(transport: transport)
        let context = try await server.sendRequest(Ping.request(), timeout: .seconds(1))
        let parent = Task { try await context.value }
        parent.cancel()
        do { _ = try await parent.value; Issue.record("Cancelled parent succeeded") } catch {}
        await server.stop()
    }
}
