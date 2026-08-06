import Foundation

/// Thin adapter kept for existing call sites. Subtitle cleanup itself lives in
/// `SubtitlePostprocessPipeline`, which is the single Stage 1 implementation.
struct SubtitleLLMProcessor: Sendable {
    let client: any LLMTextClient

    func process(
        transcript: TranscriptionResult,
        options: SubtitleProcessingPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitleTrack {
        try await SubtitlePostprocessPipeline(client: client).processTrack(
            transcript: transcript,
            options: options,
            progress: progress
        )
    }

    static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MediaFlowError.invalidLLMOutput("Could not encode the request.")
        }
        return string
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        try LLMStructuredOutputDecoder.decode(type, from: raw)
    }
}

enum SubtitleReadabilityPolicy {
    struct Limits: Equatable, Sendable {
        let minimum: Int
        let preferred: Int
        let maximum: Int
    }

    static let strongEndPunctuation: Set<String> = [".", "?", "!", "。", "？", "！"]
    static let weakEndPunctuation: Set<String> = [",", "，", ";", "；", ":", "："]

    private static let denseScriptLanguages: Set<String> = ["zh", "ja", "ko", "yue"]
    private static let maximumScoredSplitTokens = 400

    static func limits(for text: String, overridingMaximum: Int? = nil) -> Limits {
        limits(denseScript: usesDenseScript(text), overridingMaximum: overridingMaximum)
    }

    static func limits(denseScript: Bool, overridingMaximum: Int? = nil) -> Limits {
        let defaults = denseScript
            ? Limits(minimum: 8, preferred: 14, maximum: 18)
            : Limits(minimum: 24, preferred: 42, maximum: 56)
        guard let overridingMaximum else { return defaults }
        let maximum = max(1, overridingMaximum)
        let preferred = min(defaults.preferred, maximum)
        return Limits(
            minimum: min(defaults.minimum, preferred),
            preferred: preferred,
            maximum: maximum
        )
    }

    static func maximumCharacters(for text: String) -> Int {
        limits(for: text).maximum
    }

    /// True when the sample reads as a dense script (CJK or Thai) that needs the
    /// shorter cue budgets.  Used when the transcript has no reliable language code.
    static func usesDenseScript(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { return false }
        let denseCount = visible.filter(isDenseScript).count
        return Double(denseCount) / Double(visible.count) >= 0.25
    }

    /// Language code wins when it is known; otherwise fall back to the sample.
    static func usesDenseScript(languageCode: String?, sampleText: String) -> Bool {
        if let primary = primaryLanguage(languageCode) {
            return denseScriptLanguages.contains(primary)
        }
        return usesDenseScript(sampleText)
    }

    static func primaryLanguage(_ code: String?) -> String? {
        guard let base = code?
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init),
            !base.isEmpty,
            base != "auto" else { return nil }
        return base
    }

    static func displayLength(_ text: String, denseScript: Bool) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return denseScript ? trimmed.filter { !$0.isWhitespace }.count : trimmed.count
    }

    /// Port of the worker's `_split_token_indices_by_length` scoring: chunks aim
    /// for an even display length while preferring punctuation boundaries.
    static func splitTokenIndices(
        _ tokens: [String],
        languageCode: String?,
        denseScript: Bool,
        chunkCount: Int,
        limits: Limits
    ) -> [[Int]] {
        let count = tokens.count
        guard count > 1, chunkCount > 1 else { return count > 0 ? [Array(0..<count)] : [] }
        let chunks = max(2, min(chunkCount, count))

        func length(_ range: Range<Int>) -> Int {
            displayLength(
                TranscriptSegmenter.joinedText(Array(tokens[range]), language: languageCode),
                denseScript: denseScript
            )
        }

        let total = length(0..<count)
        guard total > 0, count <= maximumScoredSplitTokens else {
            return evenlySplitIndices(count: count, chunks: chunks)
        }
        let target = Double(total) / Double(chunks)

        var output: [[Int]] = []
        var start = 0
        for chunkIndex in 0..<(chunks - 1) {
            let remaining = chunks - chunkIndex
            let maximumEnd = count - (remaining - 1)
            if maximumEnd <= start { break }
            var bestEnd = start + 1
            var bestScore = Double.infinity
            for end in (start + 1)...maximumEnd {
                let chunkLength = length(start..<end)
                var score = abs(Double(chunkLength) - target)
                if chunkLength > limits.maximum {
                    score += Double(chunkLength - limits.maximum) * 8
                } else if chunkLength > limits.preferred {
                    score += Double(chunkLength - limits.preferred) * 0.25
                } else {
                    score -= Double(limits.preferred - chunkLength) * 0.05
                }
                if chunkLength < limits.minimum {
                    score += Double(limits.minimum - chunkLength) * 2.5
                }
                let boundary = tokens[end - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if strongEndPunctuation.contains(boundary) {
                    score -= max(1.0, Double(limits.preferred) * 0.35)
                } else if weakEndPunctuation.contains(boundary) {
                    score -= max(0.5, Double(limits.preferred) * 0.15)
                }
                if end == start + 1, chunkLength > limits.preferred { score += 1 }
                if score < bestScore {
                    bestScore = score
                    bestEnd = end
                }
            }
            output.append(Array(start..<bestEnd))
            start = bestEnd
        }
        if start < count { output.append(Array(start..<count)) }
        return output.filter { !$0.isEmpty }
    }

    private static func evenlySplitIndices(count: Int, chunks: Int) -> [[Int]] {
        let base = count / chunks
        let remainder = count % chunks
        var output: [[Int]] = []
        var start = 0
        for index in 0..<chunks {
            let take = base + (index < remainder ? 1 : 0)
            guard take > 0 else { continue }
            output.append(Array(start..<min(count, start + take)))
            start += take
        }
        if start < count { output.append(Array(start..<count)) }
        return output.filter { !$0.isEmpty }
    }

    private static func isDenseScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x3400...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
                || (0x0E00...0x0E7F).contains(value)
        }
    }
}
