import Foundation
import MCP

/// Project-independent adapter over the same tools and answer pipeline as Knowledge Chat.
enum MCPKnowledgeTools {
    static let instructions = """

    Knowledge base tools work without an open video project. Use knowledge.ask for a complete
    grounded answer, or knowledge.search and session.* to inspect evidence yourself. Pass history
    to knowledge.ask for follow-up questions. These calls do not modify the app's chat history.
    Source visibility follows the current account; origin optionally restricts local/cloud sources.
    """

    // Only expose the read/query surface through the MCP adapter. Native agent
    // internals such as payload reads, skill loading, and analysis mutation are
    // authorized by the in-app evidence workspace and must stay private here.
    static let definitions = KnowledgeToolRegistry.allTools.filter { definition in
        !["read_payload", "read_skill", "analysis.update", "ask_clarification"].contains(definition.name)
    } + [
        KnowledgeToolDefinition(name: "knowledge.ask", description: "Ask the existing knowledge chatbot a question. Returns an answer with citations, clarification or recovery actions. Supports multi-turn history and optional session scope.", parameters: [
            .init(name: "query", type: "string", description: "Question to answer", required: true),
            .init(name: "session_ids", type: "array", description: "Optional non-empty list of session UUIDs", required: false),
            .init(name: "answer_mode", type: "string", description: "concise, normal, or detailed", required: false),
            .init(name: "allow_cloud", type: "boolean", description: "Allow cloud model routing (default true)", required: false),
            .init(name: "history", type: "array", description: "Previous user/assistant messages with role and content", required: false),
        ])
    ]

    static var tools: [Tool] {
        definitions.map { definition in
            var properties: [String: Value] = [:]
            for parameter in definition.parameters {
                var schema: [String: Value] = ["type": .string(parameter.type), "description": .string(parameter.description)]
                if parameter.type == "array" {
                    schema["items"] = parameter.name == "history" ? .object([
                        "type": "object",
                        "properties": .object([
                            "role": .object(["type": "string", "enum": .array(["user", "assistant"])]),
                            "content": .object(["type": "string"]),
                        ]),
                        "required": .array(["role", "content"]),
                        "additionalProperties": false,
                    ]) : .object(["type": "string"])
                }
                properties[parameter.name] = .object(schema)
            }
            properties["origin"] = .object(["type": "string", "enum": .array(["all", "local", "cloud"])])
            return Tool(name: definition.name, description: definition.description, inputSchema: .object([
                "type": "object", "properties": .object(properties),
                "required": .array(definition.parameters.filter(\.required).map { .string($0.name) }),
                "additionalProperties": false,
            ]))
        }
    }

    @MainActor
    static func execute(name: String, args: [String: Any], qaService: KnowledgeQAService = .init(), visibleSessionIDs: [UUID]? = nil) async -> ToolResult {
        do {
            guard let definition = definitions.first(where: { $0.name == name }) else {
                throw KnowledgeToolError.unknownTool(name)
            }
            try validate(args, definition: definition)
            let origin = args["origin"] as? String ?? "all"
            guard ["all", "local", "cloud"].contains(origin) else {
                throw KnowledgeToolError.invalidParameter("origin must be all, local, or cloud")
            }
            let origins: Set<KnowledgeSourceOrigin>? = origin == "all" ? nil : [KnowledgeSourceOrigin(rawValue: origin)!]
            let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: AccountService.shared.isSignedIn, uiFilter: origins)
            let visibleIDs = visibleSessionIDs ?? WorkbenchStore.shared.sessions.filter {
                allowed.contains(KnowledgeSourceOrigin.resolve(isCloudStorage: $0.storage == .cloud, hasRemoteSessionID: $0.remoteSessionID != nil || $0.isRemoteOnly))
            }.map(\.id)
            let requested = (args["session_ids"] as? [String])?.compactMap(UUID.init(uuidString:))
            let single = (args["session_id"] as? String).flatMap(UUID.init(uuidString:))
            guard (requested ?? []).allSatisfy(visibleIDs.contains), single.map(visibleIDs.contains) ?? true else {
                throw KnowledgeToolError.invalidParameter("Session not found or not visible in the selected origin")
            }
            // Keep an empty visible collection empty: fromSelection([]) means all.
            let scope = KnowledgeQAScope.sessions(requested ?? visibleIDs)
            if name == "knowledge.ask" {
                let conversationID = UUID()
                let mode = args["answer_mode"] as? String ?? "normal"
                guard let answerMode = KnowledgeAnswerMode(rawValue: mode) else {
                    throw KnowledgeToolError.invalidParameter("answer_mode must be concise, normal, or detailed")
                }
                let history = try (args["history"] as? [[String: Any]] ?? []).map { message -> KnowledgeMessage in
                    guard let roleText = message["role"] as? String,
                          let role = KnowledgeMessageRole(rawValue: roleText), role != .system,
                          let content = message["content"] as? String else {
                        throw KnowledgeToolError.invalidParameter("history requires user/assistant role and content")
                    }
                    return KnowledgeMessage(conversationID: conversationID, role: role, content: content)
                }
                let request = KnowledgeQARequest(queryText: args["query"] as! String, conversationID: conversationID, scope: scope, answerMode: answerMode, allowCloud: args["allow_cloud"] as? Bool ?? true, originFilter: origins, history: history)
                var response: [String: Any] = ["citations": []]
                var terminal = false
                for await event in qaService.answer(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .status, .delta: break
                    case let .citations(refs):
                        response["citations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(refs))
                    case let .recoveryActions(actions): response["recovery_actions"] = actions.map(\.rawValue)
                    case let .clarification(question):
                        response["status"] = "clarification"
                        response["question"] = question
                        terminal = true
                    case let .finished(answer):
                        response["status"] = "completed"
                        response["answer"] = answer
                        terminal = true
                    case let .failed(message):
                        response["status"] = "failed"
                        response["error"] = message
                        let result = try jsonResult(response)
                        return ToolResult(content: result.content, isError: true)
                    }
                }
                guard terminal else { return .error("Knowledge answer cancelled or ended without a result") }
                return try jsonResult(response)
            }
            let executor = KnowledgeToolExecutor(scope: scope, originFilter: origins, retrievalService: qaService.makeRetrievalService())
            let argumentsData = try JSONSerialization.data(withJSONObject: args)
            switch try await executeKnowledgeTool(executor, name: name, argumentsData: argumentsData) {
            case let .success(value): return try jsonResult(value)
            case let .error(message): return .error(message)
            case let .control(.clarify(question)): return try jsonResult(["status": "clarification", "question": question])
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func executeKnowledgeTool(
        _ executor: KnowledgeToolExecutor, name: String, argumentsData: Data
    ) async throws -> KnowledgeToolResult {
        let arguments = try JSONSerialization.jsonObject(with: argumentsData) as! [String: Any]
        return try await executor.execute(toolName: name, arguments: arguments)
    }

    static func validate(_ args: [String: Any], definition: KnowledgeToolDefinition) throws {
        for parameter in definition.parameters {
            guard let value = args[parameter.name] else {
                if parameter.required { throw KnowledgeToolError.missingParameter(parameter.name) }
                continue
            }
            let valid: Bool
            switch parameter.type {
            case "string": valid = value is String
            case "array": valid = parameter.name == "history" ? value is [[String: Any]] : value is [String]
            case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case "integer", "number":
                valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (parameter.type != "integer" || $0.doubleValue.rounded() == $0.doubleValue) } ?? false
            default: valid = false
            }
            guard valid else { throw KnowledgeToolError.invalidParameter(parameter.name) }
        }
        if let origin = args["origin"], !(origin is String) { throw KnowledgeToolError.invalidParameter("origin") }
        for key in ["query", "question"] {
            if let text = args[key] as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw KnowledgeToolError.invalidParameter("\(key) must not be empty")
            }
        }
        let ids = (args["session_ids"] as? [String]) ?? []
        if args["session_ids"] != nil && ids.isEmpty { throw KnowledgeToolError.invalidParameter("session_ids must not be empty") }
        for id in ids + ((args["session_id"] as? String).map { [$0] } ?? []) {
            guard UUID(uuidString: id) != nil else { throw KnowledgeToolError.invalidParameter("Invalid session UUID") }
        }
        for key in ["limit", "bucket_seconds"] {
            if let value = args[key] as? NSNumber, value.doubleValue <= 0 || value.doubleValue > 10_000 {
                throw KnowledgeToolError.invalidParameter("\(key) must be between 1 and 10000")
            }
        }
        if let start = args["start"] as? Double, let end = args["end"] as? Double, start > end {
            throw KnowledgeToolError.invalidParameter("start must not exceed end")
        }
    }

    private static func jsonResult(_ value: [String: Any]) throws -> ToolResult {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return .ok(String(decoding: data, as: UTF8.self))
    }
}
