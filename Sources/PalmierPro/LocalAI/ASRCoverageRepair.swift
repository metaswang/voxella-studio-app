import Foundation

/// Finds alignable speech that ASR/alignment left without words.
///
/// Timestamp decode + seek is the primary coverage mechanism. This pass is a
/// safety net for residual holes after honest segment times are available.
enum ASRCoverageRepair {
    struct Policy: Equatable, Sendable {
        var coveragePad: Double
        var minimumUncoveredDuration: Double
        var retryOverlapDuration: Double

        static let standard = Policy(
            coveragePad: 0.25,
            minimumUncoveredDuration: 0.75,
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

        let paddedCovered = merged(
            covered.compactMap { padded($0, by: policy.coveragePad, audioDuration: mask.audioDuration) }
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
            uncovered.filter {
                $0.end - $0.start >= policy.minimumUncoveredDuration
            }
        )
    }

    static func retryRanges(
        from uncovered: [ASRSpeechRange],
        audioDuration: Double,
        policy: Policy = .standard
    ) -> [ASRSpeechRange] {
        merged(
            uncovered.compactMap {
                padded($0, by: policy.retryOverlapDuration, audioDuration: audioDuration)
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
