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

    var hasExplicitProviderOrder: Bool {
        isOpenRouter && openRouterRouting.enabled && !openRouterRouting.order.isEmpty
    }

    var resolvedExtraBody: [String: LLMJSONValue] {
        var result = isOpenRouter ? openRouterRouting.generatedExtraBody : [:]
        LLMJSONValue.deepMerge(extraBody, into: &result)
        return result
    }
}

extension LLMRuntimeConfiguration {
    var resolvedExtraBody: [String: LLMJSONValue] {
        var result = openAICompatibleRequestOptions.extraBody
        LLMJSONValue.deepMerge(profile.resolvedExtraBody, into: &result)
        return result
    }
}
