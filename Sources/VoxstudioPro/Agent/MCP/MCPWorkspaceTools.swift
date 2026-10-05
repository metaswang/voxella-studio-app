import Foundation
import MCP

/// Standard MCP Apps registration. OpenAI entrypoints are optional descriptor additions.
enum MCPAppPresentation {
    static let workspaceURI = "ui://voxstudio/workspace/v1"
    static func metadata(entry: Bool = false) -> Metadata {
        var fields: [String: Value] = ["ui": ["resourceUri": .string(workspaceURI)]]
        if entry { fields["openai/ui"] = ["entrypoints": [["type": "global"], ["type": "thread"]]] }
        return .init(additionalFields: fields)
    }
    static func resource(_ uri: String) throws -> ReadResource.Result {
        guard let url = Bundle.module.url(forResource: "workspace", withExtension: "html", subdirectory: "MCPApps") else { throw WorkspaceError("missing_ui", "Workspace UI is missing from this build") }
        return .init(contents: [.text(try String(contentsOf: url, encoding: .utf8), uri: uri, mimeType: "text/html;profile=mcp-app",
            _meta: .init(additionalFields: ["ui": ["csp": ["connectDomains": [], "resourceDomains": ["data:", "blob:"]], "prefersBorder": false]]))])
    }
}

@MainActor
final class MCPWorkspaceTools {
    nonisolated static let instructions = """
    VoxStudio provides session evidence, media workflows and the native video editor.
    Writes require a fresh UUID request_id. Preserve it across retries; receipts last one hour.
    Never retry an execution of unknown status after an app restart or receipt expiry.
    Use your own reasoning for knowledge questions. Do not call the app's answer model.
    When this client supports MCP Apps, first call app_knowledge with action=begin, query,
    a fresh UUID request_id, and the previous workspace_id for follow-up questions.
    Pass the returned workspace_id and turn_id together to evidence calls. Default scope
    is all authorized sessions; browsing a source does not restrict it. For 'this session',
    explicitly pass scope.source_ids from the UI reading context. Set an explicit scope only when the user asks to restrict sessions.
    Search candidates are not verified claims. Fetch current original spans before citing.
    Call knowledge.complete_turn with cited_evidence_ids and cited_observation_ids before
    your final answer, including no_evidence, clarification or failed when appropriate.
    Only UI entry tools have UI templates. Data calls update the open session/list panel.
    The panel reuses the session detail UI for a read source and the sessions list UI
    for session discovery or multi-session scopes. Use search target=sources to find
    sessions by title/topic, or list_sources for filtered catalog browsing. The UI has
    no knowledge dashboard or query-scope controls; scope is set from the user's chat.
    In clients without MCP Apps, call the evidence tools directly without workspace tokens;
    give the same grounded answer and citations. Never send navigation instructions as
    transcript content or manufacture user messages to open a panel. app_knowledge show
    resumes the panel without beginning another question. Methods are advisory guidance.
    """ + MCPKnowledgeBaseTools.instructions + MCPMediaTools.instructions

    let store: MCPWorkspaceStore
    private var uiSupport = "unknown"
    private let capture: (KnowledgeQAScope, Set<KnowledgeSourceOrigin>?) async -> KnowledgeScopeSnapshot
    init(store: MCPWorkspaceStore, capture: @escaping (KnowledgeQAScope, Set<KnowledgeSourceOrigin>?) async -> KnowledgeScopeSnapshot = { scope, origins in await KnowledgeScopeSnapshot.capture(scope: scope, origins: origins) }) {
        self.store = store; self.capture = capture
    }
    func initialize(_ capabilities: Client.Capabilities) {
        let ui = capabilities.extensions?["io.modelcontextprotocol/ui"]?.objectValue
        if ui?["mimeTypes"]?.arrayValue?.contains("text/html;profile=mcp-app") == true { uiSupport = "supported" }
        else if capabilities.extensions?["openai/ui"] != nil { uiSupport = "supported" }
        else { uiSupport = "unknown" }
    }
    nonisolated static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false]
    }
    nonisolated static var tools: [Tool] {
        let string: Value = ["type": "string"]
        let array: Value = ["type": "array", "items": ["type": "string"]]
        let scope: Value = schema(["source_ids": array, "origin": ["type": "string", "enum": ["all", "local", "cloud"]]])
        let common: [String: Value] = ["workspace_id": string, "turn_id": string]
        let entries: [(String, String, Value, Bool)] = [
            ("voxstudio.workspace", "Open the VoxStudio sessions list", schema([:]), true),
            ("app_workbench", "Open VoxStudio sessions (compatibility entry)", schema([:]), true),
            ("app_session", "Open the existing VoxStudio session detail UI", schema(["session_id": string], required: ["session_id"]), true),
            ("app_knowledge", "Show a simple session detail or sessions list alongside chat and begin a question; use show to resume. begin requires query and a fresh UUID request_id; preserve it when retrying.", schema([
                "action": ["type": "string", "enum": ["begin", "show"], "default": "show"], "query": string, "workspace_id": string,
                "turn_id": string, "request_id": string, "scope": scope]), true),
            ("knowledge.complete_turn", "Finalize this question's answer sources after successful original reads. Presentation only; does not generate an answer.", schema(common.merging([
                "cited_evidence_ids": array, "cited_observation_ids": array,
                "outcome": ["type": "string", "enum": ["answered", "no_evidence", "clarification", "failed"]]], uniquingKeysWith: { _, new in new }), required: ["workspace_id", "turn_id", "outcome"]), false),
            ("knowledge.workspace_state", "Read current or historical presentation state; page continues an observed sessions list in its frozen scope without changing the answer", schema(common.merging(["after_revision": ["type": "integer"], "page": schema(["observation_id": string, "cursor": string], required: ["observation_id", "cursor"])], uniquingKeysWith: { _, new in new }), required: ["workspace_id"]), false),
            ("knowledge.update_view", "Save reading focus and next-question scope without changing source documents", schema([
                "workspace_id": string, "expected_view_revision": ["type": "integer"], "view": schema([
                    "source_id": ["type": ["string", "null"]], "evidence_id": ["type": ["string", "null"]],
                    "material": ["type": "string", "enum": ["canonical", "subtitles", "translation"]], "language": string,
                    "reading_view": ["type": "string", "enum": ["body", "summary"]], "anchor": ["type": "integer"], "pinned": ["type": "boolean"], "manual_turn_id": ["type": ["string", "null"]], "next_scope": scope])
            ], required: ["workspace_id", "expected_view_revision", "view"]), false),
        ]
        let presentation = entries.map { name, description, input, ui in
            var meta: Metadata? = ui ? MCPAppPresentation.metadata(entry: name == "voxstudio.workspace") : nil
            if ["knowledge.workspace_state", "knowledge.update_view", "app_workbench"].contains(name) {
                let base = ui ? ["resourceUri": Value.string(MCPAppPresentation.workspaceURI), "visibility": ["app"]] : ["visibility": Value.array(["app"])]
                meta = .init(additionalFields: ["ui": .object(base)])
            }
            return Tool(name: name, description: description, inputSchema: input,
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: name != "app_knowledge" && name != "voxstudio.workspace", openWorldHint: false),
                outputSchema: ["type": "object"], _meta: meta)
        }
        let evidence = MCPKnowledgeBaseTools.tools.map { tool in
            var input = tool.inputSchema.objectValue!
            var properties = input["properties"]!.objectValue!
            properties.merge(common) { _, new in new }; input["properties"] = .object(properties)
            return Tool(name: tool.name, description: tool.description, inputSchema: .object(input), annotations: tool.annotations, outputSchema: tool.outputSchema)
        }
        return presentation + evidence
    }
    nonisolated static func validate(_ value: Value, schema: Value) throws {
        let fields = schema.objectValue ?? [:]
        let types = fields["type"]?.arrayValue?.compactMap(\.stringValue) ?? fields["type"]?.stringValue.map { [$0] } ?? []
        func matches(_ type: String) -> Bool {
            switch type {
            case "string": value.stringValue != nil
            case "integer": value.intValue != nil
            case "number": value.intValue != nil || value.doubleValue?.isFinite == true
            case "boolean": value.boolValue != nil
            case "object": value.objectValue != nil
            case "array": value.arrayValue != nil
            case "null": value.isNull
            default: false
            }
        }
        guard types.isEmpty || types.contains(where: matches), fields["enum"]?.arrayValue?.contains(value) != false else { throw WorkspaceError("invalid_argument", "Argument type or value is invalid") }
        if let object = value.objectValue, let properties = fields["properties"]?.objectValue {
            guard fields["additionalProperties"]?.boolValue != false || Set(object.keys).isSubset(of: Set(properties.keys)) else { throw WorkspaceError("invalid_argument", "Unknown argument") }
            for name in fields["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard object[name] != nil else { throw WorkspaceError("invalid_argument", "Missing " + name) }
            }
            for (key, item) in object { if let schema = properties[key] { try validate(item, schema: schema) } }
        }
        if let array = value.arrayValue, let items = fields["items"] { for item in array { try validate(item, schema: items) } }
    }
    nonisolated static func scope(_ value: Value) throws -> (KnowledgeQAScope, Set<KnowledgeSourceOrigin>?) {
        guard let fields = value.objectValue, Set(fields.keys).isSubset(of: ["source_ids", "origin"]) else { throw WorkspaceError("invalid_scope", "Invalid query scope") }
        var scope: KnowledgeQAScope = .all
        if let raw = fields["source_ids"] {
            guard let rows = raw.arrayValue, !rows.isEmpty, rows.count <= 100 else { throw WorkspaceError("invalid_scope", "Select 1...100 sessions") }
            let ids = rows.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            guard ids.count == rows.count, Set(ids).count == ids.count else { throw WorkspaceError("invalid_scope", "Invalid or duplicate session IDs") }
            scope = .sessions(ids)
        }
        var origins: Set<KnowledgeSourceOrigin>?
        if let origin = fields["origin"] {
            guard let string = origin.stringValue, ["all", "local", "cloud"].contains(string) else { throw WorkspaceError("invalid_scope", "Invalid origin") }
            if let parsed = KnowledgeSourceOrigin(rawValue: string) { origins = Set([parsed]) }
        }
        return (scope, origins)
    }
    nonisolated static func result(_ value: Value, error: Bool = false) -> CallTool.Result {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return .init(content: [.text(text)], structuredContent: Optional.some(value), isError: error ? true : nil)
    }
    func execute(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        let args = parameters.arguments ?? [:]
        do {
            let name = parameters.name
            guard let tool = Self.tools.first(where: { $0.name == name }) else { throw WorkspaceError("invalid_argument", "Unknown tool") }
            try Self.validate(.object(args), schema: tool.inputSchema)
            let workspaceID = args["workspace_id"]?.stringValue
            if name == "app_knowledge" || name == "voxstudio.workspace" || name == "app_workbench" || name == "app_session" {
                let action = args["action"]?.stringValue ?? "show"
                guard action == "show" || action == "begin" else { throw WorkspaceError("invalid_argument", "Invalid action") }
                let access = await capture(.all, nil)
                var id = workspaceID
                if action == "begin" {
                    guard let requestID = args["request_id"]?.stringValue, UUID(uuidString: requestID) != nil,
                          let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 16000 else {
                        throw WorkspaceError("invalid_argument", "begin requires a nonempty query and a UUID request_id")
                    }
                    if id == nil { id = try await store.receiptWorkspace(requestID: requestID) }
                    if let id, let previous = try await store.resumeBegin(id: id, requestID: requestID, query: query, scope: args["scope"]) {
                        var fields = previous.objectValue!; fields["ui_support"] = .string(uiSupport)
                        return Self.result(.object(fields))
                    }
                    if id == nil {
                        let opened = try await store.open(id: nil, snapshot: access)
                        id = opened.objectValue!["workspace_id"]!.stringValue!
                    }
                    let selected = if let supplied = args["scope"] { supplied } else { try await store.nextScope(id: id!) }
                    let (scope, origins) = try Self.scope(selected)
                    let snapshot = await capture(scope, origins)
                    if scope != .all, Set(snapshot.sessions.map(\.id)) != Set(scope.sessionIDs) { throw WorkspaceError("unauthorized_source", "Selected session is unavailable") }
                    var result = try await store.begin(id: id!, query: query, scope: selected, snapshot: snapshot, requestID: requestID).objectValue!
                    result["ui_support"] = .string(uiSupport)
                    return Self.result(.object(result))
                }
                var result = try await store.open(id: id, snapshot: access)
                if let source = args["session_id"]?.stringValue {
                    let fields = result.objectValue!
                    result = try await store.updateView(id: fields["workspace_id"]!.stringValue!, expected: fields["view_revision"]!.intValue!, values: ["source_id": .string(source)])
                }
                if let turn = args["turn_id"]?.stringValue { result = try await store.state(id: result.objectValue!["workspace_id"]!.stringValue!, turnID: turn, after: nil) }
                var fields = result.objectValue!; fields["ui_support"] = .string(uiSupport)
                return Self.result(.object(fields))
            }
            if name == "knowledge.workspace_state" {
                if let page = args["page"]?.objectValue {
                    let (snapshot, parameters) = try await store.listingPage(id: try requiredString(args, "workspace_id"), turnID: try requiredString(args, "turn_id"), observationID: try requiredString(page, "observation_id"), cursor: try requiredString(page, "cursor"))
                    let result = await MCPKnowledgeBaseTools.execute(name: "list_sources", args: ToolArgsBridge.argsFromMCP(parameters), snapshot: snapshot)
                    if result.isError == true { return result }
                    return Self.result(["page": result.structuredContent ?? .object([:])])
                }
                return Self.result(try await store.state(id: try requiredString(args, "workspace_id"), turnID: args["turn_id"]?.stringValue, after: args["after_revision"]?.intValue))
            }
            if name == "knowledge.update_view" {
                guard let view = args["view"]?.objectValue, let revision = args["expected_view_revision"]?.intValue else { throw WorkspaceError("invalid_argument", "Invalid view or revision") }
                return Self.result(try await store.updateView(id: try requiredString(args, "workspace_id"), expected: revision, values: view))
            }
            if name == "knowledge.complete_turn" {
                return Self.result(try await store.finish(id: try requiredString(args, "workspace_id"), turnID: try requiredString(args, "turn_id"),
                    evidence: try strings(args, "cited_evidence_ids"), observations: try strings(args, "cited_observation_ids"), outcome: try requiredString(args, "outcome")))
            }
            let turnID = args["turn_id"]?.stringValue
            guard (workspaceID == nil) == (turnID == nil), args["workspace_id"] == nil || workspaceID != nil,
                  args["turn_id"] == nil || turnID != nil else { throw WorkspaceError("invalid_argument", "Supply workspace_id and turn_id together") }
            var dataArgs = args; dataArgs.removeValue(forKey: "workspace_id"); dataArgs.removeValue(forKey: "turn_id")
            let operation: MCPWorkspaceStore.Operation? = if let workspaceID, let turnID { try await store.startOperation(id: workspaceID, turnID: turnID) } else { nil }
            let result = await MCPKnowledgeBaseTools.execute(name: name, args: ToolArgsBridge.argsFromMCP(dataArgs), snapshot: operation?.snapshot)
            if let operation, let content = result.structuredContent {
                let observation = try await store.record(operation, name: name, arguments: dataArgs, result: content, isError: result.isError == true)
                var fields = content.objectValue ?? [:]
                fields["workspace_id"] = .string(operation.workspaceID); fields["turn_id"] = .string(operation.turnID)
                if let observation { fields["observation_id"] = .string(observation) }
                return Self.result(.object(fields), error: result.isError == true)
            }
            return result
        } catch {
            return Self.result(["status": "error", "complete": false, "code": .string((error as? WorkspaceError)?.code ?? "materials_changed"), "error": .string(error.localizedDescription)], error: true)
        }
    }
    private func requiredString(_ args: [String: Value], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else { throw WorkspaceError("invalid_argument", "Missing or invalid " + key) }; return value
    }
    private func strings(_ args: [String: Value], _ key: String) throws -> [String] {
        guard let value = args[key] else { return [] }
        guard let array = value.arrayValue, array.count <= 128, array.allSatisfy({ $0.stringValue != nil }) else { throw WorkspaceError("invalid_argument", "Invalid " + key) }
        return array.compactMap(\.stringValue)
    }
}
