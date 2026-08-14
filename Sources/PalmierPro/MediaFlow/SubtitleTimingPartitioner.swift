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
        usesAnchorTiming: Bool,
        weights: [Int]
    ) -> [Range<Int>] {
        guard cueCount > 0, sourceWordCount >= cueCount, weights.count == cueCount else { return [] }
        if usesAnchorTiming,
           let anchored = anchoredRanges(
                cueCount: cueCount,
                sourceWordCount: sourceWordCount,
                anchorRanges: anchorRanges
           ) {
            return anchored
        }
        return interpolatedPartition(
            cueCount: cueCount,
            sourceWordCount: sourceWordCount,
            weights: weights
        )
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
