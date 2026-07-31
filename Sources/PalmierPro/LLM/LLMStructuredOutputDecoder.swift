import Foundation

/// Extracts a typed JSON value from chat-model output without assuming that the
/// provider returns JSON as the entire message. Reasoning models commonly place
/// `<think>` content or Markdown fences around the final answer.
enum LLMStructuredOutputDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("Expected a JSON value, but the response was empty.")
        }

        var candidates: [String] = []
        appendCandidate(trimmed, to: &candidates)

        if let finalAnswer = contentAfterLastReasoningBlock(in: trimmed) {
            appendCandidate(finalAnswer, to: &candidates)
            appendFencedCandidates(in: finalAnswer, to: &candidates)
            appendBalancedCandidates(in: finalAnswer, to: &candidates)
        }

        appendFencedCandidates(in: trimmed, to: &candidates)
        appendBalancedCandidates(in: trimmed, to: &candidates)

        var lastDecodingError: Error?
        for candidate in candidates {
            do {
                return try JSONDecoder().decode(type, from: Data(candidate.utf8))
            } catch {
                lastDecodingError = error
            }
        }

        if let lastDecodingError {
            throw MediaFlowError.invalidLLMOutput(describe(lastDecodingError))
        }
        throw MediaFlowError.invalidLLMOutput("Expected a complete JSON object or array.")
    }

    private static func appendCandidate(_ candidate: String, to candidates: inout [String]) {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !candidates.contains(normalized) else { return }
        candidates.append(normalized)
    }

    private static func contentAfterLastReasoningBlock(in value: String) -> String? {
        guard let closingTag = value.range(
            of: "</think>",
            options: [.caseInsensitive, .backwards]
        ) else { return nil }
        let suffix = String(value[closingTag.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func appendFencedCandidates(
        in value: String,
        to candidates: inout [String]
    ) {
        let pattern = #"```(?:json)?\s*([\s\S]*?)```"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: value) else { continue }
            appendCandidate(String(value[capture]), to: &candidates)
        }
    }

    private static func appendBalancedCandidates(
        in value: String,
        to candidates: inout [String]
    ) {
        let starts = value.indices.filter { value[$0] == "{" || value[$0] == "[" }
        for start in starts.reversed() {
            guard let range = balancedJSONRange(in: value, from: start) else { continue }
            appendCandidate(String(value[range]), to: &candidates)
        }
    }

    private static func balancedJSONRange(
        in value: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        let opening = value[start]
        guard opening == "{" || opening == "[" else { return nil }
        var stack: [Character] = [opening]
        var inString = false
        var isEscaped = false
        var index = value.index(after: start)

        while index < value.endIndex {
            let character = value[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{", "[":
                    stack.append(character)
                case "}":
                    guard stack.last == "{" else { return nil }
                    stack.removeLast()
                case "]":
                    guard stack.last == "[" else { return nil }
                    stack.removeLast()
                default:
                    break
                }
                if stack.isEmpty {
                    return start..<value.index(after: index)
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "Missing required field \(path(context.codingPath + [key]))."
        case .typeMismatch(let type, let context):
            return "Expected \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Missing \(type) value at \(path(context.codingPath))."
        case .dataCorrupted(let context):
            return "Invalid JSON at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the response root" }
        return codingPath.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }.joined(separator: ".")
    }
}
