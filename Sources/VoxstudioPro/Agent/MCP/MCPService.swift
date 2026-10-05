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
    @ObservationIgnored
    private let workspaces = MCPWorkspaceStore()
    @ObservationIgnored
    private let mutationReceipts = MCPMutationReceipts()
    @ObservationIgnored
    private var profileWorkspaces: [MCPServerProfile: MCPWorkspaceStore] = [:]
    @ObservationIgnored
    private var profileReceipts: [MCPServerProfile: MCPMutationReceipts] = [:]
    private static let receiptEpoch = UUID().uuidString

    init(projectProvider: @escaping () -> VideoProject?) {
        self.projectProvider = projectProvider
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port, makeKnowledgeServer: {
            await MCPKnowledgeBaseTools.makeServer()
        }, makeAppServer: { [self] in
            await makeAppServer()
        }, makeCoreServer: { [self] in
            await makeAppServer(profile: .chatgpt)
        }, makeNativeServer: { [self] in
            await makeAppServer(profile: .native)
        }) { [self] in
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

    func makeAppServer(profile: MCPServerProfile = .app) async -> MCPServerInstance {
        let executor = makeSessionToolExecutor()
        let store: MCPWorkspaceStore
        let receipts: MCPMutationReceipts
        if profile == .app { store = workspaces; receipts = mutationReceipts }
        else {
            if profileWorkspaces[profile] == nil { profileWorkspaces[profile] = MCPWorkspaceStore() }
            if profileReceipts[profile] == nil { profileReceipts[profile] = MCPMutationReceipts() }
            store = profileWorkspaces[profile]!; receipts = profileReceipts[profile]!
        }
        let instructions = profile == .chatgpt ? MCPToolCatalog.coreInstructions : profile == .native
            ? "Local VoxStudio native editing. Reread real session/project IDs to validate access; temporary workspace, turn, document, input, job and preview grants belong to this connection. Writes require UUID request_id, preserved on retries within one hour and the same App lifetime. Inspect current versions before editing; use existing undo and conflict checks. " + AgentInstructions.serverInstructions + AgentInstructions.projectNavigation
            : MCPWorkspaceTools.instructions
        let server = Server(name: profile == .native ? "voxstudio_native" : "voxstudio", version: "2.1.0+" + Self.receiptEpoch, instructions: instructions,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        let extensions = MCPOpenAIExtensions(server: server)
        let workspaceTools = MCPWorkspaceTools(store: store)
        let native = ToolDefinitions.mcpServer.map { Tool(name: $0.name.rawValue, description: $0.description, inputSchema: $0.mcpSchemaValue) }
        let excluded = Set(["app_workbench", "voxstudio.library", "app_session", "voxstudio.session_panel"])
        let panels = MCPOpenAIExtensions.tools.filter { !excluded.contains($0.name) }.map { tool in
            ["media.session_preview", "media.asset_preview"].contains(tool.name) ? Tool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema, annotations: .init(readOnlyHint: true), outputSchema: tool.outputSchema, _meta: tool._meta) : MCPMutationReceipts.tool(tool)
        }
        // The legacy session panel still uses this app-only read after media workflows.
        let summary = MCPKnowledgeTools.tools.filter { $0.name == "session.get_summary" }.map { tool in
            Tool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema, annotations: tool.annotations,
                _meta: .init(additionalFields: ["ui": ["visibility": ["app"]]]))
        }
        let fullTools = (native + MCPMediaTools.tools).map(Self.annotateApp).map(MCPMutationReceipts.tool) + panels + summary + MCPWorkspaceTools.tools
        let allTools = profile == .chatgpt ? MCPToolCatalog.coreTools(from: fullTools)
            : profile == .native ? MCPToolCatalog.nativeTools(from: fullTools) : fullTools
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: allTools) }
        await server.withMethodHandler(CallTool.self) { params in
            guard allTools.contains(where: { $0.name == params.name }) else {
                return .init(content: [.text("Unknown tool for this MCP profile: " + params.name)], isError: true)
            }
            if profile == .chatgpt || profile == .native {
                do { try MCPWorkspaceTools.validate(.object(params.arguments ?? [:]), schema: allTools.first { $0.name == params.name }!.inputSchema) }
                catch { return MCPWorkspaceTools.result(["error": .string(error.localizedDescription)], error: true) }
            }
            func decorated(_ result: CallTool.Result) -> CallTool.Result {
                var result = profile == .chatgpt ? MCPToolCatalog.coreResult(result) : result
                if profile == .chatgpt, params.name == "session.editor.read", var fields = result.structuredContent?.objectValue {
                    fields["editable"] = false
                    result = MCPWorkspaceTools.result(.object(fields), error: result.isError == true)
                }
                var meta = result._meta?.fields ?? [:]
                meta["voxstudio/receiptTools"] = .array(allTools.filter { $0.annotations.readOnlyHint != true }.map { .string($0.name) })
                result._meta = .init(additionalFields: meta)
                return result
            }
            if MCPWorkspaceTools.tools.contains(where: { $0.name == params.name }) { return decorated(await workspaceTools.execute(params)) }
            if allTools.first(where: { $0.name == params.name })?.annotations.readOnlyHint != true {
                let result = await receipts.execute(params, context: extensions) {
                    var arguments = params.arguments ?? [:]
                    let original = (native + MCPMediaTools.tools + MCPOpenAIExtensions.tools).first { $0.name == params.name }
                    if original?.inputSchema.objectValue?["properties"]?.objectValue?["request_id"] == nil { arguments.removeValue(forKey: "request_id") }
                    return await Self.dispatchCall(.init(name: params.name, arguments: arguments, meta: params._meta), executor: executor, extensions: extensions)
                }
                return decorated(result)
            }
            return decorated(await Self.dispatchCall(params, executor: executor, extensions: extensions))
        }
        let receiptToolNames = allTools.filter { $0.annotations.readOnlyHint != true }.map(\.name)
        extensions.receiptToolNames = receiptToolNames
        await Self.registerResources(on: server, extensions: extensions, unified: true, profile: profile, receiptTools: receiptToolNames)
        return MCPServerInstance(server: server) { client, capabilities in
            await extensions.initialize(capabilities)
            await workspaceTools.initialize(capabilities)
            await executor.setMCPClientInfo(MCPClientInfo(client))
        }
    }

    func stop() {
        Task { await workspaces.clear() }
        for store in profileWorkspaces.values { Task { await store.clear() } }
        profileWorkspaces.removeAll(); profileReceipts.removeAll()
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

    nonisolated private static func annotateApp(_ tool: Tool) -> Tool {
        let reads = Set(["get_timeline", "inspect_timeline", "get_media", "inspect_media", "search_media", "get_multicam", "get_transcript", "inspect_color", "list_models", "read_skill", "voice.list", "media.status", "media.preview", "media.search"])
        if reads.contains(tool.name) {
            return Tool(name: tool.name, title: tool.title, description: tool.description, inputSchema: tool.inputSchema, annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false), outputSchema: tool.outputSchema, _meta: tool._meta)
        }
        return annotate(tool)
    }

    nonisolated private static func annotate(_ tool: Tool) -> Tool {
        let readOnly = Set(MCPKnowledgeTools.definitions.map(\.name) + ["get_project", "get_clip", "list_media", "voice.list", "media.status", "session.list", "session.get", "session.transcript", "session.search", "knowledge.search", "knowledge.find_text", "knowledge.ask"])
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

    private nonisolated static func registerResources(on server: Server, extensions: MCPOpenAIExtensions, unified: Bool = false, profile: MCPServerProfile = .legacy, receiptTools: [String]? = nil) async {
        let resources = (unified ? [Resource(name: "VoxStudio workspace", uri: MCPAppPresentation.workspaceURI, mimeType: "text/html;profile=mcp-app")] : []) + MCPOpenAIExtensions.uiResources.map { Resource(name: $0.name, uri: $0.uri, mimeType: "text/html;profile=mcp-app") } + (profile == .chatgpt ? [] : [
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
        ])

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            if unified, ([MCPAppPresentation.workspaceURI] + MCPAppPresentation.legacyWorkspaceURIs).contains(params.uri) { return try MCPAppPresentation.resource(params.uri, receiptTools: receiptTools) }
            if params.uri.hasPrefix("ui://") || params.uri.hasPrefix("voxstudio://sessions/") || params.uri.hasPrefix("voxstudio://documents/") || params.uri.hasPrefix("voxstudio://previews/") { return try await extensions.readResource(params.uri) }
            if profile == .chatgpt { return .init(contents: [.text("Unknown core resource", uri: params.uri)]) }
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
