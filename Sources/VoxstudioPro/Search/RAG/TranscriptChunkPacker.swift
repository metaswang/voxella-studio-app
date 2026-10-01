import Foundation

enum TranscriptChunkPacker {
    static let preferredDuration = 50.0
    static let minimumDuration = 25.0
    static let maximumDuration = 90.0
    static let pauseGap = 1.8
    static let overlapDuration = 10.0
    static let minimumCharacters = 100

    struct Chunk: Equatable, Sendable {
        let start: Double
        let end: Double
        let speakerLabels: [String]
        let text: String
    }

    static func pack(segments: [TranscriptionSegment]) -> [Chunk] {
        let ordered = segments
            .filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
        guard !ordered.isEmpty else { return [] }

        var windows: [[TranscriptionSegment]] = []
        var current: [TranscriptionSegment] = []

        for segment in ordered {
            if current.isEmpty {
                current = [segment]
                continue
            }

            let duration = windowDuration(current)
            let withNext = max(current[current.count - 1].end, segment.end) - current[0].start
            let gap = segment.start - current[current.count - 1].end
            let speakerChanged = hardSpeakerChange(from: current[current.count - 1], to: segment)
            let ready = meetsMinimum(current)

            let shouldFlush =
                (withNext > maximumDuration && ready)
                || (withNext > preferredDuration && duration >= preferredDuration && ready)
                || (speakerChanged && ready)
                || (gap > pauseGap && ready)

            if shouldFlush {
                windows.append(current)
                current = [segment]
            } else {
                current.append(segment)
            }
        }

        if !current.isEmpty {
            windows.append(current)
        }

        return applyOverlap(mergeShortWindows(windows))
    }

    private static func applyOverlap(_ windows: [[TranscriptionSegment]]) -> [Chunk] {
        windows.enumerated().map { index, segments in
            let overlap = index > 0 ? overlapSegments(from: windows[index - 1]) : []
            let speakers = orderedUnique(segments.compactMap { normalizedSpeaker($0.speaker) })
            return Chunk(
                start: segments[0].start,
                end: segments[segments.count - 1].end,
                speakerLabels: speakers,
                text: SpeakerPrefixedText.joined(
                    (overlap + segments).map { ($0.speaker, $0.text) }
                )
            )
        }
    }

    private static func overlapSegments(from previous: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard let end = previous.last?.end else { return [] }
        let tailStart = end - overlapDuration
        return previous.filter { $0.start >= tailStart }
    }

    private static func mergeShortWindows(
        _ windows: [[TranscriptionSegment]]
    ) -> [[TranscriptionSegment]] {
        var merged: [[TranscriptionSegment]] = []
        for window in windows {
            guard let last = merged.last, !meetsMinimum(window) else {
                merged.append(window)
                continue
            }
            let combined = last + window
            if windowDuration(combined) <= maximumDuration {
                merged[merged.count - 1] = combined
            } else {
                merged.append(window)
            }
        }

        var index = 0
        while index < merged.count - 1 {
            guard !meetsMinimum(merged[index]) else {
                index += 1
                continue
            }
            let combined = merged[index] + merged[index + 1]
            if windowDuration(combined) <= maximumDuration {
                merged[index] = combined
                merged.remove(at: index + 1)
            } else {
                index += 1
            }
        }
        return merged
    }

    private static func meetsMinimum(_ segments: [TranscriptionSegment]) -> Bool {
        guard !segments.isEmpty else { return false }
        if windowDuration(segments) >= minimumDuration { return true }
        let characters = segments.reduce(0) { count, segment in
            count + segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        return characters >= minimumCharacters
    }

    private static func windowDuration(_ segments: [TranscriptionSegment]) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        return max(0, last.end - first.start)
    }

    private static func hardSpeakerChange(
        from lhs: TranscriptionSegment,
        to rhs: TranscriptionSegment
    ) -> Bool {
        guard let left = normalizedSpeaker(lhs.speaker),
              let right = normalizedSpeaker(rhs.speaker),
              left != right
        else { return false }
        return rhs.speakerBoundary != .soft
    }

    private static func normalizedSpeaker(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
