import Foundation

/// Ensures each ASR text fragment is owned by exactly one recognition chunk.
///
/// Recognition windows may overlap for context, but text that enters forced
/// alignment must not repeat across adjacent ownership intervals.
enum ASROwnershipResolver {
    struct Result: Equatable, Sendable {
        var spans: [RecognizedSpan]
        var removedDuplicatePrefixes: Int
        var removedContainedSpans: Int
    }

    private static let maximumBoundaryOverlap = 120
    private static let adjacentGapTolerance = 0.35

    static func resolve(
        spans: [RecognizedSpan],
        languageCode: String?
    ) -> Result {
        let ordered = spans.compactMap(Self.normalized).sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.text.count > $1.text.count
        }
        guard !ordered.isEmpty else {
            return Result(spans: [], removedDuplicatePrefixes: 0, removedContainedSpans: 0)
        }

        var removedDuplicatePrefixes = 0
        var removedContainedSpans = 0
        var resolved: [RecognizedSpan] = []

        for span in ordered {
            var working = span

            if let previous = resolved.last, working.startTime - previous.endTime <= adjacentGapTolerance {
                let withoutPrefix = removingDuplicatePrefix(
                    from: working.text,
                    after: previous.text,
                    languageCode: languageCode
                )
                if withoutPrefix != working.text {
                    removedDuplicatePrefixes += 1
                    working = RecognizedSpan(
                        text: withoutPrefix,
                        startTime: working.startTime,
                        endTime: working.endTime
                    )
                }

                if let cleaned = Self.normalized(working),
                   isTextContained(cleaned.text, in: previous.text, languageCode: languageCode) {
                    removedContainedSpans += 1
                    continue
                }
            }

            if let cleaned = Self.normalized(working) {
                resolved.append(cleaned)
            }
        }

        return Result(
            spans: resolved,
            removedDuplicatePrefixes: removedDuplicatePrefixes,
            removedContainedSpans: removedContainedSpans
        )
    }

    /// When ASR segment times are clamped into an ownership window, also drop
    /// the portion of text that proportionally falls outside that window.
    static func clampTextToOwnership(
        text: String,
        absoluteStart: Double,
        absoluteEnd: Double,
        ownershipStart: Double,
        ownershipEnd: Double
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              absoluteEnd > absoluteStart,
              ownershipEnd > ownershipStart else { return "" }

        let ownedStart = max(absoluteStart, ownershipStart)
        let ownedEnd = min(absoluteEnd, ownershipEnd)
        guard ownedEnd > ownedStart else { return "" }

        let fullDuration = absoluteEnd - absoluteStart
        let ownedRatioStart = (ownedStart - absoluteStart) / fullDuration
        let ownedRatioEnd = (ownedEnd - absoluteStart) / fullDuration
        if ownedRatioStart <= 0.001, ownedRatioEnd >= 0.999 {
            return trimmed
        }

        let characters = Array(trimmed.filter { !$0.isWhitespace })
        guard !characters.isEmpty else { return "" }
        let startIndex = Int((ownedRatioStart * Double(characters.count)).rounded(.down))
        let endIndex = Int((ownedRatioEnd * Double(characters.count)).rounded(.up))
        let lower = min(characters.count, max(0, startIndex))
        let upper = min(characters.count, max(lower, endIndex))
        guard upper > lower else { return "" }

        return reconstructing(Array(characters[lower..<upper]), from: trimmed)
    }

    private static func normalized(_ span: RecognizedSpan) -> RecognizedSpan? {
        let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              span.startTime.isFinite,
              span.endTime.isFinite,
              span.endTime > span.startTime,
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return RecognizedSpan(text: text, startTime: span.startTime, endTime: span.endTime)
    }

    private static func isTextContained(
        _ candidate: String,
        in container: String,
        languageCode: String?
    ) -> Bool {
        let left = compactFolded(container)
        let right = compactFolded(candidate)
        guard right.count >= minimumOverlap(languageCode: languageCode, text: candidate) else {
            return false
        }
        return left.contains(right)
    }

    private static func removingDuplicatePrefix(
        from current: String,
        after previous: String,
        languageCode: String?
    ) -> String {
        let preceding = compactFolded(previous)
        let following = compactFolded(current)
        guard !preceding.isEmpty, !following.isEmpty else { return current }
        let minimum = minimumOverlap(languageCode: languageCode, text: previous + current)
        let limit = min(preceding.count, following.count, maximumBoundaryOverlap)
        guard limit >= minimum else { return current }

        for overlap in stride(from: limit, through: minimum, by: -1) {
            guard Array(preceding.suffix(overlap)) == Array(following.prefix(overlap)) else { continue }
            return droppingCompactCharacters(from: current, count: overlap)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    private static func minimumOverlap(languageCode: String?, text: String) -> Int {
        prefersCharacterTokens(languageCode: languageCode, text: text) ? 2 : 4
    }

    private static func prefersCharacterTokens(languageCode: String?, text: String) -> Bool {
        let noSpaceLanguages: Set<String> = ["zh", "yue", "ja", "ko", "th", "lo", "my", "km", "bo"]
        if let base = languageCode?.lowercased().split(separator: "-").first,
           noSpaceLanguages.contains(String(base)) {
            return true
        }
        let compact = text.filter { !$0.isWhitespace }
        return compact.count >= 10 && !text.contains(where: \.isWhitespace)
    }

    private static func compactFolded(_ text: String) -> [String] {
        text.filter { !$0.isWhitespace }.map {
            String($0).folding(options: [.caseInsensitive], locale: .current)
        }
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

    private static func reconstructing(_ characters: [Character], from template: String) -> String {
        guard !characters.isEmpty else { return "" }
        var result = ""
        var characterIndex = 0
        for character in template {
            if character.isWhitespace {
                if !result.isEmpty { result.append(character) }
                continue
            }
            guard characterIndex < characters.count else { break }
            result.append(characters[characterIndex])
            characterIndex += 1
        }
        while characterIndex < characters.count {
            result.append(characters[characterIndex])
            characterIndex += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
