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
            let trimmed = trimRepeatedContent(
                in: span.text,
                duration: span.duration,
                languageCode: languageCode
            )
            if trimmed != span.text {
                statistics.trimmedRepeatedSpans += 1
                processed[index] = span.withText(trimmed)
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
                speaker: $0.speaker,
                speakerConfidence: $0.speakerConfidence,
                speakerBoundary: $0.speakerBoundary
            )
        }
    }

    private static func normalize(_ span: RecognizedSpan) -> RecognizedSpan? {
        guard span.startTime.isFinite,
              span.endTime.isFinite,
              span.endTime > span.startTime else { return nil }
        let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactCharacters(in: text).isEmpty else { return nil }
        return span.withText(text)
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
                result.append(merged(previous, current, languageCode: languageCode))
                statistics.mergedShortSpans += 1
            } else if canMergeFollowing, let following {
                remaining.removeFirst()
                remaining.insert(merged(current, following, languageCode: languageCode), at: 0)
                statistics.mergedShortSpans += 1
            } else {
                result.append(current)
            }
        }
        return result
    }

    private static func trimRepeatedContent(
        in text: String,
        duration: Double,
        languageCode: String?
    ) -> String {
        var result = text
        let rateThreshold = hasNoWordSpacing(languageCode: languageCode, text: text) ? 10.0 : 14.0
        while let run = suspiciousRepeatedRun(
            in: compactCharacters(in: result),
            duration: duration,
            rateThreshold: rateThreshold
        ) {
            let removal = (run.start + run.phraseLength)..<(run.start + run.phraseLength * run.count)
            result = removingCompactCharacters(in: result, range: removal)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func suspiciousRepeatedRun(
        in characters: [Character],
        duration: Double,
        rateThreshold: Double
    ) -> (start: Int, phraseLength: Int, count: Int)? {
        guard characters.count >= 6 else { return nil }
        let characterRate = Double(characters.count) / max(duration, 0.1)
        var best: (start: Int, phraseLength: Int, count: Int)?

        for start in characters.indices {
            let remaining = characters.count - start
            let maximumPhraseLength = min(
                maximumRepeatedPhraseLength,
                remaining / minimumRepeatedPhraseCount
            )
            guard maximumPhraseLength > 0 else { continue }

            for phraseLength in 1...maximumPhraseLength {
                let minimumCount = phraseLength == 1 ? 6 : minimumRepeatedPhraseCount
                guard remaining >= phraseLength * minimumCount else { continue }
                let phrase = Array(characters[start..<(start + phraseLength)])
                var count = 1
                var cursor = start + phraseLength
                while cursor + phraseLength <= characters.count,
                      Array(characters[cursor..<(cursor + phraseLength)]) == phrase {
                    count += 1
                    cursor += phraseLength
                }

                let repeatedCharacterCount = phraseLength * count
                let consumesMostOfSpan = repeatedCharacterCount >= max(6, Int(Double(characters.count) * 0.4))
                guard count >= minimumCount,
                      repeatedCharacterCount >= 6,
                      characterRate >= rateThreshold || consumesMostOfSpan else {
                    continue
                }
                guard best == nil
                    || repeatedCharacterCount > best!.phraseLength * best!.count
                    || (repeatedCharacterCount == best!.phraseLength * best!.count && start < best!.start) else {
                    continue
                }
                best = (start, phraseLength, count)
            }
        }
        return best
    }

    private static func merged(
        _ left: RecognizedSpan,
        _ right: RecognizedSpan,
        languageCode: String?
    ) -> RecognizedSpan {
        let inputStart: Double?
        if let leftStart = left.inputStart, let rightStart = right.inputStart {
            inputStart = min(leftStart, rightStart)
        } else {
            inputStart = left.inputStart ?? right.inputStart
        }
        let inputEnd: Double?
        if let leftEnd = left.inputEnd, let rightEnd = right.inputEnd {
            inputEnd = max(leftEnd, rightEnd)
        } else {
            inputEnd = left.inputEnd ?? right.inputEnd
        }
        return RecognizedSpan(
            text: joining(left.text, right.text, languageCode: languageCode),
            startTime: min(left.startTime, right.startTime),
            endTime: max(left.endTime, right.endTime),
            inputStart: inputStart,
            inputEnd: inputEnd
        )
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

    private static func removingCompactCharacters(in text: String, range: Range<Int>) -> String {
        var compactIndex = 0
        var output = ""
        for character in text {
            if character.isWhitespace {
                output.append(character)
                continue
            }
            defer { compactIndex += 1 }
            if !range.contains(compactIndex) { output.append(character) }
        }
        return output
    }
}
