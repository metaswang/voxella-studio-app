import Foundation

/// An inline dictation must not overwrite typing or enter a different conversation.
enum VoiceInputDraftInsertion {
    static func result(original: String, current: String, spoken: String, multiline: Bool,
                       contextIsCurrent: Bool) -> String? {
        guard contextIsCurrent, current == original else { return nil }
        let insertion = multiline ? spoken : spoken.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !insertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return current }
        let separator = original.isEmpty || original.last?.isWhitespace == true ? "" : (multiline ? "\n" : " ")
        return original + separator + insertion
    }
}
