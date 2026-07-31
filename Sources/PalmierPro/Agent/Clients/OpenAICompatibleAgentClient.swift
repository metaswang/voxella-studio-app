import Foundation

struct OpenAICompatibleAgentClient: AgentClient {
    typealias SessionFactory = @Sendable (LLMRequestPolicy) -> URLSession
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let route: LLMRuntimeRoute
    private let sessionFactory: SessionFactory
    private let sleeper: Sleeper

    init(
        route: LLMRuntimeRoute,
        sessionFactory: SessionFactory? = nil,
        sleeper: Sleeper? = nil
    ) {
        self.route = route
        self.sessionFactory = sessionFactory ?? { policy in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = policy.timeoutSeconds
            configuration.timeoutIntervalForResource = policy.timeoutSeconds
            configuration.waitsForConnectivity = true
            return URLSession(configuration: configuration)
        }
        self.sleeper = sleeper ?? { try await Task.sleep(for: $0) }
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        system: system,
                        tools: tools,
                        messages: messages,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var failures: [LLMAttemptFailure] = []
        for configuration in route.configurations {
            for attempt in 1...route.policy.maximumAttemptsPerModel {
                try Task.checkCancellation()
                var emitted = false
                do {
                    let session = sessionFactory(route.policy)
                    let stream = SingleOpenAICompatibleAgentStream(
                        configuration: configuration,
                        policy: route.policy,
                        session: session
                    )
                    for try await event in stream.events(
                        system: system,
                        tools: tools,
                        messages: messages
                    ) {
                        emitted = true
                        continuation.yield(event)
                    }
                    if !failures.isEmpty {
                        Log.llm.notice(
                            "chat recovered model=\(configuration.modelIdentifier) attempt=\(attempt)"
                        )
                    }
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if emitted { throw error }
                    let failure = LLMAttemptFailure(
                        model: configuration.modelIdentifier,
                        attempt: attempt,
                        reason: Self.failureDescription(error)
                    )
                    failures.append(failure)
                    let retryable = ResilientLLMTextClient.isRetryable(error)
                    Log.llm.warning(
                        "chat failed model=\(configuration.modelIdentifier) attempt=\(attempt) retryable=\(retryable) reason=\(failure.reason)"
                    )
                    guard retryable,
                          attempt < route.policy.maximumAttemptsPerModel else {
                        break
                    }
                    let delay = min(
                        route.policy.initialBackoffSeconds
                            * pow(2, Double(max(0, attempt - 1))),
                        10
                    )
                    if delay > 0 {
                        try await sleeper(.seconds(delay))
                    }
                }
            }
        }
        throw LLMClientError.exhausted(failures)
    }

    private static func failureDescription(_ error: Error) -> String {
        (error as? LLMClientError)?.shortDescription
            ?? String(describing: type(of: error))
    }
}

private struct SingleOpenAICompatibleAgentStream: Sendable {
    let configuration: LLMRuntimeConfiguration
    let policy: LLMRequestPolicy
    let session: URLSession

    func events(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(
                        system: system,
                        tools: tools,
                        messages: messages,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(
            url: configuration.endpoint,
            timeoutInterval: policy.timeoutSeconds
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-ID")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                system: system,
                tools: tools,
                messages: messages
            ),
            options: [.sortedKeys]
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw LLMClientError.timeout
        } catch {
            throw LLMClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count >= 2_000 { break }
            }
            throw LLMClientError.provider(
                status: http.statusCode,
                message: Self.errorMessage(from: body),
                retryAfterSeconds: Self.retryAfterSeconds(from: http)
            )
        }

        var toolCalls: [Int: PendingToolCall] = [:]
        var terminalReason: AnthropicStopReason?
        var emittedContent = false
        var reasoningFilter = ReasoningTagStreamFilter()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (root["choices"] as? [[String: Any]])?.first else {
                continue
            }
            if let delta = choice["delta"] as? [String: Any] {
                if let rawText = Self.deltaText(delta),
                   let text = reasoningFilter.consume(rawText),
                   !text.isEmpty {
                    emittedContent = true
                    continuation.yield(.textDelta(text))
                }
                if let chunks = delta["tool_calls"] as? [[String: Any]] {
                    for chunk in chunks {
                        guard let index = chunk["index"] as? Int else { continue }
                        var pending = toolCalls[index] ?? PendingToolCall()
                        if let id = chunk["id"] as? String, !id.isEmpty {
                            pending.id = id
                        }
                        if let function = chunk["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                pending.name = name
                            }
                            if let arguments = function["arguments"] as? String {
                                pending.arguments += arguments
                            }
                        }
                        toolCalls[index] = pending
                    }
                }
            }
            if let reason = choice["finish_reason"] as? String {
                terminalReason = reason == "tool_calls" || reason == "function_call"
                    ? .toolUse
                    : .endTurn
            }
        }

        if let trailingText = reasoningFilter.finish(), !trailingText.isEmpty {
            emittedContent = true
            continuation.yield(.textDelta(trailingText))
        }

        for (_, toolCall) in toolCalls.sorted(by: { $0.key < $1.key }) {
            guard !toolCall.name.isEmpty else { continue }
            emittedContent = true
            continuation.yield(.toolUseComplete(
                id: toolCall.id.isEmpty ? "call_\(UUID().uuidString)" : toolCall.id,
                name: toolCall.name,
                inputJSON: toolCall.arguments.isEmpty ? "{}" : toolCall.arguments
            ))
        }

        if !toolCalls.isEmpty {
            continuation.yield(.messageStop(stopReason: .toolUse))
        } else if emittedContent {
            continuation.yield(.messageStop(stopReason: terminalReason ?? .endTurn))
        } else {
            throw LLMClientError.emptyResponse
        }
    }

    private func requestBody(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.modelName,
            "stream": true,
            "messages": Self.openAIMessages(system: system, messages: messages),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name,
                        "description": $0.description,
                        "parameters": $0.inputSchema,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
        }

        let model = configuration.modelName.lowercased()
        if model.contains("gpt-5") || configuration.profile.normalizedPrefix == "minimax" {
            body["max_completion_tokens"] = 8_192
        } else {
            body["max_tokens"] = 8_192
        }
        if model.contains("gpt-5") {
            body["reasoning_effort"] = "low"
        }
        configuration.openAICompatibleRequestOptions.apply(to: &body)
        return body
    }

    private static func openAIMessages(
        system: String,
        messages: [AnthropicMessage]
    ) -> [[String: Any]] {
        var output: [[String: Any]] = [
            ["role": "system", "content": system],
        ]
        for message in messages {
            switch message.role {
            case .assistant:
                output.append(assistantMessage(from: message.content))
            case .user:
                output.append(contentsOf: userMessages(from: message.content))
            }
        }
        return output
    }

    private static func assistantMessage(from blocks: [[String: Any]]) -> [String: Any] {
        var text: [String] = []
        var toolCalls: [[String: Any]] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let value = block["text"] as? String, !value.isEmpty {
                    text.append(value)
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let input = block["input"] ?? [:]
                let arguments = Self.JSONString(input) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments],
                ])
            default:
                continue
            }
        }
        var message: [String: Any] = [
            "role": "assistant",
            "content": text.isEmpty ? NSNull() : text.joined(),
        ]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        return message
    }

    private static func userMessages(from blocks: [[String: Any]]) -> [[String: Any]] {
        let toolResults = blocks.filter { $0["type"] as? String == "tool_result" }
        if !toolResults.isEmpty {
            return toolResults.compactMap { block in
                guard let toolCallID = block["tool_use_id"] as? String else { return nil }
                return [
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "content": toolResultContent(block["content"]),
                ]
            }
        }

        let content = blocks.compactMap(openAIContentPart)
        guard !content.isEmpty else { return [] }
        return [["role": "user", "content": content]]
    }

    private static func openAIContentPart(_ block: [String: Any]) -> [String: Any]? {
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return ["type": "text", "text": text]
        case "image":
            guard let source = block["source"] as? [String: Any],
                  let mime = source["media_type"] as? String,
                  let data = source["data"] as? String else { return nil }
            return [
                "type": "image_url",
                "image_url": ["url": "data:\(mime);base64,\(data)"],
            ]
        default:
            return nil
        }
    }

    private static func toolResultContent(_ value: Any?) -> String {
        guard let blocks = value as? [[String: Any]] else {
            return value.map(String.init(describing:)) ?? ""
        }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                return block["text"] as? String
            case "image":
                return "[Image result attached]"
            default:
                return nil
            }
        }.joined(separator: "\n")
    }

    private static func deltaText(_ delta: [String: Any]) -> String? {
        if let text = delta["content"] as? String { return text }
        if let parts = delta["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private static func JSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func errorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let error = root["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["msg"] as? String)
        }
        if let baseResponse = root["base_resp"] as? [String: Any] {
            return baseResponse["status_msg"] as? String
        }
        return root["message"] as? String
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return min(seconds, 30)
    }

    private struct PendingToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }
}

/// Removes provider reasoning blocks without assuming SSE chunks align to tag boundaries.
/// MiniMax can return reasoning in `reasoning_content` while leaving a standalone
/// `</think>` in `content`; other OpenAI-compatible providers may stream the complete
/// `<think>…</think>` block through `content`.
private struct ReasoningTagStreamFilter {
    private static let openingTag = "<think>"
    private static let closingTag = "</think>"

    private var pending = ""
    private var isInsideReasoning = false
    private var hasVisibleOutput = false

    mutating func consume(_ chunk: String) -> String? {
        guard !chunk.isEmpty else { return nil }
        pending += chunk
        var output = ""

        while !pending.isEmpty {
            if isInsideReasoning {
                if let range = pending.range(
                    of: Self.closingTag,
                    options: [.caseInsensitive]
                ) {
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    isInsideReasoning = false
                    continue
                }
                pending = Self.possibleTagSuffix(in: pending, tag: Self.closingTag)
                break
            }

            let opening = pending.range(of: Self.openingTag, options: [.caseInsensitive])
            let closing = pending.range(of: Self.closingTag, options: [.caseInsensitive])
            let nextTag = [opening.map { ($0, true) }, closing.map { ($0, false) }]
                .compactMap { $0 }
                .min { $0.0.lowerBound < $1.0.lowerBound }

            if let (range, opensReasoning) = nextTag {
                output += pending[..<range.lowerBound]
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                isInsideReasoning = opensReasoning
                continue
            }

            let suffix = Self.longestPossibleTagSuffix(in: pending)
            let end = pending.index(pending.endIndex, offsetBy: -suffix.count)
            output += pending[..<end]
            pending = suffix
            break
        }

        return visibleOutput(from: output)
    }

    mutating func finish() -> String? {
        defer { pending = "" }
        guard !isInsideReasoning else { return nil }
        return visibleOutput(from: pending)
    }

    private mutating func visibleOutput(from raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if hasVisibleOutput { return raw }

        let trimmed = raw.drop(while: { $0.isWhitespace })
        guard !trimmed.isEmpty else { return nil }
        hasVisibleOutput = true
        return String(trimmed)
    }

    private static func longestPossibleTagSuffix(in text: String) -> String {
        let opening = possibleTagSuffix(in: text, tag: openingTag)
        let closing = possibleTagSuffix(in: text, tag: closingTag)
        return opening.count >= closing.count ? opening : closing
    }

    private static func possibleTagSuffix(in text: String, tag: String) -> String {
        let maximum = min(text.count, tag.count - 1)
        guard maximum > 0 else { return "" }
        for length in stride(from: maximum, through: 1, by: -1) {
            let suffix = text.suffix(length)
            let tagPrefix = tag.prefix(length)
            if suffix.compare(tagPrefix, options: [.caseInsensitive]) == .orderedSame {
                return String(suffix)
            }
        }
        return ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
