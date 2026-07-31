import Foundation

struct ASRSpeechRange: Equatable, Sendable {
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

struct ASRRecognitionChunk: Equatable, Sendable {
    let inputStart: Double
    let inputEnd: Double
    let ownershipStart: Double
    let ownershipEnd: Double

    var inputDuration: Double { inputEnd - inputStart }
}

struct ASRChunkPlannerConfiguration: Equatable, Sendable {
    let maximumWindowDuration: Double
    let boundaryContextDuration: Double
    let maximumMergeGap: Double
}

enum ASRChunkPlanner {
    static func chunks(
        speechRanges: [ASRSpeechRange],
        audioDuration: Double,
        configuration: ASRChunkPlannerConfiguration
    ) -> [ASRRecognitionChunk] {
        guard audioDuration.isFinite, audioDuration > 0,
              configuration.maximumWindowDuration.isFinite,
              configuration.maximumWindowDuration > 0,
              configuration.boundaryContextDuration.isFinite,
              configuration.boundaryContextDuration >= 0,
              configuration.maximumMergeGap.isFinite,
              configuration.maximumMergeGap >= 0 else { return [] }

        let normalized = speechRanges.compactMap { range -> ASRSpeechRange? in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = min(audioDuration, max(0, range.start))
            let end = min(audioDuration, max(start, range.end))
            return end > start ? ASRSpeechRange(start: start, end: end) : nil
        }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard !normalized.isEmpty else { return [] }

        let split = normalized.flatMap {
            splitRange($0, maximumDuration: configuration.maximumWindowDuration)
        }
        var ownershipRanges: [ASRSpeechRange] = []
        for range in split {
            guard let last = ownershipRanges.last else {
                ownershipRanges.append(range)
                continue
            }
            let gap = max(0, range.start - last.end)
            let combinedDuration = max(last.end, range.end) - last.start
            if gap <= configuration.maximumMergeGap,
               combinedDuration <= configuration.maximumWindowDuration {
                ownershipRanges[ownershipRanges.count - 1] = ASRSpeechRange(
                    start: last.start,
                    end: max(last.end, range.end)
                )
            } else {
                ownershipRanges.append(range)
            }
        }

        return ownershipRanges.map { ownership in
            ASRRecognitionChunk(
                inputStart: max(0, ownership.start - configuration.boundaryContextDuration),
                inputEnd: min(audioDuration, ownership.end + configuration.boundaryContextDuration),
                ownershipStart: ownership.start,
                ownershipEnd: ownership.end
            )
        }
    }

    private static func splitRange(
        _ range: ASRSpeechRange,
        maximumDuration: Double
    ) -> [ASRSpeechRange] {
        guard range.duration > maximumDuration else { return [range] }
        var result: [ASRSpeechRange] = []
        var start = range.start
        while start < range.end {
            let end = min(range.end, start + maximumDuration)
            result.append(.init(start: start, end: end))
            start = end
        }
        return result
    }
}
