import Foundation

enum WordSpanMapper {
    struct QuoteSpan: Equatable, Sendable {
        let start: Double
        let end: Double
        let words: [TranscriptionWord]
    }

    static func words(
        overlapping range: ClosedRange<Double>,
        in words: [TranscriptionWord]
    ) -> [TranscriptionWord] {
        words.filter { word in
            guard let start = word.start, start.isFinite else { return false }
            let end = word.end ?? start
            return start < range.upperBound && end > range.lowerBound
        }
    }

    static func quoteSpan(
        overlapping range: ClosedRange<Double>,
        matching terms: [String] = [],
        in words: [TranscriptionWord]
    ) -> QuoteSpan? {
        let overlapping = self.words(overlapping: range, in: words)
        guard !overlapping.isEmpty else { return nil }

        let selected: [TranscriptionWord]
        if terms.isEmpty {
            selected = overlapping
        } else {
            let hits = overlapping.enumerated().compactMap { index, word -> Int? in
                matches(word.text, terms: terms) ? index : nil
            }
            guard let first = hits.first, let last = hits.last else {
                selected = overlapping
                return span(selected)
            }
            selected = Array(overlapping[first...last])
        }
        return span(selected)
    }

    private static func span(_ words: [TranscriptionWord]) -> QuoteSpan? {
        guard let start = words.first?.start, start.isFinite else { return nil }
        let end = words.last.flatMap { $0.end ?? $0.start } ?? start
        return QuoteSpan(start: start, end: max(start, end), words: words)
    }

    private static func matches(_ text: String, terms: [String]) -> Bool {
        terms.contains { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
