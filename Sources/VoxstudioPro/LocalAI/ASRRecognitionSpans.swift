import Foundation

/// Builds alignment spans for one Palmier recognition chunk.
///
/// Whisper timestamps, when trusted, assign a whole segment to one ownership
/// window. They never split characters and never become forced-alignment bounds.
enum ASRRecognitionSpans {
    struct Segment: Equatable, Sendable {
        var text: String
        var start: Double?
        var end: Double?
    }

    struct Result: Equatable, Sendable {
        var spans: [RecognizedSpan]
        var timestampFallbackCount: Int
    }

    private static let timestampSlack = 0.05
    private static let compressedCoverageRatio = 0.15

    static func segments(from raw: [[String: Any]]?) -> [Segment] {
        (raw ?? []).compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Segment(
                text: trimmed,
                start: numericValue(item["start"]),
                end: numericValue(item["end"])
            )
        }
    }

    static func ownedChunkSpan(
        segmentTexts: [String],
        fallbackText: String,
        recognitionStart: Double,
        recognitionEnd: Double,
        ownershipStart: Double,
        ownershipEnd: Double,
        audioDuration: Double
    ) -> [RecognizedSpan] {
        ownedChunk(
            segments: segmentTexts.map { Segment(text: $0, start: nil, end: nil) },
            fallbackText: fallbackText,
            recognitionStart: recognitionStart,
            recognitionEnd: recognitionEnd,
            ownershipStart: ownershipStart,
            ownershipEnd: ownershipEnd,
            audioDuration: audioDuration
        ).spans
    }

    static func ownedChunk(
        segments: [Segment],
        fallbackText: String,
        recognitionStart: Double,
        recognitionEnd: Double,
        ownershipStart: Double,
        ownershipEnd: Double,
        audioDuration: Double
    ) -> Result {
        let inputStart = min(audioDuration, max(0, recognitionStart))
        let inputEnd = min(audioDuration, max(inputStart, recognitionEnd))
        let ownedStart = min(audioDuration, max(0, ownershipStart))
        let ownedEnd = min(audioDuration, max(ownedStart, ownershipEnd))
        guard inputEnd > inputStart, ownedEnd > ownedStart else {
            return Result(spans: [], timestampFallbackCount: 0)
        }

        let parsed = segments.compactMap { segment -> Segment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(text: text, start: segment.start, end: segment.end)
        }
        let joined = parsed.map(\.text).joined(separator: " ")
        let fallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [Segment]
        let usedFallback: Bool
        if compactCount(joined) == 0 {
            guard !fallback.isEmpty else { return Result(spans: [], timestampFallbackCount: 0) }
            source = [Segment(text: fallback, start: nil, end: nil)]
            usedFallback = true
        } else if compactCount(fallback) > compactCount(joined) {
            source = [Segment(text: fallback, start: nil, end: nil)]
            usedFallback = true
        } else {
            source = parsed
            usedFallback = false
        }

        let ownedText: String
        let timestampFallbackCount: Int
        if usedFallback || !timestampsTrusted(source, inputStart: inputStart, inputEnd: inputEnd) {
            ownedText = source.map(\.text).joined(separator: " ")
            timestampFallbackCount = 1
        } else {
            let kept = source.filter { segment in
                belongsToOwnership(
                    segment,
                    inputStart: inputStart,
                    ownershipStart: ownedStart,
                    ownershipEnd: ownedEnd,
                    audioDuration: audioDuration
                )
            }
            ownedText = kept.map(\.text).joined(separator: " ")
            timestampFallbackCount = 0
        }

        let trimmed = ownedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(spans: [], timestampFallbackCount: timestampFallbackCount)
        }
        return Result(
            spans: [
                RecognizedSpan(
                    text: trimmed,
                    startTime: ownedStart,
                    endTime: ownedEnd,
                    inputStart: inputStart,
                    inputEnd: inputEnd
                )
            ],
            timestampFallbackCount: timestampFallbackCount
        )
    }

    private static func timestampsTrusted(
        _ segments: [Segment],
        inputStart: Double,
        inputEnd: Double
    ) -> Bool {
        guard !segments.isEmpty else { return false }
        var previousStart = -Double.infinity
        var earliest = Double.infinity
        var latest = -Double.infinity
        for segment in segments {
            guard let start = segment.start, let end = segment.end,
                  start.isFinite, end.isFinite, end > start else { return false }
            let absoluteStart = inputStart + start
            let absoluteEnd = inputStart + end
            guard absoluteStart >= inputStart - timestampSlack,
                  absoluteEnd <= inputEnd + timestampSlack else { return false }
            guard start + timestampSlack >= previousStart else { return false }
            previousStart = start
            earliest = min(earliest, absoluteStart)
            latest = max(latest, absoluteEnd)
        }
        let covered = latest - earliest
        let inputDuration = inputEnd - inputStart
        if covered < min(0.5, inputDuration * compressedCoverageRatio) {
            return false
        }
        return true
    }

    private static func belongsToOwnership(
        _ segment: Segment,
        inputStart: Double,
        ownershipStart: Double,
        ownershipEnd: Double,
        audioDuration: Double
    ) -> Bool {
        guard let start = segment.start, let end = segment.end else { return true }
        let midpoint = inputStart + ((start + end) / 2)
        if midpoint >= ownershipStart, midpoint < ownershipEnd { return true }
        return abs(ownershipEnd - audioDuration) <= 1e-9
            && abs(midpoint - ownershipEnd) <= 1e-9
    }

    private static func compactCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value.isFinite ? value : nil
        case let value as Float:
            return value.isFinite ? Double(value) : nil
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            let number = value.doubleValue
            return number.isFinite ? number : nil
        default:
            return nil
        }
    }
}
