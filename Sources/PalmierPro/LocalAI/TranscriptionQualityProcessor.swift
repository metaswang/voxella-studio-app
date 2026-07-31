import Foundation

struct TranscriptionQualityStatistics: Equatable, Sendable {
    var mergedShortSpans = 0
    var trimmedRepeatedSpans = 0
    var removedCrossSpanPrefixes = 0

    var warning: String? {
        var parts: [String] = []
        if trimmedRepeatedSpans > 0 {
            parts.append("trimmed \(trimmedRepeatedSpans) repeated ASR span\(trimmedRepeatedSpans == 1 ? "" : "s")")
        }
        if removedCrossSpanPrefixes > 0 {
            parts.append("removed \(removedCrossSpanPrefixes) duplicate boundary prefix\(removedCrossSpanPrefixes == 1 ? "" : "es")")
        }
        return parts.isEmpty ? nil : "Transcript quality filter \(parts.joined(separator: "; "))."
    }
}

struct TranscriptionPreprocessingResult: Sendable {
    let spans: [RecognizedSpan]
    let statistics: TranscriptionQualityStatistics
}

enum TranscriptionQualityProcessor {
    private static let shortSpanDuration = 0.45
    private static let adjacentSpanGap = 0.25
    private static let maximumRepeatedPhraseLength = 20
    private static let minimumRepeatedPhraseCount = 3
    private static let maximumBoundaryOverlap = 80

    static func preprocess(
        spans: [RecognizedSpan],
        languageCode: String?
    ) -> TranscriptionPreprocessingResult {
        let normalized = spans.compactMap(normalize)
        guard !normalized.isEmpty else {
            return .init(spans: [], statistics: .init())
        }

        var statistics = TranscriptionQualityStatistics()
        var processed = mergeShortSpans(normalized, languageCode: languageCode, statistics: &statistics)
        for index in processed.indices {
            let span = processed[index]
            let trimmed = trimRepeatedSuffix(
                in: span.text,
                duration: span.duration,
                languageCode: languageCode
            )
            if trimmed != span.text {
                statistics.trimmedRepeatedSpans += 1
                processed[index] = .init(text: trimmed, startTime: span.startTime, endTime: span.endTime)
            }
        }

        for index in processed.indices.dropFirst() {
            let previous = processed[index - 1]
            let current = processed[index]
            guard current.startTime - previous.endTime <= adjacentSpanGap else { continue }
            let trimmed = removingDuplicatePrefix(from: current.text, after: previous.text, languageCode: languageCode)
            if trimmed != current.text {
                statistics.removedCrossSpanPrefixes += 1
                processed[index] = .init(text: trimmed, startTime: current.startTime, endTime: current.endTime)
            }
        }

        return .init(
            spans: processed.compactMap(normalize),
            statistics: statistics
        )
    }

    static func postprocess(
        _ words: [TranscriptionWord],
        chineseScript: ChineseTranscriptScript?
    ) -> [TranscriptionWord] {
        guard let chineseScript else { return words }
        return words.map {
            .init(
                text: chineseScript.applying(to: $0.text),
                start: $0.start,
                end: $0.end,
                speaker: $0.speaker
            )
        }
    }

    private static func normalize(_ span: RecognizedSpan) -> RecognizedSpan? {
        guard span.startTime.isFinite,
              span.endTime.isFinite,
              span.endTime > span.startTime else { return nil }
        let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactCharacters(in: text).isEmpty else { return nil }
        return .init(text: text, startTime: span.startTime, endTime: span.endTime)
    }

    private static func mergeShortSpans(
        _ spans: [RecognizedSpan],
        languageCode: String?,
        statistics: inout TranscriptionQualityStatistics
    ) -> [RecognizedSpan] {
        var remaining = spans.sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
        var result: [RecognizedSpan] = []

        while !remaining.isEmpty {
            let current = remaining.removeFirst()
            guard current.duration < shortSpanDuration else {
                result.append(current)
                continue
            }

            let previous = result.last
            let following = remaining.first
            let previousGap = previous.map { current.startTime - $0.endTime }
            let followingGap = following.map { $0.startTime - current.endTime }
            let canMergePrevious = previousGap.map { $0 >= 0 && $0 <= adjacentSpanGap } ?? false
            let canMergeFollowing = followingGap.map { $0 >= 0 && $0 <= adjacentSpanGap } ?? false

            if canMergePrevious, (!canMergeFollowing || (previousGap ?? .infinity) <= (followingGap ?? .infinity)),
               let previous {
                result.removeLast()
                result.append(.init(
                    text: joining(previous.text, current.text, languageCode: languageCode),
                    startTime: previous.startTime,
                    endTime: current.endTime
                ))
                statistics.mergedShortSpans += 1
            } else if canMergeFollowing, let following {
                remaining.removeFirst()
                remaining.insert(.init(
                    text: joining(current.text, following.text, languageCode: languageCode),
                    startTime: current.startTime,
                    endTime: following.endTime
                ), at: 0)
                statistics.mergedShortSpans += 1
            } else {
                result.append(current)
            }
        }
        return result
    }

    private static func trimRepeatedSuffix(
        in text: String,
        duration: Double,
        languageCode: String?
    ) -> String {
        let compact = compactCharacters(in: text)
        guard compact.count >= minimumRepeatedPhraseCount * 2 else { return text }
        let rateThreshold = hasNoWordSpacing(languageCode: languageCode, text: text) ? 10.0 : 14.0
        let characterRate = Double(compact.count) / max(duration, 0.1)
        let maximumPhraseLength = min(maximumRepeatedPhraseLength, compact.count / minimumRepeatedPhraseCount)

        for phraseLength in 2...maximumPhraseLength {
            let phrase = Array(compact.suffix(phraseLength))
            var count = 1
            var cursor = compact.count - phraseLength
            while cursor >= phraseLength,
                  Array(compact[(cursor - phraseLength)..<cursor]) == phrase {
                count += 1
                cursor -= phraseLength
            }
            guard count >= minimumRepeatedPhraseCount else { continue }

            let repeatedCharacterCount = phraseLength * count
            let hasSuspiciousDensity = characterRate >= rateThreshold
            let consumesMostOfSpan = repeatedCharacterCount >= max(6, Int(Double(compact.count) * 0.4))
            guard hasSuspiciousDensity || consumesMostOfSpan else { continue }

            return keepingCompactCharacters(
                in: text,
                count: compact.count - phraseLength * (count - 1)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard isDegenerate(compact), characterRate >= rateThreshold else { return text }
        let finalCharacter = compact.last
        let trailingCount = compact.reversed().prefix { $0 == finalCharacter }.count
        guard trailingCount >= minimumRepeatedPhraseCount else { return text }
        return keepingCompactCharacters(in: text, count: compact.count - trailingCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingDuplicatePrefix(
        from current: String,
        after previous: String,
        languageCode: String?
    ) -> String {
        let preceding = compactCharacters(in: previous).map { String($0).folding(options: [.caseInsensitive], locale: .current) }
        let following = compactCharacters(in: current).map { String($0).folding(options: [.caseInsensitive], locale: .current) }
        guard !preceding.isEmpty, !following.isEmpty else { return current }
        let minimumOverlap = hasNoWordSpacing(languageCode: languageCode, text: previous + current) ? 2 : 4
        let limit = min(preceding.count, following.count, maximumBoundaryOverlap)
        guard limit >= minimumOverlap else { return current }

        for overlap in stride(from: limit, through: minimumOverlap, by: -1) {
            guard Array(preceding.suffix(overlap)) == Array(following.prefix(overlap)) else { continue }
            return droppingCompactCharacters(from: current, count: overlap)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    private static func isDegenerate(_ characters: [Character]) -> Bool {
        guard characters.count >= 4 else { return false }
        let counts = Dictionary(grouping: characters, by: { $0 }).mapValues(\.count).values.sorted(by: >)
        guard let mostCommon = counts.first else { return false }
        let topRatio = Double(mostCommon) / Double(characters.count)
        if characters.count < 8 { return topRatio >= 0.95 }
        if characters.count < 64 { return topRatio >= 0.80 }
        let topTwoRatio = Double(counts.prefix(2).reduce(0, +)) / Double(characters.count)
        return topRatio >= 0.65 || topTwoRatio >= 0.80
    }

    private static func joining(_ left: String, _ right: String, languageCode: String?) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if hasNoWordSpacing(languageCode: languageCode, text: left + right)
            || left.last?.isWhitespace == true
            || right.first?.isWhitespace == true {
            return left + right
        }
        return left + " " + right
    }

    private static func hasNoWordSpacing(languageCode: String?, text: String) -> Bool {
        let noSpaceLanguages: Set<String> = ["zh", "yue", "ja", "ko", "th", "lo", "my", "km", "bo"]
        if let base = languageCode?.lowercased().split(separator: "-").first,
           noSpaceLanguages.contains(String(base)) {
            return true
        }
        return compactCharacters(in: text).count >= 10 && !text.contains(where: \.isWhitespace)
    }

    private static func compactCharacters(in text: String) -> [Character] {
        text.filter { !$0.isWhitespace }
    }

    private static func keepingCompactCharacters(in text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        var kept = ""
        var retained = 0
        for character in text {
            if !character.isWhitespace {
                guard retained < count else { break }
                retained += 1
            }
            kept.append(character)
        }
        return kept
    }

    private static func droppingCompactCharacters(from text: String, count: Int) -> String {
        guard count > 0 else { return text }
        var dropped = 0
        var start = text.startIndex
        while start < text.endIndex, dropped < count {
            if !text[start].isWhitespace { dropped += 1 }
            start = text.index(after: start)
        }
        return String(text[start...])
    }
}
