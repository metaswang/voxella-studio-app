import Foundation

struct ASRSpeechPreparationPolicy: Equatable, Sendable {
    var frameSize = 512
    var entryThreshold: Float = 0.50
    var exitThreshold: Float = 0.35
    var excludedThreshold: Float = 0.10
    var excludedFrameCount = 24
    var exitFrameCount = 10
    var protectionBeforeActivityFrameCount = 8
    var protectionAfterActivityFrameCount = 12

    static let standard = ASRSpeechPreparationPolicy()
}

struct ASRSpeechPreparationResult: Equatable, Sendable {
    var recognitionRanges: [ASRSpeechRange]
    var confidentSpeechRanges: [ASRSpeechRange]
    var excludedRanges: [ASRSpeechRange]

    var hasPotentialSpeech: Bool { !recognitionRanges.isEmpty }
}

enum ASRSpeechPreparation {
    static func make(
        sampleCount: Int,
        originalProbabilities: [Float],
        rescuedProbabilities: [Float]? = nil,
        sampleRate: Int = ASRAudioPreprocessor.sampleRate,
        policy: ASRSpeechPreparationPolicy = .standard
    ) -> ASRSpeechPreparationResult {
        guard sampleCount > 0, sampleRate > 0, policy.frameSize > 0,
              policy.entryThreshold.isFinite, policy.exitThreshold.isFinite,
              policy.excludedThreshold.isFinite,
              (0...1).contains(policy.excludedThreshold),
              policy.excludedThreshold <= policy.exitThreshold,
              policy.exitThreshold <= policy.entryThreshold,
              policy.entryThreshold <= 1,
              policy.excludedFrameCount > 0, policy.exitFrameCount > 0,
              policy.protectionBeforeActivityFrameCount >= 0,
              policy.protectionAfterActivityFrameCount >= 0 else {
            return .init(recognitionRanges: [], confidentSpeechRanges: [], excludedRanges: [])
        }
        let frameCount = ((sampleCount - 1) / policy.frameSize) + 1
        let probabilities = (0..<frameCount).map { index -> Float in
            let original = originalProbabilities.indices.contains(index) ? originalProbabilities[index] : policy.exitThreshold
            let rescued: Float
            if let rescuedProbabilities, rescuedProbabilities.indices.contains(index) {
                rescued = rescuedProbabilities[index]
            } else {
                rescued = original
            }
            return max(original.isFinite ? original : policy.exitThreshold,
                       rescued.isFinite ? rescued : policy.exitThreshold)
        }

        let confident = SpeechProbabilitySegmenter.sampleRanges(
            probabilities: probabilities,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            frameSize: policy.frameSize,
            entryThreshold: policy.entryThreshold,
            exitThreshold: policy.exitThreshold,
            minimumSpeechDuration: 0,
            minimumSilenceDuration: Double(policy.exitFrameCount * policy.frameSize) / Double(sampleRate),
            padding: 0
        )

        guard probabilities.contains(where: { $0 > policy.excludedThreshold }) else {
            return .init(recognitionRanges: [], confidentSpeechRanges: confident, excludedRanges: [
                ASRSpeechRange(start: 0, end: Double(sampleCount) / Double(sampleRate)),
            ])
        }

        var excludedFrames = [Bool](repeating: false, count: frameCount)
        var runStart: Int?
        for index in 0...frameCount {
            let isLow = index < frameCount && probabilities[index] <= policy.excludedThreshold
            if isLow {
                runStart = runStart ?? index
            } else if let start = runStart {
                let runEnd = index
                if runEnd - start >= policy.excludedFrameCount {
                    let excludedStart = start == 0
                        ? start
                        : min(runEnd, start + policy.protectionAfterActivityFrameCount)
                    let excludedEnd = runEnd == frameCount
                        ? runEnd
                        : max(excludedStart, runEnd - policy.protectionBeforeActivityFrameCount)
                    if excludedStart < excludedEnd {
                        for frame in excludedStart..<excludedEnd { excludedFrames[frame] = true }
                    }
                }
                runStart = nil
            }
        }

        let excluded = ranges(
            matching: true,
            flags: excludedFrames,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            frameSize: policy.frameSize
        )
        let recognition = ranges(
            matching: false,
            flags: excludedFrames,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            frameSize: policy.frameSize
        )
        return .init(
            recognitionRanges: recognition,
            confidentSpeechRanges: confident,
            excludedRanges: excluded
        )
    }

    private static func ranges(
        matching value: Bool,
        flags: [Bool],
        sampleCount: Int,
        sampleRate: Int,
        frameSize: Int
    ) -> [ASRSpeechRange] {
        var result: [ASRSpeechRange] = []
        var start: Int?
        for index in 0...flags.count {
            let matches = index < flags.count && flags[index] == value
            if matches {
                start = start ?? index
            } else if let first = start {
                let startSample = min(sampleCount, first * frameSize)
                let endSample = min(sampleCount, index * frameSize)
                if endSample > startSample {
                    result.append(.init(
                        start: Double(startSample) / Double(sampleRate),
                        end: Double(endSample) / Double(sampleRate)
                    ))
                }
                start = nil
            }
        }
        return result
    }
}

enum SpeechProbabilitySegmenter {
    static func sampleRanges(
        probabilities: [Float],
        sampleCount: Int,
        sampleRate: Int,
        frameSize: Int,
        entryThreshold: Float,
        exitThreshold: Float,
        minimumSpeechDuration: Double,
        minimumSilenceDuration: Double,
        padding: Double
    ) -> [ASRSpeechRange] {
        guard sampleCount > 0, sampleRate > 0, frameSize > 0 else { return [] }
        let minimumSpeechFrames = max(1, Int((minimumSpeechDuration * Double(sampleRate) / Double(frameSize)).rounded(.up)))
        let minimumSilenceFrames = max(1, Int((minimumSilenceDuration * Double(sampleRate) / Double(frameSize)).rounded(.up)))
        let paddingSamples = max(0, Int((padding * Double(sampleRate)).rounded()))
        var raw: [Range<Int>] = []
        var speechStart: Int?
        var silenceStart: Int?

        for (index, probability) in probabilities.enumerated() {
            if speechStart == nil, probability >= entryThreshold {
                speechStart = index
                silenceStart = nil
            } else if speechStart != nil {
                if probability >= entryThreshold {
                    silenceStart = nil
                } else if probability < exitThreshold {
                    silenceStart = silenceStart ?? index
                    if let pendingEnd = silenceStart, index - pendingEnd + 1 >= minimumSilenceFrames {
                        if pendingEnd - speechStart! >= minimumSpeechFrames {
                            raw.append(speechStart!..<pendingEnd)
                        }
                        speechStart = nil
                        silenceStart = nil
                    }
                }
            }
        }
        if let speechStart, probabilities.count - speechStart >= minimumSpeechFrames {
            raw.append(speechStart..<probabilities.count)
        }

        var padded: [ASRSpeechRange] = []
        for frames in raw {
            let startSample = max(0, frames.lowerBound * frameSize - paddingSamples)
            let endSample = min(sampleCount, frames.upperBound * frameSize + paddingSamples)
            guard endSample > startSample else { continue }
            let range = ASRSpeechRange(
                start: Double(startSample) / Double(sampleRate),
                end: Double(endSample) / Double(sampleRate)
            )
            if let last = padded.last, range.start <= last.end {
                padded[padded.count - 1] = .init(start: last.start, end: max(last.end, range.end))
            } else {
                padded.append(range)
            }
        }
        return padded
    }
}
