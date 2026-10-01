import Foundation

enum CuePacker {
    static let preferredDuration = 12.0
    static let minimumDuration = 8.0
    static let maximumDuration = 20.0
    static let pauseGap = 1.2

    struct Clip: Equatable, Sendable {
        let start: Double
        let end: Double
        let cueIDs: [Int]
        let speakerLabels: [String]
        let text: String
    }

    static func pack(cues: [SubtitleCue], shotBounds: [Double] = []) -> [Clip] {
        let ordered = cues
            .filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return [] }

        let shots = shotBounds.filter(\.isFinite).sorted()
        var clips: [Clip] = []
        var current: [SubtitleCue] = []

        for cue in ordered {
            if current.isEmpty {
                current = [cue]
                continue
            }

            let windowStart = current[0].start
            let windowEnd = current[current.count - 1].end
            let nextEnd = max(windowEnd, cue.end)
            let duration = windowEnd - windowStart
            let withCueDuration = nextEnd - windowStart
            let gap = cue.start - windowEnd
            let speakerChanged = hardSpeakerChange(from: current[current.count - 1], to: cue)
            let crossedShot = crossesShotBoundary(windowEnd, cue.start, shots)

            let shouldFlush =
                (withCueDuration > maximumDuration && duration >= minimumDuration)
                || (speakerChanged && duration >= minimumDuration)
                || (gap > pauseGap && duration >= minimumDuration)
                || (crossedShot && duration >= minimumDuration)

            if shouldFlush {
                clips.append(makeClip(current))
                current = [cue]
            } else {
                current.append(cue)
            }
        }

        if !current.isEmpty {
            clips.append(makeClip(current))
        }
        return clips
    }

    static func videoOnlyWindows(duration: Double, shotBounds: [Double] = []) -> [Clip] {
        guard duration.isFinite, duration > 0 else { return [] }
        var bounds = shotBounds.filter { $0.isFinite && $0 > 0 && $0 < duration }.sorted()
        bounds.insert(0, at: 0)
        if bounds.last != duration { bounds.append(duration) }

        var windows: [(start: Double, end: Double)] = []
        for index in 0..<(bounds.count - 1) {
            let start = bounds[index]
            let end = bounds[index + 1]
            if end - start <= maximumDuration {
                windows.append((start, end))
                continue
            }
            var cursor = start
            while cursor < end {
                let next = min(end, cursor + preferredDuration)
                windows.append((cursor, next))
                cursor = next
            }
        }

        return mergeShortWindows(windows).map { window in
            Clip(start: window.start, end: window.end, cueIDs: [], speakerLabels: [], text: "")
        }
    }

    private static func makeClip(_ cues: [SubtitleCue]) -> Clip {
        let speakers = orderedUnique(cues.compactMap(\.speaker))
        return Clip(
            start: cues[0].start,
            end: cues[cues.count - 1].end,
            cueIDs: cues.map(\.id),
            speakerLabels: speakers,
            text: SpeakerPrefixedText.joined(cues.map { ($0.speaker, $0.text) })
        )
    }

    private static func hardSpeakerChange(from lhs: SubtitleCue, to rhs: SubtitleCue) -> Bool {
        guard let left = lhs.speaker, let right = rhs.speaker else { return false }
        return left != right
    }

    private static func crossesShotBoundary(_ from: Double, _ to: Double, _ shots: [Double]) -> Bool {
        shots.contains { $0 > from && $0 < to }
    }

    private static func mergeShortWindows(
        _ windows: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        var merged: [(start: Double, end: Double)] = []
        for window in windows {
            guard let last = merged.last, window.end - window.start < minimumDuration else {
                merged.append(window)
                continue
            }
            let combined = (last.start, window.end)
            if combined.1 - combined.0 <= maximumDuration {
                merged[merged.count - 1] = combined
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
