import Foundation

/// Reconstructs display words from Parakeet's SentencePiece/TDT token stream.
///
/// Parakeet emits subword pieces, not lexical words.  The SentencePiece word
/// boundary is represented by a leading `▁` (converted to whitespace by the
/// tokenizer).  Keeping that boundary until after token assembly is essential:
/// joining every token as if it were a word produces output such as
/// `activ iti es` and `I ' m`.
enum ParakeetTokenAssembler {
    struct Token: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double

        init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Coalesces SentencePiece pieces into words while retaining the first and
    /// last token timestamps.  Punctuation and apostrophe pieces without a
    /// leading boundary stay attached to the preceding word.
    static func assemble(_ tokens: [Token]) -> [Token] {
        var output: [Token] = []
        var current: Token?

        func emitCurrent() {
            guard let current else { return }
            output.append(current)
        }

        for token in tokens {
            let decoded = token.text.replacingOccurrences(of: "▁", with: " ")
            let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            let startsNewWord = decoded.first?.isWhitespace == true
                || token.text.first == "▁"

            guard !text.isEmpty else {
                emitCurrent()
                current = nil
                continue
            }

            if startsNewWord {
                emitCurrent()
                current = Token(text: text, start: token.start, end: token.end)
            } else if let existing = current {
                current = Token(
                    text: existing.text + text,
                    start: existing.start,
                    end: max(existing.end, token.end)
                )
            } else {
                current = Token(text: text, start: token.start, end: token.end)
            }
        }
        emitCurrent()
        return deduplicatingNearIdenticalWords(output)
    }

    /// Context-window decoding can expose the same token at an ownership
    /// boundary.  Remove only highly-overlapping identical words; repeated
    /// spoken words with separate timing remain intact.
    private static func deduplicatingNearIdenticalWords(_ words: [Token]) -> [Token] {
        var result: [Token] = []
        for word in words {
            if let previous = result.last,
               previous.text == word.text,
               overlap(previous, word) >= min(duration(previous), duration(word)) * 0.5 {
                if duration(word) > duration(previous) {
                    result[result.count - 1] = word
                }
                continue
            }
            result.append(word)
        }
        return result
    }

    private static func duration(_ token: Token) -> Double {
        max(0, token.end - token.start)
    }

    private static func overlap(_ lhs: Token, _ rhs: Token) -> Double {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
    }
}
