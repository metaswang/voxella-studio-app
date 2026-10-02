import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private static let enabledKey = "io.voxstudio.mcp.enabled"
    private static let legacyEnabledKey = "io.palmier.pro.mcp.enabled"

    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil {
                return defaults.object(forKey: legacyEnabledKey) == nil ? true : defaults.bool(forKey: legacyEnabledKey)
            }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    private(set) var isRunning: Bool = false

    @ObservationIgnored
    private let projectProvider: () -> VideoProject?
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?

    init(projectProvider: @escaping () -> VideoProject?) {
        self.projectProvider = projectProvider
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [self] in
            let toolExecutor = await makeSessionToolExecutor()
            let server = Server(
                name: "voxstudio",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions + AgentInstructions.projectNavigation + MCPKnowledgeTools.instructions + MCPMediaTools.instructions,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: true)
                )
            )
            let extensions = await MCPOpenAIExtensions(server: server)
            await Self.registerTools(on: server, executor: toolExecutor, extensions: extensions)
            await Self.registerResources(on: server, extensions: extensions)
            return MCPServerInstance(server: server) { clientInfo, capabilities in
                await extensions.initialize(capabilities)
                await toolExecutor.setMCPClientInfo(MCPClientInfo(clientInfo))
            }
        }
        self.httpServer = httpServer
        Task { @MainActor [weak self] in
            do {
                try await httpServer.start()
                Log.mcp.notice("http server started port=\(Self.port)")
                self?.isRunning = true
            } catch {
                Log.mcp.error("http server failed to start: \(error.localizedDescription)")
                self?.isRunning = false
            }
        }
    }

    func makeSessionToolExecutor() -> ToolExecutor {
        ToolExecutor(projectProvider: projectProvider)
    }

    func stop() {
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
        isRunning = false
        Log.mcp.notice("http server stopped")
    }

    nonisolated static func registerTools(on server: Server, executor: ToolExecutor, extensions: MCPOpenAIExtensions? = nil) async {
        let tools: [Tool] = ToolDefinitions.mcpServer.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        let allTools = (tools + MCPKnowledgeTools.tools + MCPMediaTools.tools).map(Self.annotate) + (extensions == nil ? [] : MCPOpenAIExtensions.tools)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: allTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await dispatchCall(params, executor: executor, extensions: extensions)
        }
    }

    nonisolated private static func annotate(_ tool: Tool) -> Tool {
        let readOnly = Set(["get_project", "get_clip", "list_media", "voice.list", "media.status", "session.list", "session.get", "session.transcript", "session.search", "knowledge.search", "knowledge.find_text", "knowledge.ask"])
        return Tool(name: tool.name, title: tool.title, description: tool.description, inputSchema: tool.inputSchema, annotations: .init(readOnlyHint: readOnly.contains(tool.name), destructiveHint: !readOnly.contains(tool.name), idempotentHint: readOnly.contains(tool.name), openWorldHint: true), outputSchema: tool.outputSchema, _meta: tool._meta)
    }

    // Convert args on the main actor so the non-Sendable dict never crosses the hop.
    private static func dispatchCall(_ params: CallTool.Parameters, executor: ToolExecutor, extensions: MCPOpenAIExtensions?) async -> CallTool.Result {
        if let extensions, MCPOpenAIExtensions.tools.contains(where: { $0.name == params.name }) { return await extensions.execute(params) }
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        if MCPMediaTools.definitions.contains(where: { $0.name == params.name }) {
            let result = MCPOpenAIExtensions.adapted(await MCPMediaTools.execute(name: params.name, args: args))
            if params.name == "media.preview", let extensions {
                do { return try extensions.registerPreview(result) }
                catch { return .init(content: [.text(error.localizedDescription)], isError: true) }
            }
            return result
        }
        if MCPKnowledgeTools.definitions.contains(where: { $0.name == params.name }) {
            return MCPOpenAIExtensions.adapted(await MCPKnowledgeTools.execute(name: params.name, args: args))
        }
        let result = await executor.execute(name: params.name, args: args, source: "mcp")
        return result.toMCPResult()
    }

    private nonisolated static func registerResources(on server: Server, extensions: MCPOpenAIExtensions) async {
        let resources = MCPOpenAIExtensions.uiResources.map { Resource(name: $0.name, uri: $0.uri, mimeType: "text/html;profile=mcp-app") } + [
            Resource(
                name: "Video Models",
                uri: "voxstudio://models/video",
                description: "Available AI video generation models and their capabilities",
                mimeType: "application/json"
            ),
            Resource(
                name: "Image Models",
                uri: "voxstudio://models/image",
                description: "Available AI image generation models and their capabilities",
                mimeType: "application/json"
            ),
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            if params.uri.hasPrefix("ui://") || params.uri.hasPrefix("voxstudio://sessions/") || params.uri.hasPrefix("voxstudio://documents/") || params.uri.hasPrefix("voxstudio://previews/") { return try await extensions.readResource(params.uri) }
            return await Self.readResource(uri: params.uri)
        }
    }

    @MainActor
    private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "voxstudio://models/video", "palmier://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "voxstudio://models/image", "palmier://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
