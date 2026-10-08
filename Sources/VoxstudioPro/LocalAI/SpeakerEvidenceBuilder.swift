import Foundation

/// Non-overlapped speech of one transcript speaker label, kept so identity can
/// be matched (and re-matched) without rerunning diarization.
struct SpeakerChannelEvidence: Codable, Equatable, Sendable {
    /// Anonymous label at transcription time, e.g. "Speaker 2".
    var label: String
    /// Stretches where only this speaker is active, longest first, ≥ 1 s.
    var cleanRanges: [SpeechTimeRange]
    var activeDuration: Double
    /// Labels with simultaneous speech; they cannot be the same person.
    var overlapsWith: [String]

    var cleanDuration: Double { cleanRanges.reduce(0) { $0 + $1.end - $1.start } }
}

enum SpeakerEvidenceBuilder {
    static let minimumCleanRange = 1.0
    static let minimumOverlap = 0.3
    static let maximumRanges = 60

    static func build(
        timeline: SpeakerActivityTimeline,
        words: [TranscriptionWord]
    ) -> [SpeakerChannelEvidence] {
        guard timeline.diagnostics.backend.producesSpeakerActivity, !timeline.intervals.isEmpty else { return [] }
        // Final labels come from word attribution; map each channel to the
        // label its words were given.
        var votes: [Int: [String: Double]] = [:]
        for word in words {
            guard let label = SpeakerLabelResolver.normalized(word.speaker),
                  let start = word.start, let end = word.end, end > start,
                  let channel = timeline.attributionForWord(start: start, end: end)?.speakerID else { continue }
            votes[channel, default: [:]][label, default: 0] += end - start
        }
        let labelByChannel = votes.compactMapValues { counts in
            counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }
        let byChannel = Dictionary(grouping: timeline.intervals, by: \.speakerID)

        var clean: [String: [SpeechTimeRange]] = [:]
        var active: [String: Double] = [:]
        for (channel, intervals) in byChannel {
            guard let label = labelByChannel[channel] else { continue }
            let others = timeline.intervals.filter { $0.speakerID != channel }
                .map { SpeechTimeRange(start: $0.start, end: $0.end) }
            for interval in intervals {
                active[label, default: 0] += interval.end - interval.start
                clean[label, default: []].append(contentsOf: subtract(
                    SpeechTimeRange(start: interval.start, end: interval.end), others
                ))
            }
        }

        var overlaps: [String: Set<String>] = [:]
        var overlapDuration: [String: [String: Double]] = [:]
        for lhs in timeline.intervals {
            for rhs in timeline.intervals where rhs.speakerID > lhs.speakerID {
                guard let left = labelByChannel[lhs.speakerID], let right = labelByChannel[rhs.speakerID],
                      left != right else { continue }
                let shared = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
                guard shared > 0 else { continue }
                overlapDuration[left, default: [:]][right, default: 0] += shared
                overlapDuration[right, default: [:]][left, default: 0] += shared
            }
        }
        for (label, others) in overlapDuration {
            overlaps[label] = Set(others.filter { $0.value >= minimumOverlap }.map(\.key))
        }

        let labels = Set(labelByChannel.values)
        return labels.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { label in
            let ranges = (clean[label] ?? [])
                .filter { $0.end - $0.start >= minimumCleanRange }
                .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
                .prefix(maximumRanges)
            return SpeakerChannelEvidence(
                label: label,
                cleanRanges: Array(ranges),
                activeDuration: active[label] ?? 0,
                overlapsWith: (overlaps[label] ?? []).sorted()
            )
        }
    }

    /// `range` minus the union of `others`.
    static func subtract(_ range: SpeechTimeRange, _ others: [SpeechTimeRange]) -> [SpeechTimeRange] {
        var pieces = [range]
        for other in others where other.end > range.start && other.start < range.end {
            pieces = pieces.flatMap { piece -> [SpeechTimeRange] in
                guard other.end > piece.start, other.start < piece.end else { return [piece] }
                var kept: [SpeechTimeRange] = []
                if other.start > piece.start { kept.append(SpeechTimeRange(start: piece.start, end: other.start)) }
                if other.end < piece.end { kept.append(SpeechTimeRange(start: other.end, end: piece.end)) }
                return kept
            }
        }
        return pieces
    }
}
