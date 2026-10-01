import Foundation

/// Ensures each ASR text fragment is owned by exactly one recognition chunk.
///
/// Recognition windows may overlap for context, but text that enters forced
/// alignment must not repeat across adjacent ownership intervals.
enum ASROwnershipResolver {
    struct Result: Equatable, Sendable {
        var spans: [RecognizedSpan]
        var removedDuplicatePrefixes: Int
        var removedDuplicateSuffixes: Int
        var removedContainedSpans: Int
        var unresolvedBoundaryCount: Int

        var reconciledBoundaryCount: Int {
            removedDuplicatePrefixes + removedDuplicateSuffixes
        }
    }

    private static let maximumBoundaryOverlap = 120
    private static let adjacentGapTolerance = 0.35
    private static let longCharacterOverlap = 8
    private static let longTokenOverlap = 4

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
            return Result(
                spans: [],
                removedDuplicatePrefixes: 0,
                removedDuplicateSuffixes: 0,
                removedContainedSpans: 0,
                unresolvedBoundaryCount: 0
            )
        }

        var removedDuplicatePrefixes = 0
        var removedDuplicateSuffixes = 0
        var removedContainedSpans = 0
        var unresolvedBoundaryCount = 0
        var resolved: [RecognizedSpan] = []

        for span in ordered {
            var working = span

            if let previous = resolved.last, working.startTime - previous.endTime <= adjacentGapTolerance {
                if recognitionInputsOverlap(previous, working) {
                    let overlap = boundaryOverlap(
                        previous: previous.text,
                        current: working.text,
                        languageCode: languageCode
                    )
                    if overlap.isLong {
                        let stripped = droppingSuffix(
                            from: previous.text,
                            count: overlap.length,
                            usesCharacterTokens: overlap.usesCharacterTokens
                        )
                        if stripped != previous.text {
                            removedDuplicateSuffixes += 1
                            if let cleaned = Self.normalized(previous.withText(stripped)) {
                                resolved[resolved.count - 1] = cleaned
                            } else {
                                resolved.removeLast()
                            }
                        }
                    } else if overlap.length > 0 {
                        let withoutPrefix = droppingPrefix(
                            from: working.text,
                            count: overlap.length,
                            usesCharacterTokens: overlap.usesCharacterTokens
                        )
                        if withoutPrefix != working.text {
                            removedDuplicatePrefixes += 1
                            working = working.withText(withoutPrefix)
                        }
                    } else if hasUnprovenBoundaryOverlap(
                        previous: previous.text,
                        current: working.text,
                        languageCode: languageCode
                    ) {
                        unresolvedBoundaryCount += 1
                    }

                    if let cleaned = Self.normalized(working),
                       let container = resolved.last,
                       isTextContained(cleaned.text, in: container.text, languageCode: languageCode) {
                        removedContainedSpans += 1
                        continue
                    }
                }
            }

            if let cleaned = Self.normalized(working) {
                resolved.append(cleaned)
            }
        }

        return Result(
            spans: resolved,
            removedDuplicatePrefixes: removedDuplicatePrefixes,
            removedDuplicateSuffixes: removedDuplicateSuffixes,
            removedContainedSpans: removedContainedSpans,
            unresolvedBoundaryCount: unresolvedBoundaryCount
        )
    }

    private struct BoundaryOverlap {
        var length: Int
        var isLong: Bool
        var usesCharacterTokens: Bool
    }

    private static func boundaryOverlap(
        previous: String,
        current: String,
        languageCode: String?
    ) -> BoundaryOverlap {
        let usesCharacters = prefersCharacterTokens(languageCode: languageCode, text: previous + current)
        if usesCharacters {
            let length = compactOverlapLength(previous: previous, current: current)
            let minimum = minimumOverlap(languageCode: languageCode, text: previous + current)
            guard length >= minimum else {
                return BoundaryOverlap(length: 0, isLong: false, usesCharacterTokens: true)
            }
            return BoundaryOverlap(
                length: length,
                isLong: length >= longCharacterOverlap,
                usesCharacterTokens: true
            )
        }

        let tokenLength = tokenOverlapLength(previous: previous, current: current)
        if tokenLength >= longTokenOverlap {
            return BoundaryOverlap(length: tokenLength, isLong: true, usesCharacterTokens: false)
        }
        let characterLength = compactOverlapLength(previous: previous, current: current)
        let minimum = minimumOverlap(languageCode: languageCode, text: previous + current)
        guard characterLength >= minimum else {
            return BoundaryOverlap(length: 0, isLong: false, usesCharacterTokens: true)
        }
        return BoundaryOverlap(length: characterLength, isLong: false, usesCharacterTokens: true)
    }

    private static func compactOverlapLength(previous: String, current: String) -> Int {
        let preceding = compactFolded(previous)
        let following = compactFolded(current)
        guard !preceding.isEmpty, !following.isEmpty else { return 0 }
        let limit = min(preceding.count, following.count, maximumBoundaryOverlap)
        guard limit > 0 else { return 0 }
        for overlap in stride(from: limit, through: 1, by: -1) {
            if Array(preceding.suffix(overlap)) == Array(following.prefix(overlap)) {
                return overlap
            }
        }
        return 0
    }

    private static func tokenOverlapLength(previous: String, current: String) -> Int {
        let preceding = foldedTokens(previous)
        let following = foldedTokens(current)
        guard !preceding.isEmpty, !following.isEmpty else { return 0 }
        let limit = min(preceding.count, following.count, maximumBoundaryOverlap)
        guard limit > 0 else { return 0 }
        for overlap in stride(from: limit, through: 1, by: -1) {
            if Array(preceding.suffix(overlap)) == Array(following.prefix(overlap)) {
                return overlap
            }
        }
        return 0
    }

    private static func droppingPrefix(
        from text: String,
        count: Int,
        usesCharacterTokens: Bool
    ) -> String {
        usesCharacterTokens
            ? droppingCompactCharacters(from: text, count: count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : droppingLeadingTokens(from: text, count: count)
    }

    private static func droppingSuffix(
        from text: String,
        count: Int,
        usesCharacterTokens: Bool
    ) -> String {
        usesCharacterTokens
            ? droppingCompactSuffix(from: text, count: count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : droppingTrailingTokens(from: text, count: count)
    }

    private static func recognitionInputsOverlap(
        _ left: RecognizedSpan,
        _ right: RecognizedSpan
    ) -> Bool {
        guard let leftStart = left.inputStart, let leftEnd = left.inputEnd,
              let rightStart = right.inputStart, let rightEnd = right.inputEnd,
              leftStart.isFinite, leftEnd.isFinite, rightStart.isFinite, rightEnd.isFinite,
              leftEnd > leftStart, rightEnd > rightStart else {
            return true
        }
        return leftEnd > rightStart && leftStart < rightEnd
    }

    private static func hasUnprovenBoundaryOverlap(
        previous: String,
        current: String,
        languageCode: String?
    ) -> Bool {
        let length = compactOverlapLength(previous: previous, current: current)
        guard length > 0 else { return false }
        return length < minimumOverlap(languageCode: languageCode, text: previous + current)
    }

    private static func normalized(_ span: RecognizedSpan) -> RecognizedSpan? {
        let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              span.startTime.isFinite,
              span.endTime.isFinite,
              span.endTime > span.startTime,
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return span.withText(text)
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
        return left.firstRange(of: right) != nil
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

    private static func foldedTokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace }.map {
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

    private static func droppingCompactSuffix(from text: String, count: Int) -> String {
        guard count > 0 else { return text }
        var dropped = 0
        var end = text.endIndex
        while end > text.startIndex, dropped < count {
            end = text.index(before: end)
            if !text[end].isWhitespace { dropped += 1 }
        }
        return String(text[..<end])
    }

    private static func droppingLeadingTokens(from text: String, count: Int) -> String {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        guard count > 0, count < tokens.count else {
            return count >= tokens.count ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tokens.dropFirst(count).joined(separator: " ")
    }

    private static func droppingTrailingTokens(from text: String, count: Int) -> String {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        guard count > 0, count < tokens.count else {
            return count >= tokens.count ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tokens.dropLast(count).joined(separator: " ")
    }

}
