import Foundation

enum AgentUsageLog {
    static func record(_ usage: [String: Any]) {
        #if DEBUG
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let billed = input + cacheWrite + cacheRead
        let readPct = billed > 0 ? Int((Double(cacheRead) / Double(billed)) * 100) : 0
        print("[agent cache] input=\(input) cacheWrite=\(cacheWrite) cacheRead=\(cacheRead) (\(readPct)% read)")
        #endif
    }
}

struct AnthropicUsageAccumulator {
    private var counts: [String: Int] = [:]
    private var hasFinalOutput = false
    private var invalid = false

    mutating func update(_ usage: [String: Any], finalOutput: Bool) {
        for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
            guard let raw = usage[key], !(raw is NSNull) else { continue }
            guard let value = raw as? Int, value >= 0, value <= 1_000_000_000 else {
                invalid = true
                continue
            }
            // message_delta counts are cumulative, not incremental.
            counts[key] = value
            if key == "output_tokens", finalOutput { hasFinalOutput = true }
        }
    }

    var finalUsage: AgentTokenUsage? {
        guard !invalid, hasFinalOutput, let input = counts["input_tokens"], let output = counts["output_tokens"] else { return nil }
        let totalInput = input + (counts["cache_creation_input_tokens"] ?? 0) + (counts["cache_read_input_tokens"] ?? 0)
        return AgentTokenUsage.from(["input_tokens": totalInput, "output_tokens": output])
    }
}

enum AnthropicSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var pendingTools: [Int: (id: String, name: String, json: String)] = [:]
        var finished = false
        var usageAccumulator = AnthropicUsageAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    AgentUsageLog.record(usage)
                    usageAccumulator.update(usage, finalOutput: false)
                }

            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        pendingTools[index] = (id, name, "")
                    } else if blockType == "redacted_thinking",
                              let data = block["data"] as? String {
                        continuation.yield(.redactedThinking(data))
                    }
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                } else if deltaType == "thinking_delta",
                          let thinking = delta["thinking"] as? String,
                          !thinking.isEmpty {
                    continuation.yield(.thinkingDelta(thinking))
                } else if deltaType == "signature_delta",
                          let signature = delta["signature"] as? String,
                          !signature.isEmpty {
                    continuation.yield(.thinkingSignature(signature))
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String,
                          var acc = pendingTools[index] {
                    acc.json += partial
                    pendingTools[index] = acc
                }

            case "content_block_stop":
                if let index = event["index"] as? Int, let acc = pendingTools.removeValue(forKey: index) {
                    let json = acc.json.isEmpty ? "{}" : acc.json
                    continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json))
                }

            case "message_delta":
                if let usage = event["usage"] as? [String: Any] {
                    usageAccumulator.update(usage, finalOutput: true)
                }
                if let delta = event["delta"] as? [String: Any],
                   let raw = delta["stop_reason"] as? String {
                    continuation.yield(.messageStop(stopReason: AgentStopReason(rawValue: raw) ?? .other))
                }

            case "error":
                if let err = event["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    throw AgentClientTransportError.streamError(provider: .anthropic, message: msg)
                }

            case "message_stop":
                if let usage = usageAccumulator.finalUsage { continuation.yield(.tokenUsage(usage)) }
                finished = true

            default: break
            }
        }
        guard finished else { throw AgentClientTransportError.streamError(provider: .anthropic, message: "The response stream ended before completion.") }
    }
}

enum AnthropicRequestBody {
    static func build(
        model: AgentModel,
        reasoningEffort: AgentReasoningEffort = .medium,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        precondition(model.provider == .anthropic)
        precondition(model.supportedReasoningEfforts.contains(reasoningEffort))
        return build(
            modelName: model.rawValue,
            reasoningEffort: LLMReasoningEffort(rawValue: reasoningEffort.rawValue) ?? .medium,
            system: system,
            tools: tools,
            messages: messages
        )
    }

    static func build(
        modelName: String,
        reasoningEffort: LLMReasoningEffort,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        extraBody: [String: LLMJSONValue] = [:],
        capability: ChatModelCapability? = nil
    ) -> [String: Any] {
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        // Prompt-cache boundary covers system + tools.
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
        // Prompt-cache the conversation prefix
        var messageBlocks: [[String: Any]] = messages.compactMap { message in
            let content = message.content.compactMap(contentJSON)
            return content.isEmpty ? nil : ["role": message.role.rawValue, "content": content]
        }
        if var lastMsg = messageBlocks.popLast(),
           var content = lastMsg["content"] as? [[String: Any]],
           var lastBlock = content.popLast() {
            lastBlock["cache_control"] = ["type": "ephemeral"]
            content.append(lastBlock)
            lastMsg["content"] = content
            messageBlocks.append(lastMsg)
        }
        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": 64_000,
            "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messageBlocks,
        ]
        (capability ?? .known(modelName)).applyAnthropic(to: &body, effort: reasoningEffort)
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        for (key, value) in anthropicJSON(extraBody) { body[key] = value }
        return body
    }

    private static func contentJSON(_ block: AgentRequestBlock) -> [String: Any]? {
        switch block {
        case .image(let base64, let mediaType):
            return imageJSON(base64: base64, mediaType: mediaType)
        case .content(let content):
            switch content {
            case .thinking(let text, let signature):
                guard !signature.isEmpty else { return nil }
                return ["type": "thinking", "thinking": text, "signature": signature]
            case .redactedThinking(let data):
                guard !data.isEmpty else { return nil }
                return ["type": "redacted_thinking", "data": data]
            case .openAIReasoning:
                return nil
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return ["type": "text", "text": text]
            case .toolUse(let id, let name, let inputJSON):
                return [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": parseJSONObject(inputJSON),
                ]
            case .toolResult(let toolUseID, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                    "content": content.map(toolResultJSON),
                    "is_error": isError,
                ]
            }
        }
    }

    private static func toolResultJSON(_ block: ToolResult.Block) -> [String: Any] {
        switch block {
        case .text(let text):
            ["type": "text", "text": text]
        case .image(let base64, let mediaType):
            imageJSON(base64: base64, mediaType: mediaType)
        }
    }

    private static func imageJSON(base64: String, mediaType: String) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": mediaType, "data": base64],
        ]
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

private func anthropicJSON(_ value: [String: LLMJSONValue]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: value.map { ($0.key, anthropicJSON($0.value)) })
}

private func anthropicJSON(_ value: LLMJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): anthropicJSON(value)
    case .array(let value): value.map(anthropicJSON)
    case .null: NSNull()
    }
}
