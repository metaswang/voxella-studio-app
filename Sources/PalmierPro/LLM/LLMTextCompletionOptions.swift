import Foundation

/// A provider-neutral structured output description for short LLM calls.
///
/// The app has both Chat Completions and Responses transports. Keeping the
/// schema in one value prevents the skill selector from silently falling back
/// to prompt-only JSON when the transport changes.
struct LLMStructuredOutputFormat: Equatable, Sendable {
    let name: String
    let schema: [String: LLMJSONValue]
    let strict: Bool

    init(
        name: String,
        schema: [String: LLMJSONValue],
        strict: Bool = true
    ) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }

    /// Chat Completions' `response_format` value.
    var chatCompletionsValue: LLMJSONValue {
        .object([
            "type": .string("json_schema"),
            "json_schema": .object([
                "name": .string(name),
                "strict": .bool(strict),
                "schema": .object(schema),
            ]),
        ])
    }

    /// Responses API's `text.format` value.
    var responsesTextFormatValue: [String: Any] {
        [
            "type": "json_schema",
            "name": name,
            "strict": strict,
            "schema": schema.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = entry.value.foundationValue
            },
        ]
    }

    static let skillSelection = LLMStructuredOutputFormat(
        name: "skill_selection",
        schema: [
            "type": .string("object"),
            "properties": .object([
                "selected_skill_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
            ]),
            "required": .array([.string("selected_skill_ids")]),
            "additionalProperties": .bool(false),
        ]
    )
}

struct LLMTextCompletionOptions: Equatable, Sendable {
    let structuredOutput: LLMStructuredOutputFormat?

    init(structuredOutput: LLMStructuredOutputFormat? = nil) {
        self.structuredOutput = structuredOutput
    }

    static let `default` = LLMTextCompletionOptions()

    static let skillSelection = LLMTextCompletionOptions(
        structuredOutput: .skillSelection
    )
}

/// Optional capability for clients that can enforce a response schema.
/// Existing test and feature clients can remain text-only; callers fall back
/// to the legacy completion method when this capability is unavailable.
protocol LLMConfigurableTextClient: LLMTextClient {
    func complete(
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String
}

private extension LLMJSONValue {
    var foundationValue: Any {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value
        case .bool(let value):
            value
        case .object(let value):
            value.mapValues(\.foundationValue)
        case .array(let value):
            value.map(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}
