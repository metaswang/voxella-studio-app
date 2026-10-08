import Foundation

/// One embedding of a continuous, clean, single-speaker stretch of audio.
struct VoiceprintSegment: Codable, Equatable, Sendable {
    var vector: [Float]
    /// Effective speech seconds the vector was computed from.
    var duration: Double
}

/// Duration-weighted speaker embedding with its provenance.
struct SpeakerVoiceprint: Codable, Equatable, Sendable {
    enum Quality: String, Codable, Sendable {
        case ready
        /// Some segments disagree with the rest; possibly a different person mixed in.
        case needsReview
    }

    var vector: [Float]
    var effectiveDuration: Double
    var segmentCount: Int
    /// Lowest cosine between a segment and the centroid of the other segments.
    var consistency: Double
    var quality: Quality
    var version: String
}

enum SpeakerVoiceprintPolicy {
    /// Enrollment needs at least this much single-speaker speech.
    static let minimumEnrollmentDuration = 3.0
    /// Recommended enrollment range for reliable identification.
    static let recommendedEnrollmentDuration = 15.0...30.0
    /// Embedding window bounds. Shorter stretches give unreliable statistics;
    /// longer ones are split so one window cannot dominate the aggregate.
    static let minimumWindow = 1.0
    static let maximumWindow = 8.0
    /// Edge trim removes turn-boundary bleed from neighbouring speakers.
    static let edgeTrim = 0.1
    /// A segment below this cosine to the others marks the voiceprint for review.
    static let consistencyFloor = 0.5
    /// Caps embedding work per speaker channel.
    static let maximumEvidenceDuration = 120.0

    /// Splits clean ranges into embedding windows of 1–8 s, longest evidence first.
    static func windows(
        for ranges: [SpeechTimeRange],
        limit: Double = maximumEvidenceDuration
    ) -> [SpeechTimeRange] {
        var windows: [SpeechTimeRange] = []
        let trimmed = ranges.compactMap { range -> SpeechTimeRange? in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = range.start + edgeTrim
            let end = range.end - edgeTrim
            return end - start >= minimumWindow ? SpeechTimeRange(start: start, end: end) : nil
        }.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        var total = 0.0
        for range in trimmed {
            let duration = range.end - range.start
            let pieces = max(1, Int(ceil(duration / maximumWindow)))
            let length = duration / Double(pieces)
            for piece in 0..<pieces {
                guard total < limit else { return windows.sorted { $0.start < $1.start } }
                let start = range.start + Double(piece) * length
                windows.append(SpeechTimeRange(start: start, end: start + length))
                total += length
            }
        }
        return windows.sorted { $0.start < $1.start }
    }

    /// Duration-weighted mean of unit vectors; nil when no valid segment or the
    /// effective duration is below `minimumDuration`.
    static func aggregate(
        _ segments: [VoiceprintSegment],
        version: String,
        minimumDuration: Double = 0
    ) -> SpeakerVoiceprint? {
        let valid = segments.compactMap { segment -> VoiceprintSegment? in
            guard segment.duration.isFinite, segment.duration > 0,
                  let unit = normalized(segment.vector) else { return nil }
            return VoiceprintSegment(vector: unit, duration: segment.duration)
        }
        guard let dimension = valid.first?.vector.count,
              valid.allSatisfy({ $0.vector.count == dimension }) else { return nil }
        let total = valid.reduce(0) { $0 + $1.duration }
        guard total > 0, total >= minimumDuration else { return nil }
        guard let centroid = weightedCentroid(valid, dimension: dimension) else { return nil }

        var consistency = 1.0
        if valid.count > 1 {
            for index in valid.indices {
                var others = valid
                others.remove(at: index)
                guard let rest = weightedCentroid(others, dimension: dimension) else { continue }
                consistency = min(consistency, Double(cosine(valid[index].vector, rest)))
            }
        }
        return SpeakerVoiceprint(
            vector: centroid,
            effectiveDuration: total,
            segmentCount: valid.count,
            consistency: consistency,
            quality: consistency < consistencyFloor ? .needsReview : .ready,
            version: version
        )
    }

    private static func weightedCentroid(_ segments: [VoiceprintSegment], dimension: Int) -> [Float]? {
        var sum = [Float](repeating: 0, count: dimension)
        for segment in segments {
            let weight = Float(segment.duration)
            for index in 0..<dimension { sum[index] += segment.vector[index] * weight }
        }
        return normalized(sum)
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6 else { return nil }
        return vector.map { $0 / norm }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        let denominator = (left * right).squareRoot()
        guard denominator > 0, dot.isFinite else { return 0 }
        return dot / denominator
    }
}
