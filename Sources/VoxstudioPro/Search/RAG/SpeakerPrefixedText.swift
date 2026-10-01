import Foundation

enum SpeakerPrefixedText {
    static func line(speaker: String?, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let label = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if label.isEmpty { return trimmed }
        return "[\(label)] \(trimmed)"
    }

    static func joined(_ items: [(speaker: String?, text: String)]) -> String {
        items
            .map { line(speaker: $0.speaker, text: $0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
