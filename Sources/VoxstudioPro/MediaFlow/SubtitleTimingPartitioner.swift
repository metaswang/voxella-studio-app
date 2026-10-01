import Foundation

struct SubtitleTimingPartitioner {
    static func anchoredRanges(
        cueCount: Int,
        sourceWordCount: Int,
        anchorRanges: [Range<Int>?]
    ) -> [Range<Int>]? {
        guard cueCount > 0,
              sourceWordCount >= cueCount,
              anchorRanges.count == cueCount,
              anchorRanges.allSatisfy({ $0 != nil }),
              let anchored = anchoredPartition(
                sourceWordCount: sourceWordCount,
                anchors: anchorRanges.compactMap { $0 }
              ),
              anchored.count == cueCount else {
            return nil
        }
        return anchored
    }

    static func partition(
        cueCount: Int,
        sourceWordCount: Int,
        anchorRanges: [Range<Int>?],
        weights: [Int]
    ) -> [Range<Int>] {
        guard cueCount > 0, sourceWordCount >= cueCount, weights.count == cueCount else { return [] }
        if let covering = coveringRanges(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            anchorRanges: anchorRanges
        ) {
            return covering
        }
        return interpolatedPartition(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            weights: weights
        )
    }

    private static func coveringRanges(
        cueCount: Int,
        sourceWordCount: Int,
        anchorRanges: [Range<Int>?]
    ) -> [Range<Int>]? {
        if let anchored = anchoredRanges(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            anchorRanges: anchorRanges
        ) {
            return anchored
        }
        guard let filled = filledAnchors(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            anchors: anchorRanges
        ) else {
            return nil
        }
        return anchoredRanges(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            anchorRanges: filled.map { Optional($0) }
        )
    }

    private static func filledAnchors(
        cueCount: Int,
        sourceWordCount: Int,
        anchors: [Range<Int>?]
    ) -> [Range<Int>]? {
        guard cueCount > 0,
              sourceWordCount >= cueCount,
              anchors.count == cueCount,
              anchors.contains(where: { $0 != nil }) else {
            return nil
        }

        var known: [(index: Int, range: Range<Int>)] = []
        known.reserveCapacity(cueCount)
        for (index, anchor) in anchors.enumerated() {
            guard let anchor else { continue }
            guard anchor.lowerBound >= 0,
                  anchor.lowerBound < anchor.upperBound,
                  anchor.upperBound <= sourceWordCount else {
                return nil
            }
            if let previous = known.last, anchor.lowerBound < previous.range.upperBound {
                return nil
            }
            known.append((index, anchor))
        }
        guard !known.isEmpty else { return nil }

        var filled = anchors
        func assign(_ cueRange: Range<Int>, _ wordRange: Range<Int>) -> Bool {
            let count = cueRange.count
            guard count > 0 else { return true }
            guard wordRange.count >= count else { return false }
            let parts = interpolatedPartition(
                cueCount: count,
                sourceWordCount: wordRange.count,
                weights: Array(repeating: 1, count: count)
            )
            for (offset, part) in parts.enumerated() {
                filled[cueRange.lowerBound + offset] =
                    (wordRange.lowerBound + part.lowerBound)..<(wordRange.lowerBound + part.upperBound)
            }
            return true
        }

        let first = known[0]
        if first.index > 0 {
            guard assign(0..<first.index, 0..<first.range.lowerBound) else { return nil }
        }
        for (left, right) in zip(known, known.dropFirst()) {
            let cueStart = left.index + 1
            if cueStart < right.index {
                guard assign(cueStart..<right.index, left.range.upperBound..<right.range.lowerBound) else {
                    return nil
                }
            }
        }
        let last = known[known.count - 1]
        if last.index + 1 < cueCount {
            guard assign((last.index + 1)..<cueCount, last.range.upperBound..<sourceWordCount) else {
                return nil
            }
        }

        let concrete = filled.compactMap { $0 }
        guard concrete.count == cueCount else { return nil }
        return concrete
    }

    private static func anchoredPartition(
        sourceWordCount: Int,
        anchors: [Range<Int>]
    ) -> [Range<Int>]? {
        guard !anchors.isEmpty,
              anchors.allSatisfy({
                  $0.lowerBound >= 0
                      && $0.lowerBound < $0.upperBound
                      && $0.upperBound <= sourceWordCount
              }) else {
            return nil
        }
        var boundaries: [Int] = [0]
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            guard right.lowerBound >= left.upperBound else {
                return nil
            }
            let midpoint = left.upperBound + (right.lowerBound - left.upperBound) / 2
            boundaries.append(midpoint)
        }
        boundaries.append(sourceWordCount)
        let ranges = zip(boundaries, boundaries.dropFirst()).map { $0..<$1 }
        guard ranges.count == anchors.count,
              zip(ranges, anchors).allSatisfy({ range, anchor in
                  range.lowerBound <= anchor.lowerBound && range.upperBound >= anchor.upperBound
              }) else {
            return nil
        }
        return ranges
    }

    private static func interpolatedPartition(
        cueCount: Int,
        sourceWordCount: Int,
        weights: [Int]
    ) -> [Range<Int>] {
        let positiveWeights = weights.map { max(1, $0) }
        let totalWeight = positiveWeights.reduce(0, +)
        var result: [Range<Int>] = []
        result.reserveCapacity(cueCount)
        var lower = 0
        var consumedWeight = 0

        for index in 0..<cueCount {
            let remainingCues = cueCount - index - 1
            let upper: Int
            if index + 1 == cueCount {
                upper = sourceWordCount
            } else {
                consumedWeight += positiveWeights[index]
                let ideal = Int((Double(sourceWordCount) * Double(consumedWeight) / Double(totalWeight)).rounded())
                upper = min(sourceWordCount - remainingCues, max(lower + 1, ideal))
            }
            result.append(lower..<upper)
            lower = upper
        }
        return result
    }
}
