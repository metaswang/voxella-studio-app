import Foundation

enum SubtitleBoundaryOptimizer {
    enum OptimizationError: Error { case invalidPolicy }
    struct Policy: Sendable {
        var exactReward = 1.2
        var projectedReward = 0.1
        var cueCost = 0.75
        var terminalReward = 0.75
        var punctuationReward = 0.2
        var continuationCost = 0.5
        var internalTerminalCost = 2.0

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
        let result = try ElasticSubtitleSegmenter.optimize(.init(
            text: sourceText, proposedLines: proposedLines, maximumCharacters: maximum, policy: policy
        ))
        return Result(lines: result.lines, projection: result.projection, forcedBoundaries: 0)
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
