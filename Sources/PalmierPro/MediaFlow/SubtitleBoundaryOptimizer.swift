import Foundation

enum SubtitleBoundaryOptimizer {
    enum OptimizationError: Error { case invalidPolicy }
    struct Policy: Sendable {
        var exactReward = 1.5
        var projectedReward = 0.25
        var cueCost = 0.65
        var terminalReward = 0.8
        var punctuationReward = 0.25
        var continuationCost = 0.7
        var internalTerminalCost = 0.8

        var isValid: Bool {
            projectedReward <= exactReward && [exactReward, projectedReward, cueCost, terminalReward, punctuationReward,
             continuationCost, internalTerminalCost].allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }

    struct Projection: Sendable {
        var offsets: [Int]
        var matchedLines: Int
        var skippedLines: Int
        var resyncs: Int
        var exact: Bool
    }

    struct Result: Sendable {
        var lines: [String]
        var projection: Projection
        var forcedBoundaries: Int

        var mode: String {
            projection.exact ? "exact_hybrid" : (projection.offsets.isEmpty ? "local_fallback" : "projected_hybrid")
        }
    }

    static func projectBoundaries(sourceText: String, proposedLines: [String]) -> Projection {
        let source = Array(sourceText)
        var cursor = 0
        var matched = 0
        var skipped = 0
        var resyncs = 0
        var boundaries: [Int] = []
        for raw in proposedLines {
            let line = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !line.isEmpty else { skipped += 1; continue }
            while cursor < source.count, source[cursor].isWhitespace { cursor += 1 }
            let start: Int
            if matches(line, source, cursor) {
                start = cursor
            } else {
                var occurrences: [Int] = []
                if cursor <= source.count - line.count {
                    for index in cursor...(source.count - line.count) where matches(line, source, index) {
                        occurrences.append(index)
                        if occurrences.count > 1 { break }
                    }
                }
                guard occurrences.count == 1 else { skipped += 1; continue }
                start = occurrences[0]
                resyncs += 1
            }
            cursor = start + line.count
            while cursor < source.count, source[cursor].isWhitespace { cursor += 1 }
            if cursor < source.count, boundaries.last != cursor { boundaries.append(cursor) }
            matched += 1
        }
        return Projection(offsets: boundaries, matchedLines: matched, skippedLines: skipped, resyncs: resyncs,
                          exact: !proposedLines.isEmpty && skipped == 0 && resyncs == 0 && cursor == source.count)
    }

    static func optimize(sourceText: String, proposedLines: [String], dense: Bool,
                         minimum: Int, preferred: Int, maximum: Int, policy: Policy = Policy()) throws -> Result {
        try Task.checkCancellation()
        guard minimum >= 0, minimum <= preferred, preferred > 0, preferred <= maximum, policy.isValid else {
            throw OptimizationError.invalidPolicy
        }
        let projection = projectBoundaries(sourceText: sourceText, proposedLines: proposedLines)
        let chars = Array(sourceText)
        let n = chars.count
        guard n > 0 else { return Result(lines: [], projection: projection, forcedBoundaries: 0) }
        var positions: [Int: Int] = [0: 0]
        var utf16Offset = 0
        for (index, char) in chars.enumerated() {
            utf16Offset += String(char).utf16.count
            positions[utf16Offset] = index + 1
        }
        let wordPattern = try NSRegularExpression(pattern: #"(?w)\b"#)
        let wordEnds = Set(wordPattern.matches(in: sourceText, range: NSRange(location: 0, length: utf16Offset))
            .compactMap { positions[$0.range.location] })
        let punctuationPattern = try NSRegularExpression(pattern: #"^\p{P}$"#)
        let openingPattern = try NSRegularExpression(pattern: #"^[\p{Ps}\p{Pi}]$"#)
        let terminalPattern = try NSRegularExpression(pattern: #"^\p{STerm}$"#)
        let whitespace = chars.map(\.isWhitespace)
        let punctuation = chars.map { matchesProperty(punctuationPattern, $0) }
        let opening = chars.map { matchesProperty(openingPattern, $0) }
        let terminal = chars.enumerated().map { wordEnds.contains($0.offset + 1) && matchesProperty(terminalPattern, $0.element) }
        var nextVisible = Array(0...n)
        for index in stride(from: n - 1, through: 0, by: -1) where whitespace[index] {
            nextVisible[index] = nextVisible[index + 1]
        }
        var trimEnd = [0]
        var counts = [0]
        var terminals = [0]
        for index in 0..<n {
            trimEnd.append(whitespace[index] ? trimEnd[index] : index + 1)
            counts.append(counts[index] + ((!dense || !whitespace[index]) ? 1 : 0))
            terminals.append(terminals[index] + (terminal[index] ? 1 : 0))
        }
        let preferredEnds = Set(projection.offsets)
        var natural = Set(wordEnds.map { nextVisible[$0] }).union([0, n])
        natural = natural.filter { index in
            index == 0 || index == n || (!(punctuation[index] && !opening[index])
                && (trimEnd[index] == 0 || !opening[trimEnd[index] - 1]))
        }
        let cuts = Set(nextVisible).union([0, n]).sorted()
        let reward = projection.exact ? policy.exactReward : policy.projectedReward
        var costs = Array(repeating: Double.infinity, count: cuts.count)
        var forced = Array(repeating: n + 1, count: cuts.count)
        var previous = Array<Int?>(repeating: nil, count: cuts.count)
        costs[0] = 0
        forced[0] = 0
        for j in 1..<cuts.count {
            try Task.checkCancellation()
            let end = cuts[j]
            let b = trimEnd[end]
            for i in stride(from: j - 1, through: 0, by: -1) {
                let a = nextVisible[cuts[i]]
                let length = counts[b] - counts[a]
                if length > maximum { break }
                guard length > 0, costs[i].isFinite else { continue }
                var score = pow(Double(length - preferred) / Double(preferred), 2) + policy.cueCost
                score += Double(max(0, minimum - length)) / Double(max(1, minimum))
                if end < n {
                    score += terminal[b - 1] ? -policy.terminalReward
                        : (punctuation[b - 1] ? -policy.punctuationReward : policy.continuationCost)
                    if preferredEnds.contains(end) { score -= reward }
                }
                score += policy.internalTerminalCost * Double(terminals[b - 1] - terminals[a])
                let newForced = forced[i] + (natural.contains(end) ? 0 : 1)
                let newCost = costs[i] + score
                if newForced < forced[j] || (newForced == forced[j] && newCost < costs[j]) {
                    forced[j] = newForced
                    costs[j] = newCost
                    previous[j] = i
                }
            }
        }
        guard previous[cuts.count - 1] != nil else { return Result(lines: [], projection: projection, forcedBoundaries: 0) }
        var ends: [Int] = []
        var index = cuts.count - 1
        while index > 0 {
            ends.append(cuts[index])
            guard let prior = previous[index] else { return Result(lines: [], projection: projection, forcedBoundaries: 0) }
            index = prior
        }
        var lines: [String] = []
        var start = 0
        for end in ends.reversed() {
            lines.append(String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
        }
        return Result(lines: lines, projection: projection, forcedBoundaries: forced[cuts.count - 1])
    }

    private static func matches(_ needle: [Character], _ source: [Character], _ offset: Int) -> Bool {
        guard offset >= 0, offset + needle.count <= source.count else { return false }
        return String(source[offset..<(offset + needle.count)]).utf8.elementsEqual(String(needle).utf8)
    }

    private static func matchesProperty(_ pattern: NSRegularExpression, _ char: Character) -> Bool {
        let text = String(char)
        return pattern.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }
}
