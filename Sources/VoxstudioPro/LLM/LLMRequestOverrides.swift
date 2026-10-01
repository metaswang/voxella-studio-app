import Foundation

enum LLMJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LLMJSONValue])
    case array([LLMJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: LLMJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([LLMJSONValue].self) {
            self = .array(value)
        } else {
            throw LLMRequestOverridesError.invalidJSON
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw LLMRequestOverridesError.invalidJSON }
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var prettyJSONString: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            guard let string = String(data: data, encoding: .utf8) else {
                throw LLMRequestOverridesError.invalidJSON
            }
            return string
        }
    }

    static func parseObject(_ text: String) throws -> [String: LLMJSONValue] {
        let data = Data(text.utf8)
        let object = try JSONDecoder().decode(LLMJSONValue.self, from: data)
        guard case .object(let object) = object else {
            throw LLMRequestOverridesError.rootMustBeObject
        }
        return object
    }

    static func deepMerge(
        _ source: [String: LLMJSONValue],
        into destination: inout [String: LLMJSONValue]
    ) {
        for (key, value) in source {
            guard case .object(let sourceObject) = value,
                  case .object(let destinationObject) = destination[key] else {
                destination[key] = value
                continue
            }
            var merged = destinationObject
            deepMerge(sourceObject, into: &merged)
            destination[key] = .object(merged)
        }
    }

    var compactLogValue: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return String(value.prefix(48))
        case .array(let values):
            return "[\(values.count)]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\(key)=\(object[key]?.compactLogValue ?? "nil")"
            }
            return "{\(pairs.joined(separator: ","))}"
        }
    }

    static func compactLogObject(
        _ object: [String: LLMJSONValue],
        limit: Int = 400
    ) -> String {
        guard !object.isEmpty else { return "none" }
        let text = object.keys.sorted().map { key in
            "\(key)=\(object[key]?.compactLogValue ?? "nil")"
        }.joined(separator: ",")
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}

enum LLMOpenRouterSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultOrder = "default"
    case price
    case throughput
    case latency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOrder: "Default"
        case .price: "Price"
        case .throughput: "Throughput"
        case .latency: "Latency"
        }
    }
}

struct LLMOpenRouterRouting: Codable, Equatable, Sendable {
    var enabled = false
    var order: [String] = []
    var allowFallbacks = true
    var sort: LLMOpenRouterSort?

    var generatedExtraBody: [String: LLMJSONValue] {
        guard enabled else { return [:] }

        var provider: [String: LLMJSONValue] = [:]
        if !order.isEmpty {
            provider["order"] = .array(order.map { .string($0) })
        }
        provider["allow_fallbacks"] = .bool(allowFallbacks)
        if order.isEmpty, let sort, sort != .defaultOrder {
            provider["sort"] = .string(sort.rawValue)
        }
        return ["provider": .object(provider)]
    }
}

enum LLMRequestOverridesError: LocalizedError, Equatable {
    case invalidJSON
    case rootMustBeObject

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Enter valid JSON."
        case .rootMustBeObject:
            "Extra body JSON must be an object."
        }
    }
}

extension LLMProviderProfile {
    var extraBodyValue: LLMJSONValue {
        .object(extraBody)
    }

    var isOpenRouter: Bool {
        provider == .openRouter
            || normalizedPrefix == "openrouter"
            || normalizedBaseURL.localizedCaseInsensitiveContains("openrouter.ai")
    }

    var resolvedExtraBody: [String: LLMJSONValue] {
        var result = isOpenRouter ? openRouterRouting.generatedExtraBody : [:]
        LLMJSONValue.deepMerge(extraBody, into: &result)
        return result
    }
}

extension LLMRuntimeConfiguration {
    private var usesOfficialOpenAIChatCompletions: Bool {
        profile.provider == .openAI
            || endpoint.host?.caseInsensitiveCompare("api.openai.com") == .orderedSame
    }

    var resolvedExtraBody: [String: LLMJSONValue] {
        var result = openAICompatibleRequestOptions.extraBody
        LLMJSONValue.deepMerge(profile.resolvedExtraBody, into: &result)

        // Gateway-specific reasoning fields can remain in persisted overrides
        // after a provider is changed. The official OpenAI Chat Completions
        // endpoint rejects those fields and accepts only `reasoning_effort`.
        if usesOfficialOpenAIChatCompletions {
            let legacyReasoningEffort: String?
            if case let .object(reasoning)? = result["reasoning"],
               case let .string(effort)? = reasoning["effort"] {
                legacyReasoningEffort = effort
            } else {
                legacyReasoningEffort = nil
            }
            result.removeValue(forKey: "reasoning")
            result.removeValue(forKey: "thinking")
            result.removeValue(forKey: "reasoning_split")
            if result["reasoning_effort"] == nil, let legacyReasoningEffort {
                result["reasoning_effort"] = .string(legacyReasoningEffort)
            }
            if let maxTokens = result.removeValue(forKey: "max_tokens"),
               result["max_completion_tokens"] == nil {
                result["max_completion_tokens"] = maxTokens
            }
        }
        if useCase == .skillSelection {
            // A provider's persisted general-chat override must not turn a
            // bounded routing call back into an unbounded generation.
            if usesOfficialOpenAIChatCompletions {
                // Newer official OpenAI reasoning models reject the legacy
                // `max_tokens` name. Compatible gateways still expect it.
                result.removeValue(forKey: "max_tokens")
                result["max_completion_tokens"] = .number(256)
                result["reasoning_effort"] = .string(lowestReasoningEffort.rawValue)
                result.removeValue(forKey: "reasoning")
                result.removeValue(forKey: "thinking")
                result.removeValue(forKey: "reasoning_split")
            } else {
                result["max_tokens"] = .number(256)
            }
        }
        return result
    }
}
