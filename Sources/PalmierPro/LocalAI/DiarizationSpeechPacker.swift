import Foundation

struct SortformerStreamingParameters: Equatable, Sendable {
    var chunkDuration: Double
    var frameDuration: Double
    var spkcacheMax: Int
    var fifoMax: Int

    static func from(
        hopLength: Int,
        subsamplingFactor: Int,
        samplingRate: Int,
        chunkLen: Int,
        spkcacheLen: Int,
        fifoLen: Int
    ) -> Self {
        let safeRate = max(1, samplingRate)
        let frameDuration = Double(max(0, hopLength) * max(1, subsamplingFactor)) / Double(safeRate)
        return Self(
            chunkDuration: Double(max(1, chunkLen)) * frameDuration,
            frameDuration: frameDuration,
            spkcacheMax: max(0, spkcacheLen),
            fifoMax: max(0, fifoLen)
        )
    }
}

struct DiarizationSpeechMapping: Equatable, Sendable {
    let concatStart: Double
    let concatEnd: Double
    let originalStart: Double
    let originalEnd: Double

    func originalTime(for concatTime: Double) -> Double? {
        let span = concatEnd - concatStart
        guard span > 0 else { return nil }
        if concatTime >= concatStart, concatTime < concatEnd {
            return originalStart + (concatTime - concatStart)
        }
        if concatTime == concatEnd || abs(concatTime - concatEnd) < 1e-9 {
            return originalEnd
        }
        return nil
    }
}

struct DiarizationSpeechPack: Equatable, Sendable {
    let samples: [Float]
    let mappings: [DiarizationSpeechMapping]
    let speechDuration: Double
    let processedAudioDuration: Double
    let coverage: Double
    let usedIdentity: Bool

    func originalTime(for concatTime: Double) -> Double? {
        guard concatTime.isFinite else { return nil }
        for mapping in mappings {
            if let original = mapping.originalTime(for: concatTime) {
                return original
            }
        }
        return nil
    }
}

enum DiarizationSpeechPacker {
    static let mergeGap = 1.5
    static let interWindowPad = 0.6
    static let identityCoverageThreshold = 0.98

    static func pack(
        audio: [Float],
        sampleRate: Int,
        speechRanges: [SpeechTimeRange],
        audioDuration: Double
    ) -> DiarizationSpeechPack {
        let safeRate = max(1, sampleRate)
        let duration = audioDuration.isFinite && audioDuration > 0
            ? audioDuration
            : Double(audio.count) / Double(safeRate)
        let windows = mergedWindows(
            speechRanges: speechRanges,
            audioDuration: duration
        )
        let speechDuration = windows.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let coverage = duration > 0 ? min(1, max(0, speechDuration / duration)) : 0

        if windows.isEmpty || coverage >= identityCoverageThreshold {
            return identityPack(
                audio: audio,
                duration: duration,
                speechDuration: speechDuration,
                coverage: coverage
            )
        }

        let padSampleCount = max(0, Int((interWindowPad * Double(safeRate)).rounded()))
        let padDuration = Double(padSampleCount) / Double(safeRate)
        var packed: [Float] = []
        var mappings: [DiarizationSpeechMapping] = []
        packed.reserveCapacity(min(audio.count, Int((speechDuration * Double(safeRate)).rounded(.up)) + padSampleCount * max(0, windows.count - 1)))

        var concatCursor = 0.0
        for (index, window) in windows.enumerated() {
            if index > 0, padSampleCount > 0 {
                packed.append(contentsOf: repeatElement(0, count: padSampleCount))
                concatCursor += padDuration
            }
            let range = sampleRange(
                start: window.start,
                end: window.end,
                sampleRate: safeRate,
                sampleCount: audio.count
            )
            packed.append(contentsOf: audio[range])
            let extractedDuration = Double(range.count) / Double(safeRate)
            let concatEnd = concatCursor + extractedDuration
            mappings.append(DiarizationSpeechMapping(
                concatStart: concatCursor,
                concatEnd: concatEnd,
                originalStart: window.start,
                originalEnd: window.start + extractedDuration
            ))
            concatCursor = concatEnd
        }

        let processed = Double(packed.count) / Double(safeRate)
        return DiarizationSpeechPack(
            samples: packed,
            mappings: mappings,
            speechDuration: speechDuration,
            processedAudioDuration: processed,
            coverage: coverage,
            usedIdentity: false
        )
    }

    static func scatterProbabilities(
        concatProbabilities: [Float],
        speakerCapacity: Int,
        frameDuration: Double,
        pack: DiarizationSpeechPack,
        audioDuration: Double
    ) -> [Float] {
        guard speakerCapacity > 0, frameDuration > 0, audioDuration > 0 else { return [] }
        if pack.usedIdentity {
            return concatProbabilities
        }

        let originalFrameCount = max(0, Int((audioDuration / frameDuration).rounded(.up)))
        var scattered = [Float](repeating: 0, count: originalFrameCount * speakerCapacity)
        let concatFrameCount = concatProbabilities.count / speakerCapacity
        guard concatFrameCount > 0 else { return scattered }

        var mappingIndex = 0
        for concatFrame in 0..<concatFrameCount {
            let concatTime = (Double(concatFrame) + 0.5) * frameDuration
            while mappingIndex < pack.mappings.count,
                  pack.mappings[mappingIndex].concatEnd <= concatTime {
                mappingIndex += 1
            }
            guard mappingIndex < pack.mappings.count,
                  let originalTime = pack.mappings[mappingIndex].originalTime(for: concatTime) else {
                continue
            }
            let originalFrame = Int(floor(originalTime / frameDuration))
            guard originalFrame >= 0, originalFrame < originalFrameCount else { continue }
            let source = concatFrame * speakerCapacity
            let destination = originalFrame * speakerCapacity
            for speaker in 0..<speakerCapacity {
                scattered[destination + speaker] = concatProbabilities[source + speaker]
            }
        }
        return scattered
    }

    static func mergedWindows(
        speechRanges: [SpeechTimeRange],
        audioDuration: Double
    ) -> [SpeechTimeRange] {
        guard audioDuration.isFinite, audioDuration > 0 else { return [] }
        let normalized = speechRanges.compactMap { range -> SpeechTimeRange? in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = min(audioDuration, max(0, range.start))
            let end = min(audioDuration, max(start, range.end))
            return end > start ? SpeechTimeRange(start: start, end: end) : nil
        }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard !normalized.isEmpty else { return [] }

        var merged: [SpeechTimeRange] = []
        for range in normalized {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            let gap = range.start - last.end
            if gap <= mergeGap {
                merged[merged.count - 1] = SpeechTimeRange(
                    start: last.start,
                    end: max(last.end, range.end)
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func identityPack(
        audio: [Float],
        duration: Double,
        speechDuration: Double,
        coverage: Double
    ) -> DiarizationSpeechPack {
        let mapping = duration > 0
            ? [DiarizationSpeechMapping(
                concatStart: 0,
                concatEnd: duration,
                originalStart: 0,
                originalEnd: duration
            )]
            : []
        return DiarizationSpeechPack(
            samples: audio,
            mappings: mapping,
            speechDuration: speechDuration,
            processedAudioDuration: duration,
            coverage: coverage,
            usedIdentity: true
        )
    }

    private static func sampleRange(
        start: Double,
        end: Double,
        sampleRate: Int,
        sampleCount: Int
    ) -> Range<Int> {
        let startIndex = max(0, Int((start * Double(sampleRate)).rounded(.down)))
        let endIndex = min(sampleCount, max(startIndex, Int((end * Double(sampleRate)).rounded(.up))))
        return startIndex..<endIndex
    }
}
