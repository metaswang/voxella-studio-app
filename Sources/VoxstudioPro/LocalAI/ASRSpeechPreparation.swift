import Foundation

struct ASRSpeechPreparationPolicy: Equatable, Sendable {
    var frameSize = LocalSpeechVAD.chunkSize
    var entryThreshold: Float = 0.50
    var exitThreshold: Float = 0.35
    var exitFrameCount = 1

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
              policy.exitThreshold <= policy.entryThreshold,
              policy.entryThreshold <= 1,
              policy.exitFrameCount > 0 else {
            return .init(recognitionRanges: [], confidentSpeechRanges: [], excludedRanges: [])
        }
        let frameCount = ((sampleCount - 1) / policy.frameSize) + 1
        let probabilities = (0..<frameCount).map { index -> Float in
            let original = originalProbabilities.indices.contains(index)
                ? originalProbabilities[index]
                : policy.exitThreshold
            return original.isFinite ? original : policy.exitThreshold
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

        _ = rescuedProbabilities
        var acceptedFrames = [Bool](repeating: false, count: frameCount)
        for range in confident {
            let first = max(0, Int((range.start * Double(sampleRate) / Double(policy.frameSize)).rounded(.down)))
            let last = min(
                frameCount - 1,
                max(first, Int((range.end * Double(sampleRate) / Double(policy.frameSize)).rounded(.up)) - 1)
            )
            guard first <= last else { continue }
            for index in first...last { acceptedFrames[index] = true }
        }

        let excluded = ranges(
            matching: false,
            flags: acceptedFrames,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            frameSize: policy.frameSize
        )
        let recognition = ranges(
            matching: true,
            flags: acceptedFrames,
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
