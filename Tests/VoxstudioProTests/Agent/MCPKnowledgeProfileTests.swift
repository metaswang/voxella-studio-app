import Foundation
import MCP
import Testing
@testable import VoxstudioPro

struct MCPKnowledgeProfileTests {
    private static func instance(_ name: String) async -> MCPServerInstance {
        let server = Server(name: name, version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [.init(name: name, description: name, inputSchema: .object(["type": .string("object")]))])
        }
        return MCPServerInstance(server: server) { _ in }
    }

    @Test func statefulAndStatelessProfilesCannotShareToolInventoryOrSessionIDs() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let server = MCPHTTPServer(port: port, makeKnowledgeServer: { await Self.instance("knowledge_only") }, makeAppServer: { await Self.instance("app_only") }) {
            await Self.instance("media_only")
        }
        try await server.start()
        defer { Task { await server.stop() } }
        let initialized = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let legacy = try await request(port, "/mcp", initialized)
        let knowledge = try await request(port, "/knowledge/mcp", initialized)
        let app = try await request(port, "/app/mcp", initialized)
        let appID = try #require(app.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let legacyID = try #require(legacy.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let knowledgeID = try #require(knowledge.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
        #expect(legacyID != knowledgeID)
        for (path, session, name, excluded) in [("/mcp", legacyID, "media_only", "knowledge_only"),
                                               ("/knowledge/mcp", knowledgeID, "knowledge_only", "media_only"), ("/app/mcp", appID, "app_only", "knowledge_only")] {
            for id in [Optional(session), nil] {
                let response = try await request(port, path, list, session: id)
                #expect(response.1.statusCode == 200)
                #expect(response.0.contains(name))
                #expect(!response.0.contains(excluded))
            }
        }
        let crossLegacy = try await request(port, "/mcp", list, session: knowledgeID)
        let crossKnowledge = try await request(port, "/knowledge/mcp", list, session: legacyID)
        #expect(crossLegacy.1.statusCode == 404)
        #expect(crossKnowledge.1.statusCode == 404)
        #expect(try await request(port, "/app/mcp", list, session: legacyID).1.statusCode == 404)
        #expect(try await request(port, "/mcp", list, session: appID).1.statusCode == 404)
        let unknown = try await request(port, "/unknown", list)
        #expect(unknown.1.statusCode == 404)
    }

    private func request(_ port: UInt16, _ path: String, _ body: String, session: String? = nil) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (String(decoding: data, as: UTF8.self), try #require(response as? HTTPURLResponse))
    }
}

struct MCPUnifiedInventoryTests {
    @Test @MainActor func fullProfileProvidesStandardUIAndTypedEditorWithoutLegacyQA() async throws {
        let service=MCPService(projectProvider:{nil}),port=UInt16.random(in:49_500...64_000)
        let http=MCPHTTPServer(port:port,makeAppServer:{await service.makeAppServer()}) {await service.makeAppServer()}
        try await http.start();defer{Task{await http.stop()}}
        func rpc(_ method:String,_ params:Value = [:]) async throws -> Value {
            var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/app/mcp")!)
            request.httpMethod="POST";request.timeoutInterval=10
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("application/json, text/event-stream",forHTTPHeaderField:"Accept")
            request.setValue("2025-06-18",forHTTPHeaderField:"MCP-Protocol-Version")
            request.httpBody=try JSONEncoder().encode(Value.object(["jsonrpc":"2.0","id":1,"method":.string(method),"params":params]))
            let (bytes,_)=try await URLSession.shared.data(for:request)
            let raw=String(decoding:bytes,as:UTF8.self)
            let json=raw.hasPrefix("{") ? raw : raw.components(separatedBy:"\n").first{$0.hasPrefix("data: {")}!.dropFirst(6).description
            let decoded=try JSONDecoder().decode(Value.self,from:Data(json.utf8))
            return try #require(decoded.objectValue?["result"])
        }
        let result=try await rpc("tools/list"),tools=try #require(result.objectValue?["tools"]?.arrayValue)
        let names=tools.compactMap{$0.objectValue?["name"]?.stringValue}
        #expect(Set(names).count==names.count)
        #expect(["search","fetch","aggregate","app_knowledge","voxstudio.workspace","get_timeline","set_clip_properties","media.status"].allSatisfy(names.contains))
        #expect(!names.contains("knowledge.ask"));#expect(!names.contains("knowledge.search"))
        let mutation=try #require(tools.first{$0.objectValue?["name"]?.stringValue=="set_clip_properties"})
        #expect(mutation.objectValue?["inputSchema"]?.objectValue?["required"]?.arrayValue?.contains("request_id")==true)
        let commit=try #require(tools.first{$0.objectValue?["name"]?.stringValue=="session.editor.commit"})
        #expect(commit.objectValue?["inputSchema"]?.objectValue?["required"]?.arrayValue?.filter{$0=="request_id"}.count==1)
        let resource=try await rpc("resources/read",["uri":.string(MCPAppPresentation.workspaceURI)])
        let content=try #require(resource.objectValue?["contents"]?.arrayValue?.first?.objectValue)
        #expect(content["mimeType"]=="text/html;profile=mcp-app")
        #expect(content["text"]?.stringValue?.contains("voxstudio-session-companion-v1")==true)
    }
}
