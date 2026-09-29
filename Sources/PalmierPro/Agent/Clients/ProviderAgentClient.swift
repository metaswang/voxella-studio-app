import Foundation

/// Streams an agent turn through the Provider configuration shared by every
/// other BYOK AI feature. A route can contain a primary and fallbacks, but a
/// fallback is only safe before the first visible event has been emitted.
struct ProviderAgentClient: AgentClient {
    let route: LLMRuntimeRoute
    let session: URLSession
    var maximumOutputTokens: Int? = nil
    var onModelSelected: @Sendable (String) async -> Void = { _ in }

    init(route: LLMRuntimeRoute, session: URLSession = .shared, maximumOutputTokens: Int? = nil) {
        self.route = route
        self.session = session
        self.maximumOutputTokens = maximumOutputTokens
    }

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            var lastError: Error?
            for configuration in route.configurations {
                for attempt in 1...route.policy.maximumAttemptsPerModel {
                    var emitted = false
                    do {
                        await onModelSelected(configuration.modelIdentifier)
                        let client = SingleProviderAgentClient(configuration: configuration, session: session, timeout: route.policy.timeoutSeconds, maximumOutputTokens: maximumOutputTokens)
                        let events = client.stream(
                            system: system, tools: tools, messages: messages, context: context
                        )
                        for try await event in events {
                            emitted = true
                            continuation.yield(event)
                        }
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                        let detail = configuration.apiKey.isEmpty
                            ? error.localizedDescription
                            : error.localizedDescription.replacingOccurrences(of: configuration.apiKey, with: "[redacted]")
                        Log.agent.warning(
                            "agent attempt failed model=\(configuration.modelIdentifier) attempt=\(attempt) emitted=\(emitted) error=\(detail)"
                        )
                        // Never concatenate an already-visible partial answer
                        // with a response from another provider or model.
                        guard !emitted else { throw error }
                        guard Self.isRetryable(error) else { break }
                        if attempt < route.policy.maximumAttemptsPerModel {
                            try await Task.sleep(for: .seconds(route.policy.initialBackoffSeconds * Double(attempt)))
                        }
                    }
                }
            }
            throw lastError ?? AgentClientTransportError.streamError(
                provider: .openAI, message: "No configured agent provider could complete the request."
            )
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? AgentClientTransportError else { return true }
        guard case .httpError(_, let status, _) = error else { return true }
        return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
    }
}

private struct SingleProviderAgentClient: AgentClient {
    let configuration: LLMRuntimeConfiguration
    let session: URLSession
    let timeout: Double
    let maximumOutputTokens: Int?

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            guard let protocolKind = configuration.agentProtocol else {
                throw AgentClientTransportError.streamError(provider: .openAI, message: "Unsupported agent provider.")
            }
            var request = URLRequest(url: configuration.endpoint, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")

            var body: [String: Any]
            switch protocolKind {
            case .openAIResponses:
                request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                body = OpenAIRequestBody.build(
                    modelName: configuration.modelName,
                    reasoningEffort: configuration.reasoningEffort ?? .medium,
                    system: system,
                    tools: tools,
                    messages: messages,
                    extraBody: configuration.profile.resolvedExtraBody
                )
            case .openAICompatible:
                request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                body = OpenAICompatibleAgentRequestBody.build(
                    configuration: configuration, system: system, tools: tools, messages: messages
                )
            case .anthropic:
                request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                body = AnthropicRequestBody.build(
                    modelName: configuration.modelName,
                    reasoningEffort: configuration.reasoningEffort ?? .medium,
                    system: system,
                    tools: tools,
                    messages: messages,
                    extraBody: configuration.profile.resolvedExtraBody,
                    capability: configuration.chatCapability
                )
            }
            if protocolKind == .openAIResponses, configuration.chatCapability.thinking == .automatic {
                body.removeValue(forKey: "reasoning")
            }
            if let maximumOutputTokens {
                switch protocolKind {
                case .openAIResponses: body["max_output_tokens"] = maximumOutputTokens
                case .anthropic:
                    body["max_tokens"] = maximumOutputTokens
                    if var thinking = body["thinking"] as? [String: Any], let tokens = thinking["budget_tokens"] as? Int {
                        thinking["budget_tokens"] = min(tokens, max(1_024, maximumOutputTokens - 1_024))
                        body["thinking"] = thinking
                    }
                case .openAICompatible:
                    body["max_tokens"] = maximumOutputTokens
                    body.removeValue(forKey: "max_completion_tokens")
                }
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            Log.agent.notice(
                "agent request model=\(configuration.modelIdentifier) host=\(configuration.endpoint.host ?? "unknown") path=\(configuration.endpoint.path) tools=\(tools.count) messages=\(messages.count)"
            )

            let bytes = try await AgentHTTP.bytes(for: request, session: session) { status, body in
                let diagnosticBody = configuration.apiKey.isEmpty
                    ? body
                    : body.replacingOccurrences(of: configuration.apiKey, with: "[redacted]")
                Log.agent.warning(
                    "agent provider error model=\(configuration.modelIdentifier) host=\(configuration.endpoint.host ?? "unknown") path=\(configuration.endpoint.path) status=\(status) body=\(LLMDiagnostics.preview(Data(diagnosticBody.utf8), limit: 800))"
                )
                return AgentClientTransportError.httpError(
                    provider: protocolKind == .anthropic ? .anthropic : .openAI,
                    status: status,
                    body: diagnosticBody
                )
            }
            switch protocolKind {
            case .openAIResponses:
                try await OpenAISSE.parse(
                    bytes: bytes,
                    continuation: continuation,
                    model: AgentModel(rawValue: configuration.modelName)
                )
            case .openAICompatible:
                try await OpenAICompatibleSSE.parse(bytes: bytes, continuation: continuation)
            case .anthropic:
                try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
            }
        }
    }
}

enum OpenAICompatibleAgentRequestBody {
    static func build(
        configuration: LLMRuntimeConfiguration,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.modelName,
            "stream": true,
            "messages": [["role": "system", "content": system]] + messageJSON(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "function": [
                    "name": $0.name, "description": $0.description, "parameters": $0.inputSchema,
                ]]
            }
        }
        if let effort = configuration.reasoningEffort {
            if configuration.chatCapability.thinking == .budget, effort != .none {
                body["reasoning"] = ["max_tokens": effort == .low ? 1_024 : effort == .medium ? 4_096 : 8_192]
            } else { body["reasoning"] = ["effort": effort.rawValue] }
        }
        for (key, value) in anyJSON(configuration.resolvedExtraBody) {
            body[key] = value
        }
        return body
    }

    private static func messageJSON(_ messages: [AgentRequestMessage]) -> [[String: Any]] {
        messages.flatMap { message in
            var text: [String] = []
            var images: [[String: Any]] = []
            var toolCalls: [[String: Any]] = []
            var toolResults: [[String: Any]] = []
            for block in message.content {
                switch block {
                case .image(let base64, let mediaType):
                    images.append(["type": "image_url", "image_url": [
                        "url": "data:\(mediaType);base64,\(base64)",
                    ]])
                case .content(let content):
                    switch content {
                    case .text(let value): text.append(value)
                    case .toolUse(let id, let name, let inputJSON):
                        toolCalls.append(["id": id, "type": "function", "function": [
                            "name": name, "arguments": inputJSON,
                        ]])
                    case .toolResult(let id, let output, let isError):
                        let outputText = output.compactMap { block -> String? in
                            if case .text(let value) = block { return value }
                            return "[Image result attached]"
                        }.joined(separator: "\n")
                        toolResults.append([
                            "role": "tool", "tool_call_id": id,
                            "content": isError ? "Tool error\n\(outputText)" : outputText,
                        ])
                    case .thinking, .redactedThinking, .openAIReasoning:
                        break
                    }
                }
            }
            var result: [[String: Any]] = []
            if !text.isEmpty || !images.isEmpty || !toolCalls.isEmpty {
                var entry: [String: Any] = ["role": message.role.rawValue]
                let content = text.map { ["type": "text", "text": $0] } + images
                if !content.isEmpty { entry["content"] = content }
                if !toolCalls.isEmpty { entry["tool_calls"] = toolCalls }
                result.append(entry)
            }
            result.append(contentsOf: toolResults)
            return result
        }
    }
}

enum OpenAICompatibleSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var parser = OpenAICompatibleStreamParser()
        for try await line in bytes.lines {
            for event in try parser.consume(line: line) { continuation.yield(event) }
        }
        try parser.finish()
    }
}

struct OpenAICompatibleStreamParser {
    private var tools: [Int: (id: String, name: String, arguments: String)] = [:]
    private var didTerminate = false

    mutating func consume(line: String) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if value == "[DONE]" { didTerminate = true; return [] }
        guard let data = value.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AgentClientTransportError.streamError(provider: .openAI, message: "Invalid stream payload.") }
        if let error = root["error"] as? [String: Any] {
            throw AgentClientTransportError.streamError(provider: .openAI, message: error["message"] as? String ?? "Provider error.")
        }
        var events: [AgentStreamEvent] = []
        if let usage = root["usage"] as? [String: Any],
           let input = usage["prompt_tokens"], let output = usage["completion_tokens"],
           let reported = AgentTokenUsage.from(["input_tokens": input, "output_tokens": output]) {
            events.append(.tokenUsage(reported))
        }
        // Some compatible endpoints report usage in a final chunk with no choices.
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return events }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if let text = delta["content"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? 0
            var pending = tools[index] ?? ("", "", "")
            if let id = call["id"] as? String { pending.id = id }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String { pending.name = name }
                if let arguments = function["arguments"] as? String { pending.arguments += arguments }
            }
            tools[index] = pending
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            didTerminate = true
            if reason == "tool_calls" {
                for tool in tools.values where !tool.id.isEmpty && !tool.name.isEmpty {
                    events.append(.toolUseComplete(id: tool.id, name: tool.name, inputJSON: tool.arguments.isEmpty ? "{}" : tool.arguments))
                }
                events.append(.messageStop(stopReason: .toolUse))
            } else {
                events.append(.messageStop(stopReason: reason == "length" ? .maxTokens : (reason == "content_filter" ? .refusal : .endTurn)))
            }
        }
        return events
    }

    func finish() throws {
        guard didTerminate else {
            throw AgentClientTransportError.streamError(provider: .openAI, message: "The stream ended before a terminal event.")
        }
    }
}

private func anyJSON(_ value: [String: LLMJSONValue]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: value.map { ($0.key, anyJSON($0.value)) })
}

private func anyJSON(_ value: LLMJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): anyJSON(value)
    case .array(let value): value.map(anyJSON)
    case .null: NSNull()
    }
}
