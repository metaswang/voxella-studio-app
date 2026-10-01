import Foundation

/// Finds alignable speech that ASR/alignment left without words.
///
/// Timestamp decode + seek is the primary coverage mechanism. This pass is a
/// safety net for residual holes after honest segment times are available.
enum ASRCoverageRepair {
    struct Policy: Equatable, Sendable {
        var coveragePad: Double
        /// Interior holes between two word clusters.
        var minimumUncoveredDuration: Double
        /// Leading/trailing holes with words on only one side.
        var minimumEdgeUncoveredDuration: Double
        var retryOverlapDuration: Double

        static let standard = Policy(
            coveragePad: 0.25,
            minimumUncoveredDuration: 0.75,
            minimumEdgeUncoveredDuration: 0.40,
            retryOverlapDuration: 1.0
        )
    }

    static func uncoveredSpeech(
        mask: AlignmentSpeechMask,
        covered: [ASRSpeechRange],
        policy: Policy = .standard
    ) -> [ASRSpeechRange] {
        let speech = AlignmentSpeechGate.alignableIntervals(mask: mask)
        guard !speech.isEmpty else { return [] }

        let wordRanges = merged(covered)
        let paddedCovered = merged(
            wordRanges.compactMap { padded($0, by: policy.coveragePad, audioDuration: mask.audioDuration) }
        )
        var uncovered: [ASRSpeechRange] = []
        for interval in speech {
            var remaining = [ASRSpeechRange(start: interval.startTime, end: interval.endTime)]
            for cover in paddedCovered {
                remaining = remaining.flatMap { subtracting($0, cover) }
            }
            uncovered.append(contentsOf: remaining)
        }
        return merged(
            uncovered.filter { hole in
                hole.end - hole.start >= minimumDuration(for: hole, covered: wordRanges, policy: policy)
            }
        )
    }

    static func retryRanges(
        from uncovered: [ASRSpeechRange],
        firstPassCovered: [ASRSpeechRange] = [],
        audioDuration: Double,
        policy: Policy = .standard
    ) -> [ASRSpeechRange] {
        let words = merged(firstPassCovered)
        return merged(
            uncovered.compactMap { hole in
                retryWindow(
                    for: hole,
                    firstPassCovered: words,
                    audioDuration: audioDuration,
                    policy: policy
                )
            }
        )
    }

    static func excluding(
        _ ranges: [ASRSpeechRange],
        overlapping uncovered: [ASRSpeechRange]
    ) -> [ASRSpeechRange] {
        ranges.filter { !overlaps($0, with: uncovered) }
    }

    static func overlaps(_ range: ASRSpeechRange, with uncovered: [ASRSpeechRange]) -> Bool {
        uncovered.contains { hole in
            range.end > hole.start && range.start < hole.end
        }
    }

    enum RetryOutcome: Equatable, Sendable {
        case accept
        case keepFirstPass
    }

    static func replacingCore(
        firstPassCovered: [ASRSpeechRange],
        retryCovered: [ASRSpeechRange],
        cores: [ASRSpeechRange]
    ) -> [ASRSpeechRange] {
        merged(
            excluding(firstPassCovered, overlapping: cores)
                + retryCovered.filter { overlaps($0, with: cores) }
        )
    }

    static func retryOutcome(
        firstPassCovered: [ASRSpeechRange],
        retryCovered: [ASRSpeechRange],
        cores: [ASRSpeechRange],
        mask: AlignmentSpeechMask
    ) -> RetryOutcome {
        let retryInCore = retryCovered.filter { overlaps($0, with: cores) }
        guard !retryInCore.isEmpty, !cores.isEmpty else { return .keepFirstPass }
        let spliced = replacingCore(
            firstPassCovered: firstPassCovered,
            retryCovered: retryCovered,
            cores: cores
        )
        let before = uncoveredSpeech(mask: mask, covered: firstPassCovered)
        let after = uncoveredSpeech(mask: mask, covered: spliced)
        return totalDuration(after) + 1e-6 < totalDuration(before) ? .accept : .keepFirstPass
    }

    private static func totalDuration(_ ranges: [ASRSpeechRange]) -> Double {
        ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    private static func minimumDuration(
        for hole: ASRSpeechRange,
        covered: [ASRSpeechRange],
        policy: Policy
    ) -> Double {
        isEdgeHole(hole, covered: covered)
            ? policy.minimumEdgeUncoveredDuration
            : policy.minimumUncoveredDuration
    }

    /// A hole is leading/trailing when words exist on at most one side.
    /// Interior breath gaps sit between two word clusters.
    private static func isEdgeHole(_ hole: ASRSpeechRange, covered: [ASRSpeechRange]) -> Bool {
        let hasBefore = covered.contains { $0.end <= hole.start + 1e-9 }
        let hasAfter = covered.contains { $0.start >= hole.end - 1e-9 }
        return !hasBefore || !hasAfter
    }

    /// Interior holes keep ±overlap into adjacent words. Edge holes stop at the
    /// nearest first-pass word so the decoder is not replayed across the same pause.
    private static func retryWindow(
        for hole: ASRSpeechRange,
        firstPassCovered: [ASRSpeechRange],
        audioDuration: Double,
        policy: Policy
    ) -> ASRSpeechRange? {
        guard var window = padded(
            hole,
            by: policy.retryOverlapDuration,
            audioDuration: audioDuration
        ) else { return nil }
        guard isEdgeHole(hole, covered: firstPassCovered) else { return window }
        if let lastBefore = firstPassCovered
            .filter({ $0.end <= hole.start + 1e-9 })
            .max(by: { $0.end < $1.end })
        {
            window = ASRSpeechRange(start: max(window.start, lastBefore.end), end: window.end)
        }
        if let firstAfter = firstPassCovered
            .filter({ $0.start >= hole.end - 1e-9 })
            .min(by: { $0.start < $1.start })
        {
            window = ASRSpeechRange(start: window.start, end: min(window.end, firstAfter.start))
        }
        return window.end > window.start ? window : nil
    }

    private static func padded(
        _ range: ASRSpeechRange,
        by pad: Double,
        audioDuration: Double
    ) -> ASRSpeechRange? {
        guard range.end > range.start,
              range.start.isFinite, range.end.isFinite,
              pad.isFinite, pad >= 0,
              audioDuration.isFinite, audioDuration > 0 else { return nil }
        let start = min(audioDuration, max(0, range.start - pad))
        let end = min(audioDuration, max(start, range.end + pad))
        return end > start ? ASRSpeechRange(start: start, end: end) : nil
    }

    private static func subtracting(
        _ interval: ASRSpeechRange,
        _ covered: ASRSpeechRange
    ) -> [ASRSpeechRange] {
        guard interval.end > covered.start, interval.start < covered.end else {
            return [interval]
        }
        var pieces: [ASRSpeechRange] = []
        if covered.start > interval.start {
            pieces.append(ASRSpeechRange(start: interval.start, end: min(interval.end, covered.start)))
        }
        if covered.end < interval.end {
            pieces.append(ASRSpeechRange(start: max(interval.start, covered.end), end: interval.end))
        }
        return pieces.filter { $0.end > $0.start }
    }

    private static func merged(_ ranges: [ASRSpeechRange]) -> [ASRSpeechRange] {
        let ordered = ranges.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [ASRSpeechRange] = []
        for range in ordered {
            guard let last = result.last, range.start <= last.end else {
                result.append(range)
                continue
            }
            result[result.count - 1] = ASRSpeechRange(start: last.start, end: max(last.end, range.end))
        }
        return result
    }
}
