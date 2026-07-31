import Foundation

struct KnownTextAlignmentSpan: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String?

    init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

enum KnownTextSpeakerAttribution: Sendable {
    case providedSpans
    case diarize(requestedSpeakerCount: Int?)
    case none
}

struct KnownTextAlignmentRequest: Sendable {
    var text: String
    var languageCode: String?
    var spans: [KnownTextAlignmentSpan]
    var anchor: TranscriptionResult?
    var speakerAttribution: KnownTextSpeakerAttribution

    init(
        text: String,
        languageCode: String?,
        spans: [KnownTextAlignmentSpan] = [],
        anchor: TranscriptionResult? = nil,
        speakerAttribution: KnownTextSpeakerAttribution = .none
    ) {
        self.text = text
        self.languageCode = languageCode
        self.spans = spans
        self.anchor = anchor
        self.speakerAttribution = speakerAttribution
    }
}

struct KnownTextAlignmentDiagnostics: Codable, Equatable, Sendable {
    var alignedUnitCount: Int
    var estimatedUnitCount: Int

    var usedEstimatedTiming: Bool { estimatedUnitCount > 0 }
}

struct KnownTextAlignmentOutput: Sendable {
    var result: TranscriptionResult
    var diagnostics: KnownTextAlignmentDiagnostics
}

enum KnownTextSpeakerMapper {
    static func assign(
        words: [TranscriptionWord],
        spans: [KnownTextAlignmentSpan]
    ) -> [TranscriptionWord] {
        let validSpans = spans.enumerated().compactMap { index, span -> (Int, KnownTextAlignmentSpan)? in
            guard span.start.isFinite, span.end.isFinite, span.end > span.start else { return nil }
            return (index, span)
        }
        guard !validSpans.isEmpty else { return words }

        return words.map { word in
            guard let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, end >= start else { return word }
            let midpoint = (start + end) / 2
            let best = validSpans.max { lhs, rhs in
                let lhsRank = rank(span: lhs.1, index: lhs.0, start: start, end: end, midpoint: midpoint)
                let rhsRank = rank(span: rhs.1, index: rhs.0, start: start, end: end, midpoint: midpoint)
                if lhsRank.overlap != rhsRank.overlap { return lhsRank.overlap < rhsRank.overlap }
                if lhsRank.distance != rhsRank.distance { return lhsRank.distance > rhsRank.distance }
                return lhsRank.index > rhsRank.index
            }?.1
            return TranscriptionWord(
                text: word.text,
                start: start,
                end: end,
                speaker: best?.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }
    }

    private static func rank(
        span: KnownTextAlignmentSpan,
        index: Int,
        start: Double,
        end: Double,
        midpoint: Double
    ) -> (overlap: Double, distance: Double, index: Int) {
        let overlap = max(0, min(end, span.end) - max(start, span.start))
        let distance = abs(midpoint - (span.start + span.end) / 2)
        return (overlap, distance, index)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
