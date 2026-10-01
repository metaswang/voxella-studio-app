import Foundation

enum SpeechInputSegmentPlanner {
    static let maximumSegmentDuration: Double = 20
    static let overlapDuration: Double = 1.5

    static func segments(forDuration duration: Double) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        var segments: [ClosedRange<Double>] = []
        var start = 0.0
        while start < duration {
            let end = min(duration, start + maximumSegmentDuration)
            segments.append(start...end)
            guard end < duration else { break }
            start = max(start + 0.001, end - overlapDuration)
        }
        return segments
    }
}

enum SpeechInputTextMerger {
    static func append(_ accumulated: String, _ next: String) -> String {
        guard !accumulated.isEmpty else { return next }
        guard !next.isEmpty else { return accumulated }
        let limit = min(accumulated.count, next.count, 160)
        guard limit > 0 else { return accumulated + "\n" + next }
        for length in stride(from: limit, through: 1, by: -1) {
            if String(accumulated.suffix(length)).caseInsensitiveCompare(String(next.prefix(length))) == .orderedSame {
                return accumulated + next.dropFirst(length)
            }
        }
        return accumulated + "\n" + next
    }
}
