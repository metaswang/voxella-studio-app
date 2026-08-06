import Foundation

struct SubtitleRemapSourceWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String?
}

struct SubtitleRemapDestinationToken: Equatable, Sendable {
    var text: String
    var subtitleIndex: Int
    var isPunctuation: Bool
}

struct SubtitleRemappedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String?
    var synthetic: Bool
    var timingSource: String
    var confidence: String
}

struct SubtitleRemapStats: Equatable, Sendable {
    var globalRatio: Double
    var insertedCount: Int
    var deletedCount: Int
    var abstainedGaps: Int
    var mappedDestinationCount: Int
    var usedSourceCount: Int
}

struct SubtitleRemapResult: Equatable, Sendable {
    var wordsBySubtitle: [[SubtitleRemappedWord]]
    var stats: SubtitleRemapStats
}

/// Back-maps LLM-rewritten subtitle tokens onto the original ASR word timings.
enum SubtitleTokenRemapper {
    enum TimingSource {
        static let inherited = "inherited"
        static let corrected = "corrected"
        static let split = "split"
        static let merge = "merge"
        static let synthetic = "synthetic"
    }

    enum Confidence {
        static let high = "high"
        static let medium = "medium"
        static let low = "low"
    }

    private static let minimumSubtitleDuration = 0.001
    private static let pauseGapMinimum = 0.08
    private static let pauseBoundarySearch = 0.75
    private static let insertCost = 0.95
    private static let deleteCost = 0.95
    private static let connectorTokens: Set<String> = ["'", "\u{2019}", "-"]

    /// Mirrors the worker's `ALLOWED_PUNCT`. Apostrophes and hyphens are connectors,
    /// not punctuation, so contractions stay alignable instead of being dropped.
    private static let punctuationCharacters: Set<Character> = [
        "\u{FF0C}", "\u{3002}", "\u{FF1F}", "\u{FF01}", ",", ".", "?", "!",
    ]

    private static let tokenSplitCharacters: Set<Character> = punctuationCharacters
        .union(["'", "\u{2019}", "-"])

    // MARK: - Tokenization

    static func tokenize(_ text: String, languageCode: String?) -> [SubtitleRemapDestinationToken] {
        tokenize(text, subtitleIndex: 0, useCharacterTokens: usesCharacterTokens(languageCode: languageCode, text: text))
    }

    static func buildDestinationTokens(fromSubtitles texts: [String], languageCode: String?) -> [SubtitleRemapDestinationToken] {
        let characterTokens = usesCharacterTokens(languageCode: languageCode, text: texts.joined())
        var tokens: [SubtitleRemapDestinationToken] = []
        for (index, text) in texts.enumerated() {
            tokens.append(contentsOf: tokenize(text, subtitleIndex: index, useCharacterTokens: characterTokens))
        }
        return tokens
    }

    private static func tokenize(
        _ text: String,
        subtitleIndex: Int,
        useCharacterTokens: Bool
    ) -> [SubtitleRemapDestinationToken] {
        let pieces = useCharacterTokens ? characterRunTokens(text) : spacedTokens(text)
        return pieces.map {
            SubtitleRemapDestinationToken(text: $0, subtitleIndex: subtitleIndex, isPunctuation: isPunctuation($0))
        }
    }

    /// Keeps ASCII alphanumeric runs together and emits every other character on its own.
    private static func characterRunTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var run = ""
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber {
                run.append(character)
                continue
            }
            if !run.isEmpty {
                tokens.append(run)
                run = ""
            }
            if character.isWhitespace { continue }
            tokens.append(String(character))
        }
        if !run.isEmpty { tokens.append(run) }
        return tokens
    }

    private static func spacedTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for part in text.split(whereSeparator: { $0.isWhitespace }) {
            var buffer = ""
            for character in part {
                if tokenSplitCharacters.contains(character) {
                    if !buffer.isEmpty {
                        tokens.append(buffer)
                        buffer = ""
                    }
                    tokens.append(String(character))
                    continue
                }
                buffer.append(character)
            }
            if !buffer.isEmpty { tokens.append(buffer) }
        }
        return tokens
    }

    private static func isPunctuation(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { punctuationCharacters.contains($0) }
    }

    private static func usesCharacterTokens(languageCode: String?, text: String) -> Bool {
        if let base = primaryLanguage(languageCode), ["zh", "yue", "ja", "ko"].contains(base) { return true }
        return text.unicodeScalars.contains(where: isHanIdeograph)
    }

    private static func primaryLanguage(_ code: String?) -> String? {
        guard let code else { return nil }
        let base = code
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        guard let base, !base.isEmpty else { return nil }
        return base
    }

    private static func isHanIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    // MARK: - Normalization helpers

    private static func normalized(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func canonicalPiece(_ token: String) -> String {
        let norm = normalized(token)
        if norm.isEmpty || connectorTokens.contains(norm) { return "" }
        return norm
    }

    private static func canonicalGroup(_ tokens: ArraySlice<String>) -> String {
        tokens.map(canonicalPiece).joined()
    }

    private static func groupSimilarity(_ sourceTokens: ArraySlice<String>, _ destinationTokens: ArraySlice<String>) -> Double {
        let sourceKey = canonicalGroup(sourceTokens)
        let destinationKey = canonicalGroup(destinationTokens)
        if sourceKey.isEmpty || destinationKey.isEmpty { return 0.0 }
        if sourceKey == destinationKey { return 1.0 }
        return sequenceRatio(sourceKey, destinationKey)
    }

    private static func isInformativeUnigram(_ token: String) -> Bool {
        let norm = normalized(token)
        if norm.isEmpty || connectorTokens.contains(norm) { return false }
        let compact = norm.filter { $0.isLetter || $0.isNumber }
        if compact.contains(where: { $0.isNumber }) { return true }
        if !compact.isEmpty, !compact.allSatisfy(\.isASCII) { return true }
        return compact.count >= 3
    }

    // MARK: - difflib-compatible similarity

    /// Mirrors `difflib.SequenceMatcher(autojunk=False).ratio()`.
    private static func sequenceRatio(_ a: String, _ b: String) -> Double {
        let left = Array(a)
        let right = Array(b)
        let total = left.count + right.count
        guard total > 0 else { return 1.0 }

        var occurrences: [Character: [Int]] = [:]
        for (index, character) in right.enumerated() {
            occurrences[character, default: []].append(index)
        }

        var matched = 0
        var pending: [(Int, Int, Int, Int)] = [(0, left.count, 0, right.count)]
        while let (alo, ahi, blo, bhi) = pending.popLast() {
            guard alo < ahi, blo < bhi else { continue }
            let block = longestMatch(left, right, occurrences, alo, ahi, blo, bhi)
            guard block.size > 0 else { continue }
            matched += block.size
            pending.append((alo, block.i, blo, block.j))
            pending.append((block.i + block.size, ahi, block.j + block.size, bhi))
        }
        return 2.0 * Double(matched) / Double(total)
    }

    private static func longestMatch(
        _ left: [Character],
        _ right: [Character],
        _ occurrences: [Character: [Int]],
        _ alo: Int,
        _ ahi: Int,
        _ blo: Int,
        _ bhi: Int
    ) -> (i: Int, j: Int, size: Int) {
        var bestI = alo
        var bestJ = blo
        var bestSize = 0
        var lengths: [Int: Int] = [:]
        for i in alo..<ahi {
            var next: [Int: Int] = [:]
            for j in occurrences[left[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let length = (lengths[j - 1] ?? 0) + 1
                next[j] = length
                if length > bestSize {
                    bestI = i - length + 1
                    bestJ = j - length + 1
                    bestSize = length
                }
            }
            lengths = next
        }
        return (bestI, bestJ, bestSize)
    }

    // MARK: - Anchor seeds

    private struct Seed {
        var sourceStart: Int
        var destinationStart: Int
        var length: Int
        var score: Double
    }

    private static func buildUniqueSeeds(_ sourceNorm: [String], _ destinationNorm: [String]) -> [Seed] {
        let maxN = min(4, sourceNorm.count, destinationNorm.count)
        guard maxN >= 1 else { return [] }

        var seeds: [Seed] = []
        for n in stride(from: maxN, through: 1, by: -1) {
            var sourcePositions: [[String]: [Int]] = [:]
            var destinationPositions: [[String]: [Int]] = [:]
            for i in 0...(sourceNorm.count - n) {
                sourcePositions[Array(sourceNorm[i..<(i + n)]), default: []].append(i)
            }
            for j in 0...(destinationNorm.count - n) {
                destinationPositions[Array(destinationNorm[j..<(j + n)]), default: []].append(j)
            }
            for (key, sources) in sourcePositions {
                guard sources.count == 1, let destinations = destinationPositions[key], destinations.count == 1 else { continue }
                if n == 1, !isInformativeUnigram(key[0]) { continue }
                seeds.append(
                    Seed(
                        sourceStart: sources[0],
                        destinationStart: destinations[0],
                        length: n,
                        score: Double(n * n) + (n > 1 ? 0.25 : 0.0)
                    )
                )
            }
        }
        return seeds
    }

    private static func chainSeeds(_ seeds: [Seed]) -> [Seed] {
        guard !seeds.isEmpty else { return [] }
        let ordered = seeds.sorted { lhs, rhs in
            if lhs.destinationStart != rhs.destinationStart { return lhs.destinationStart < rhs.destinationStart }
            if lhs.sourceStart != rhs.sourceStart { return lhs.sourceStart < rhs.sourceStart }
            return lhs.length > rhs.length
        }

        var best = ordered.map(\.score)
        var previous = [Int](repeating: -1, count: ordered.count)
        for i in ordered.indices {
            let seed = ordered[i]
            for j in 0..<i {
                let candidateSeed = ordered[j]
                let sourceEnd = candidateSeed.sourceStart + candidateSeed.length
                let destinationEnd = candidateSeed.destinationStart + candidateSeed.length
                if sourceEnd > seed.sourceStart || destinationEnd > seed.destinationStart { continue }
                let drift = abs((seed.sourceStart - sourceEnd) - (seed.destinationStart - destinationEnd))
                let score = best[j] + seed.score - (0.10 * Double(drift))
                if score > best[i] {
                    best[i] = score
                    previous[i] = j
                }
            }
        }

        var bestIndex = 0
        for index in ordered.indices where best[index] > best[bestIndex] {
            bestIndex = index
        }

        var chain: [Seed] = []
        var cursor = bestIndex
        while cursor != -1 {
            chain.append(ordered[cursor])
            cursor = previous[cursor]
        }
        return chain.reversed()
    }

    // MARK: - Gap alignment

    private enum GapStepKind {
        case match
        case split
        case merge
        case insert
        case delete
    }

    private struct GapStep {
        var kind: GapStepKind
        var sourceTake: Int
        var destinationTake: Int
        var similarity: Double
    }

    private static func blockCost(
        _ sourceTokens: ArraySlice<String>,
        _ destinationTokens: ArraySlice<String>,
        replacePairThreshold: Double
    ) -> (accepted: Bool, cost: Double, similarity: Double) {
        let sourceTake = sourceTokens.count
        let destinationTake = destinationTokens.count
        guard sourceTake > 0, destinationTake > 0 else { return (false, 0.0, 0.0) }

        let similarity = groupSimilarity(sourceTokens, destinationTokens)
        if sourceTake == 1, destinationTake == 1 {
            if normalized(sourceTokens[sourceTokens.startIndex]) == normalized(destinationTokens[destinationTokens.startIndex]) {
                return (true, 0.0, 1.0)
            }
            if canonicalGroup(sourceTokens) == canonicalGroup(destinationTokens) {
                return (true, 0.04, 0.995)
            }
            if similarity >= max(0.78, replacePairThreshold) {
                return (true, 0.22 + (1.0 - similarity), similarity)
            }
            return (false, 0.0, similarity)
        }

        guard min(sourceTake, destinationTake) == 1 else { return (false, 0.0, similarity) }

        if canonicalGroup(sourceTokens) == canonicalGroup(destinationTokens) {
            return (true, 0.12 + (0.04 * Double(max(sourceTake, destinationTake) - 1)), 1.0)
        }

        let threshold = max(0.84, replacePairThreshold + 0.18)
        guard similarity >= threshold else { return (false, 0.0, similarity) }
        let fragmentation = 0.14 + (0.05 * Double(max(sourceTake, destinationTake) - 1))
        return (true, fragmentation + (1.0 - similarity), similarity)
    }

    private static func alignGap(
        _ sourceTokens: ArraySlice<String>,
        _ destinationTokens: ArraySlice<String>,
        replacePairThreshold: Double
    ) -> (steps: [GapStep], abstained: Bool) {
        let source = Array(sourceTokens)
        let destination = Array(destinationTokens)
        let sourceLength = source.count
        let destinationLength = destination.count

        func fallback() -> [GapStep] {
            let deletes = (0..<sourceLength).map { _ in GapStep(kind: .delete, sourceTake: 1, destinationTake: 0, similarity: 0.0) }
            let inserts = (0..<destinationLength).map { _ in GapStep(kind: .insert, sourceTake: 0, destinationTake: 1, similarity: 0.0) }
            return deletes + inserts
        }

        if sourceLength <= 0, destinationLength <= 0 { return ([], false) }
        if sourceLength <= 0 || destinationLength <= 0 { return (fallback(), false) }

        // Large ambiguous gaps are safer to abstain from than to overfit with opaque edits.
        if sourceLength * destinationLength > 6400, min(sourceLength, destinationLength) >= 12 {
            return (fallback(), true)
        }

        let infinity = 1e12
        var costs = [[Double]](repeating: [Double](repeating: infinity, count: destinationLength + 1), count: sourceLength + 1)
        var backtrack = [[(Int, Int, GapStep)?]](
            repeating: [(Int, Int, GapStep)?](repeating: nil, count: destinationLength + 1),
            count: sourceLength + 1
        )
        costs[0][0] = 0.0

        func relax(_ nextI: Int, _ nextJ: Int, _ candidate: Double, _ step: GapStep, _ fromI: Int, _ fromJ: Int) {
            if candidate < costs[nextI][nextJ] {
                costs[nextI][nextJ] = candidate
                backtrack[nextI][nextJ] = (fromI, fromJ, step)
            }
        }

        for i in 0...sourceLength {
            for j in 0...destinationLength {
                let current = costs[i][j]
                if current >= infinity { continue }
                if j < destinationLength {
                    relax(i, j + 1, current + insertCost, GapStep(kind: .insert, sourceTake: 0, destinationTake: 1, similarity: 0.0), i, j)
                }
                if i < sourceLength {
                    relax(i + 1, j, current + deleteCost, GapStep(kind: .delete, sourceTake: 1, destinationTake: 0, similarity: 0.0), i, j)
                }
                if i < sourceLength, j < destinationLength {
                    let block = blockCost(source[i..<(i + 1)], destination[j..<(j + 1)], replacePairThreshold: replacePairThreshold)
                    if block.accepted {
                        relax(
                            i + 1,
                            j + 1,
                            current + block.cost,
                            GapStep(kind: .match, sourceTake: 1, destinationTake: 1, similarity: block.similarity),
                            i,
                            j
                        )
                    }
                }
                if i < sourceLength {
                    for take in 2...3 where j + take <= destinationLength {
                        let block = blockCost(source[i..<(i + 1)], destination[j..<(j + take)], replacePairThreshold: replacePairThreshold)
                        if block.accepted {
                            relax(
                                i + 1,
                                j + take,
                                current + block.cost,
                                GapStep(kind: .split, sourceTake: 1, destinationTake: take, similarity: block.similarity),
                                i,
                                j
                            )
                        }
                    }
                }
                if j < destinationLength {
                    for take in 2...3 where i + take <= sourceLength {
                        let block = blockCost(source[i..<(i + take)], destination[j..<(j + 1)], replacePairThreshold: replacePairThreshold)
                        if block.accepted {
                            relax(
                                i + take,
                                j + 1,
                                current + block.cost,
                                GapStep(kind: .merge, sourceTake: take, destinationTake: 1, similarity: block.similarity),
                                i,
                                j
                            )
                        }
                    }
                }
            }
        }

        if costs[sourceLength][destinationLength] >= infinity { return (fallback(), true) }

        var steps: [GapStep] = []
        var i = sourceLength
        var j = destinationLength
        while i > 0 || j > 0 {
            guard let item = backtrack[i][j] else { return (fallback(), true) }
            steps.append(item.2)
            i = item.0
            j = item.1
        }
        steps.reverse()

        let paired = steps.filter { $0.sourceTake > 0 && $0.destinationTake > 0 }
        let matchedDestination = paired.reduce(0) { $0 + $1.destinationTake }
        let similarityWeight = paired.reduce(0) { $0 + max($1.sourceTake, $1.destinationTake) }
        let weightedSimilarity = paired.reduce(0.0) { $0 + ($1.similarity * Double(max($1.sourceTake, $1.destinationTake))) }
        let averageSimilarity = weightedSimilarity / Double(similarityWeight == 0 ? 1 : similarityWeight)
        let baseline = (insertCost * Double(destinationLength)) + (deleteCost * Double(sourceLength))
        let improvement = max(0.0, baseline - costs[sourceLength][destinationLength])

        var abstained = false
        if matchedDestination == 0 {
            abstained = true
        } else if improvement < 0.35, max(sourceLength, destinationLength) >= 3 {
            abstained = true
        } else if averageSimilarity < 0.68, matchedDestination < max(2, Int(0.75 * Double(destinationLength))) {
            abstained = true
        }
        return (steps, abstained)
    }

    // MARK: - Timing helpers

    private struct Assignment {
        var sourceIndices: [Int]
        var start: Double
        var end: Double
        var timingSource: String
        var confidence: String
    }

    private static func splitSpan(start: Double, end: Double, weights: [Double]) -> [(Double, Double)] {
        guard !weights.isEmpty else { return [] }
        let segmentStart = start
        let segmentEnd = max(start, end)
        let duration = max(0.0, segmentEnd - segmentStart)
        if duration <= 0.0 { return weights.map { _ in (segmentStart, segmentStart) } }

        let safeWeights = weights.map { max(1.0, $0) }
        let total = safeWeights.reduce(0.0, +)
        let denominator = total == 0.0 ? 1.0 : total
        var spans: [(Double, Double)] = []
        var cursor = segmentStart
        var consumed = 0.0
        for (index, weight) in safeWeights.enumerated() {
            var next: Double
            if index + 1 == safeWeights.count {
                next = segmentEnd
            } else {
                consumed += weight
                next = segmentStart + (duration * consumed / denominator)
            }
            if next < cursor { next = cursor }
            spans.append((cursor, next))
            cursor = next
        }
        if let last = spans.last {
            spans[spans.count - 1] = (last.0, segmentEnd)
        }
        return spans
    }

    private static func assignmentConfidence(similarity: Double, timingSource: String) -> String {
        if similarity >= 0.995, timingSource == TimingSource.inherited { return Confidence.high }
        if similarity >= 0.90 { return Confidence.high }
        if similarity >= 0.75 { return Confidence.medium }
        return Confidence.low
    }

    private static func speaker(of sourceWords: [SubtitleRemapSourceWord], at indices: [Int]) -> String? {
        for index in indices where index >= 0 && index < sourceWords.count {
            let value = sourceWords[index].speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func wordWeight(_ text: String) -> Double {
        let canonical = canonicalPiece(text)
        return Double(max(1, canonical.isEmpty ? text.count : canonical.count))
    }

    private static func dominantSpeaker(in words: [SubtitleRemappedWord]) -> String? {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var seen = 0
        for word in words {
            let value = word.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty { continue }
            counts[value, default: 0] += 1
            if firstSeen[value] == nil { firstSeen[value] = seen }
            seen += 1
        }
        var best: String?
        var bestCount = -1
        var bestOrder = Int.max
        for (name, count) in counts {
            let order = firstSeen[name] ?? Int.max
            if count > bestCount || (count == bestCount && order < bestOrder) {
                best = name
                bestCount = count
                bestOrder = order
            }
        }
        return best
    }

    private static func neighborSpeaker(_ wordsBySubtitle: [[SubtitleRemappedWord]], at index: Int) -> String? {
        var left = index - 1
        while left >= 0 {
            if let speaker = dominantSpeaker(in: wordsBySubtitle[left]) { return speaker }
            left -= 1
        }
        var right = index + 1
        while right < wordsBySubtitle.count {
            if let speaker = dominantSpeaker(in: wordsBySubtitle[right]) { return speaker }
            right += 1
        }
        return nil
    }

    private static func normalizeWordsInWindow(
        _ words: [SubtitleRemappedWord],
        segmentStart: Double,
        segmentEnd: Double
    ) -> [SubtitleRemappedWord] {
        var output: [SubtitleRemappedWord] = []
        output.reserveCapacity(words.count)
        var previousEnd = segmentStart
        let upper = max(segmentStart, segmentEnd)
        for word in words {
            var item = word
            var start = min(upper, max(segmentStart, word.start))
            var end = min(upper, max(start, word.end))
            if start < previousEnd {
                start = previousEnd
                if end < start { end = start }
            }
            item.start = start
            item.end = end
            output.append(item)
            previousEnd = end
        }
        return output
    }

    private static func sourcePause(
        _ sourceWords: [SubtitleRemapSourceWord],
        after index: Int,
        minimumGap: Double
    ) -> (leftEnd: Double, rightStart: Double, gap: Double)? {
        guard index >= 0, index + 1 < sourceWords.count else { return nil }
        let leftEnd = sourceWords[index].end
        let rightStart = sourceWords[index + 1].start
        let gap = rightStart - leftEnd
        guard gap >= minimumGap else { return nil }
        return (leftEnd, rightStart, gap)
    }

    private static func applyPauseAwareBoundaries(
        windows: [(Double, Double)],
        sourceWords: [SubtitleRemapSourceWord],
        tokensBySubtitle: [[Int]],
        assignmentsByToken: [Int: Assignment],
        minimumGap: Double,
        boundarySearch: Double
    ) -> [(Double, Double)] {
        var adjusted = windows
        guard adjusted.count >= 2, sourceWords.count >= 2, minimumGap > 0.0 else { return adjusted }
        let search = max(0.0, boundarySearch)

        func assignedSourceIndices(subtitleIndex: Int) -> [Int] {
            guard subtitleIndex >= 0, subtitleIndex < tokensBySubtitle.count else { return [] }
            var indices = Set<Int>()
            for tokenIndex in tokensBySubtitle[subtitleIndex] {
                guard let assignment = assignmentsByToken[tokenIndex] else { continue }
                indices.formUnion(assignment.sourceIndices)
            }
            return indices.sorted()
        }

        for boundary in 0..<(adjusted.count - 1) {
            let (leftStart, leftEnd) = adjusted[boundary]
            let (rightStart, rightEnd) = adjusted[boundary + 1]
            let reference = (leftEnd + rightStart) / 2.0

            var candidates: [(index: Int, leftEnd: Double, rightStart: Double, gap: Double)] = []
            let leftIndices = assignedSourceIndices(subtitleIndex: boundary)
            let rightIndices = assignedSourceIndices(subtitleIndex: boundary + 1)
            if let leftMax = leftIndices.max(), let rightMin = rightIndices.min(), leftMax < rightMin {
                for index in leftMax..<rightMin {
                    guard let pause = sourcePause(sourceWords, after: index, minimumGap: minimumGap) else { continue }
                    let middle = (pause.leftEnd + pause.rightStart) / 2.0
                    if abs(middle - reference) <= search + 1e-9 {
                        candidates.append((index, pause.leftEnd, pause.rightStart, pause.gap))
                    }
                }
            }

            if candidates.isEmpty {
                for index in 0..<(sourceWords.count - 1) {
                    guard let pause = sourcePause(sourceWords, after: index, minimumGap: minimumGap) else { continue }
                    let middle = (pause.leftEnd + pause.rightStart) / 2.0
                    if abs(middle - reference) <= search + 1e-9 {
                        candidates.append((index, pause.leftEnd, pause.rightStart, pause.gap))
                    }
                }
            }

            guard var chosen = candidates.first else { continue }
            var chosenDistance = -abs(((chosen.leftEnd + chosen.rightStart) / 2.0) - reference)
            for candidate in candidates.dropFirst() {
                let distance = -abs(((candidate.leftEnd + candidate.rightStart) / 2.0) - reference)
                if candidate.gap > chosen.gap || (candidate.gap == chosen.gap && distance > chosenDistance) {
                    chosen = candidate
                    chosenDistance = distance
                }
            }

            if chosen.rightStart <= chosen.leftEnd { continue }
            if chosen.leftEnd <= leftStart + minimumSubtitleDuration { continue }
            if chosen.rightStart >= rightEnd - minimumSubtitleDuration { continue }

            adjusted[boundary] = (leftStart, chosen.leftEnd)
            adjusted[boundary + 1] = (chosen.rightStart, rightEnd)
        }

        return adjusted
    }

    // MARK: - Remap

    static func remap(
        sourceWords: [SubtitleRemapSourceWord],
        destinationTokens: [SubtitleRemapDestinationToken],
        batchStart: Double,
        batchEnd: Double,
        languageCode: String?,
        globalRatioThreshold: Double = 0.60,
        replacePairThreshold: Double = 0.60
    ) -> SubtitleRemapResult {
        let sources = sourceWords.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sourceTexts = sources.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        let subtitleCount = max(0, 1 + (destinationTokens.map(\.subtitleIndex).max() ?? -1))

        var alignableTokenIndices: [Int] = []
        var alignableTexts: [String] = []
        var alignableSubtitles: [Int] = []
        for (index, token) in destinationTokens.enumerated() where !token.isPunctuation {
            alignableTokenIndices.append(index)
            alignableTexts.append(token.text)
            alignableSubtitles.append(token.subtitleIndex)
        }

        let sourceNorm = sourceTexts.map(normalized)
        let destinationNorm = alignableTexts.map(normalized)

        var assignments: [Int: Assignment] = [:]
        var usedSourceIndices = Set<Int>()

        func register(_ destinationIndex: Int, _ assignment: Assignment) {
            if let current = assignments[destinationIndex], current.sourceIndices.count >= assignment.sourceIndices.count { return }
            assignments[destinationIndex] = assignment
            usedSourceIndices.formUnion(assignment.sourceIndices)
        }

        func applyGap(sourceFrom: Int, sourceTo: Int, destinationFrom: Int, destinationTo: Int) -> Int {
            let sourceRange = sourceFrom..<max(sourceFrom, sourceTo)
            let destinationRange = destinationFrom..<max(destinationFrom, destinationTo)
            let result = alignGap(
                sourceTexts[sourceRange],
                alignableTexts[destinationRange],
                replacePairThreshold: replacePairThreshold
            )
            var sourceCursor = sourceRange.lowerBound
            var destinationCursor = destinationRange.lowerBound
            for step in result.steps {
                switch step.kind {
                case .match:
                    let word = sources[sourceCursor]
                    register(
                        destinationCursor,
                        Assignment(
                            sourceIndices: [sourceCursor],
                            start: word.start,
                            end: word.end,
                            timingSource: step.similarity >= 0.995 ? TimingSource.inherited : TimingSource.corrected,
                            confidence: assignmentConfidence(similarity: step.similarity, timingSource: TimingSource.inherited)
                        )
                    )
                case .split:
                    let word = sources[sourceCursor]
                    let weights = (0..<step.destinationTake).map { wordWeight(alignableTexts[destinationCursor + $0]) }
                    let spans = splitSpan(start: word.start, end: word.end, weights: weights)
                    for (offset, span) in spans.enumerated() {
                        register(
                            destinationCursor + offset,
                            Assignment(
                                sourceIndices: [sourceCursor],
                                start: span.0,
                                end: span.1,
                                timingSource: TimingSource.split,
                                confidence: assignmentConfidence(similarity: step.similarity, timingSource: TimingSource.split)
                            )
                        )
                    }
                case .merge:
                    let indices = (0..<step.sourceTake).map { sourceCursor + $0 }
                    let start = sources[indices[0]].start
                    let end = sources[indices[indices.count - 1]].end
                    register(
                        destinationCursor,
                        Assignment(
                            sourceIndices: indices,
                            start: start,
                            end: max(start, end),
                            timingSource: TimingSource.merge,
                            confidence: assignmentConfidence(similarity: step.similarity, timingSource: TimingSource.merge)
                        )
                    )
                case .insert, .delete:
                    break
                }
                sourceCursor += step.sourceTake
                destinationCursor += step.destinationTake
            }
            return (result.abstained && !result.steps.isEmpty) ? 1 : 0
        }

        var abstainedGaps = 0
        var sourceCursor = 0
        var destinationCursor = 0
        for seed in chainSeeds(buildUniqueSeeds(sourceNorm, destinationNorm)) {
            abstainedGaps += applyGap(
                sourceFrom: sourceCursor,
                sourceTo: seed.sourceStart,
                destinationFrom: destinationCursor,
                destinationTo: seed.destinationStart
            )
            for offset in 0..<seed.length {
                let sourceIndex = seed.sourceStart + offset
                let word = sources[sourceIndex]
                register(
                    seed.destinationStart + offset,
                    Assignment(
                        sourceIndices: [sourceIndex],
                        start: word.start,
                        end: word.end,
                        timingSource: TimingSource.inherited,
                        confidence: Confidence.high
                    )
                )
            }
            sourceCursor = seed.sourceStart + seed.length
            destinationCursor = seed.destinationStart + seed.length
        }
        abstainedGaps += applyGap(
            sourceFrom: sourceCursor,
            sourceTo: sourceTexts.count,
            destinationFrom: destinationCursor,
            destinationTo: alignableTexts.count
        )

        let mappedCount = assignments.count
        let denominator = Double(sourceTexts.count + alignableTexts.count)
        let globalRatio = denominator > 0.0 ? Double(usedSourceIndices.count + mappedCount) / denominator : 1.0

        var windowStarts = [Double?](repeating: nil, count: subtitleCount)
        var windowEnds = [Double?](repeating: nil, count: subtitleCount)
        for (alignableIndex, assignment) in assignments {
            guard alignableIndex >= 0, alignableIndex < alignableSubtitles.count else { continue }
            let subtitleIndex = alignableSubtitles[alignableIndex]
            guard subtitleIndex >= 0, subtitleIndex < subtitleCount else { continue }
            let start = assignment.start
            let end = max(assignment.start, assignment.end)
            windowStarts[subtitleIndex] = windowStarts[subtitleIndex].map { min($0, start) } ?? start
            windowEnds[subtitleIndex] = windowEnds[subtitleIndex].map { max($0, end) } ?? end
        }

        var tokensBySubtitle = [[Int]](repeating: [], count: subtitleCount)
        for (index, token) in destinationTokens.enumerated() {
            let subtitleIndex = token.subtitleIndex
            if subtitleIndex >= 0, subtitleIndex < subtitleCount {
                tokensBySubtitle[subtitleIndex].append(index)
            }
        }

        func fillGap(after left: Int?, before right: Int?, gapStart: Double, gapEnd: Double) {
            let lower = left.map { $0 + 1 } ?? 0
            let upper = right ?? subtitleCount
            guard lower < upper else { return }
            let group = (lower..<upper).filter { windowStarts[$0] == nil }
            guard !group.isEmpty else { return }
            let start = gapStart
            let end = max(gapStart, gapEnd)
            let duration = max(0.0, end - start)
            let weights = group.map { Double(max(1, tokensBySubtitle[$0].count)) }
            let total = weights.reduce(0.0, +)
            let denominator = total == 0.0 ? 1.0 : total
            var cursor = start
            for (index, weight) in zip(group, weights) {
                let share = duration > 0.0 ? duration * weight / denominator : 0.0
                let segmentEnd = max(cursor, cursor + share)
                windowStarts[index] = cursor
                windowEnds[index] = segmentEnd
                cursor = segmentEnd
            }
        }

        let anchored = (0..<subtitleCount).filter { windowStarts[$0] != nil && windowEnds[$0] != nil }
        if let first = anchored.first, let last = anchored.last {
            fillGap(after: nil, before: first, gapStart: batchStart, gapEnd: windowStarts[first] ?? batchStart)
            for (left, right) in zip(anchored, anchored.dropFirst()) {
                fillGap(
                    after: left,
                    before: right,
                    gapStart: windowEnds[left] ?? batchStart,
                    gapEnd: windowStarts[right] ?? batchEnd
                )
            }
            fillGap(after: last, before: nil, gapStart: windowEnds[last] ?? batchStart, gapEnd: batchEnd)
        } else {
            fillGap(after: nil, before: nil, gapStart: batchStart, gapEnd: batchEnd)
        }

        var clampedWindows: [(Double, Double)] = []
        clampedWindows.reserveCapacity(subtitleCount)
        for index in 0..<subtitleCount {
            var start = windowStarts[index] ?? batchStart
            var end = windowEnds[index] ?? start
            if index > 0 { start = max(start, clampedWindows[index - 1].1) }
            if index + 1 < subtitleCount, let nextStart = windowStarts[index + 1] { end = min(end, nextStart) }
            if end < start { end = start }
            clampedWindows.append((start, end))
        }

        var assignmentsByToken: [Int: Assignment] = [:]
        for (alignableIndex, assignment) in assignments where alignableIndex >= 0 && alignableIndex < alignableTokenIndices.count {
            assignmentsByToken[alignableTokenIndices[alignableIndex]] = assignment
        }

        clampedWindows = applyPauseAwareBoundaries(
            windows: clampedWindows,
            sourceWords: sources,
            tokensBySubtitle: tokensBySubtitle,
            assignmentsByToken: assignmentsByToken,
            minimumGap: pauseGapMinimum,
            boundarySearch: pauseBoundarySearch
        )

        var previousMapped = [Int?](repeating: nil, count: destinationTokens.count)
        var nextMapped = [Int?](repeating: nil, count: destinationTokens.count)
        var lastSeen: Int?
        for index in destinationTokens.indices {
            if assignmentsByToken[index] != nil { lastSeen = index }
            previousMapped[index] = lastSeen
        }
        var upcoming: Int?
        for index in destinationTokens.indices.reversed() {
            if assignmentsByToken[index] != nil { upcoming = index }
            nextMapped[index] = upcoming
        }

        var wordsBySubtitle = [[SubtitleRemappedWord]](repeating: [], count: subtitleCount)
        for subtitleIndex in 0..<subtitleCount {
            let segmentStart = clampedWindows[subtitleIndex].0
            var segmentEnd = clampedWindows[subtitleIndex].1
            if segmentEnd <= segmentStart {
                segmentEnd = min(batchEnd, segmentStart + minimumSubtitleDuration)
            }

            var words: [SubtitleRemappedWord] = []
            words.reserveCapacity(tokensBySubtitle[subtitleIndex].count)
            for tokenIndex in tokensBySubtitle[subtitleIndex] {
                let token = destinationTokens[tokenIndex]
                if let assignment = assignmentsByToken[tokenIndex] {
                    words.append(
                        SubtitleRemappedWord(
                            text: token.text,
                            start: assignment.start,
                            end: max(assignment.start, assignment.end),
                            speaker: speaker(of: sources, at: assignment.sourceIndices),
                            synthetic: false,
                            timingSource: assignment.timingSource,
                            confidence: assignment.confidence
                        )
                    )
                    continue
                }

                let leftAssignment = previousMapped[tokenIndex].flatMap { assignmentsByToken[$0] }
                let rightAssignment = nextMapped[tokenIndex].flatMap { assignmentsByToken[$0] }
                var time: Double
                if let left = leftAssignment, let right = rightAssignment {
                    time = left.end + (max(0.0, right.start - left.end) * 0.5)
                } else if let left = leftAssignment {
                    time = left.end
                } else if let right = rightAssignment {
                    time = right.start
                } else {
                    time = segmentStart
                }
                time = min(segmentEnd, max(segmentStart, time))

                var inherited: String?
                if let left = leftAssignment { inherited = speaker(of: sources, at: left.sourceIndices) }
                if inherited == nil, let right = rightAssignment { inherited = speaker(of: sources, at: right.sourceIndices) }
                if inherited == nil { inherited = neighborSpeaker(wordsBySubtitle, at: subtitleIndex) }

                words.append(
                    SubtitleRemappedWord(
                        text: token.text,
                        start: time,
                        end: time,
                        speaker: inherited,
                        synthetic: true,
                        timingSource: TimingSource.synthetic,
                        confidence: Confidence.low
                    )
                )
            }

            wordsBySubtitle[subtitleIndex] = normalizeWordsInWindow(words, segmentStart: segmentStart, segmentEnd: segmentEnd)
        }

        return SubtitleRemapResult(
            wordsBySubtitle: wordsBySubtitle,
            stats: SubtitleRemapStats(
                globalRatio: globalRatio,
                insertedCount: max(0, alignableTexts.count - mappedCount),
                deletedCount: max(0, sourceTexts.count - usedSourceIndices.count),
                abstainedGaps: abstainedGaps,
                mappedDestinationCount: mappedCount,
                usedSourceCount: usedSourceIndices.count
            )
        )
    }
}
