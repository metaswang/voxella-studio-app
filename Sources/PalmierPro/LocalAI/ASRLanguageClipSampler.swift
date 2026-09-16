import Foundation

struct ASRLanguageClipSamplingPolicy: Equatable, Sendable {
    var candidateDuration = 10.0
    var minimumAcceptedDuration = ASREngineRouter.targetIdentificationWindowDuration
    var maximumAcceptedDuration = ASREngineRouter.maximumIdentificationWindowDuration
    var attemptsPerSlot = 3

    static let standard = ASRLanguageClipSamplingPolicy()

    var isValid: Bool {
        candidateDuration.isFinite && candidateDuration > 0
            && minimumAcceptedDuration.isFinite && minimumAcceptedDuration > 0
            && maximumAcceptedDuration.isFinite && maximumAcceptedDuration >= minimumAcceptedDuration
            && candidateDuration >= maximumAcceptedDuration
            && attemptsPerSlot > 0 && attemptsPerSlot <= 16
    }
}

struct ASRLanguageClipSamplingResult: Equatable, Sendable {
    let windows: [ASRLanguageIdentificationWindow]
    let targetCount: Int
    let attemptedCount: Int

    var isComplete: Bool { targetCount > 0 && windows.count == targetCount }
}

enum ASRLanguageClipSampler {
    static func windows(
        samples: [Float],
        sampleRate: Int = ASRAudioPreprocessor.sampleRate,
        policy: ASRLanguageClipSamplingPolicy = .standard
    ) -> ASRLanguageClipSamplingResult {
        guard policy.isValid, sampleRate > 0, !samples.isEmpty else {
            return .init(windows: [], targetCount: 0, attemptedCount: 0)
        }
        let rate = Double(sampleRate)
        let audioDuration = Double(samples.count) / rate
        guard audioDuration.isFinite, audioDuration > 0 else {
            return .init(windows: [], targetCount: 0, attemptedCount: 0)
        }
        let preferredCount = audioDuration >= ASREngineRouter.longFormAudioDuration
            ? ASREngineRouter.longFormIdentificationWindowCount
            : ASREngineRouter.standardIdentificationWindowCount
        let availableCountValue = (audioDuration / policy.minimumAcceptedDuration).rounded(.down)
        let availableCount = availableCountValue >= Double(Int.max)
            ? Int.max
            : max(1, Int(availableCountValue))
        let targetCount = min(preferredCount, availableCount)
        func sampleCount(for duration: Double, roundingRule: FloatingPointRoundingRule) -> Int {
            let scaled = duration * rate
            guard scaled.isFinite, scaled < Double(Int.max) else { return samples.count }
            return min(samples.count, max(0, Int(scaled.rounded(roundingRule))))
        }
        let candidateSampleCount = min(
            samples.count,
            max(1, sampleCount(for: policy.candidateDuration, roundingRule: .up))
        )
        let maximumOrigin = samples.count - candidateSampleCount
        let gridCount = targetCount == 1 ? 1 : (targetCount - 1) * policy.attemptsPerSlot + 1
        let minimumAcceptedDuration = audioDuration < policy.minimumAcceptedDuration
            ? min(audioDuration, AudioBoundarySilenceTrimmer.minimumAudibleDuration)
            : policy.minimumAcceptedDuration
        let minimumAcceptedSamples = min(
            samples.count,
            max(1, sampleCount(
                for: minimumAcceptedDuration,
                roundingRule: .down
            ))
        )
        let maximumAcceptedSamples = max(
            minimumAcceptedSamples,
            sampleCount(
                for: min(policy.maximumAcceptedDuration, audioDuration),
                roundingRule: .down
            )
        )
        let paddingSamples = sampleCount(
            for: AudioBoundarySilenceTrimmer.boundaryPadding,
            roundingRule: .toNearestOrAwayFromZero
        )
        var accepted: [Range<Int>] = []
        var attemptedCount = 0
        var visited = Set<Int>()

        func acceptCandidate(at gridIndex: Int) -> Bool {
            guard gridIndex >= 0, gridIndex < gridCount, visited.insert(gridIndex).inserted else {
                return false
            }
            let origin: Int
            if gridCount == 1 {
                origin = 0
            } else {
                let divisor = gridCount - 1
                let quotient = maximumOrigin / divisor
                let remainder = maximumOrigin % divisor
                origin = quotient * gridIndex
                    + (remainder * gridIndex + divisor / 2) / divisor
            }
            let candidate = origin..<(origin + candidateSampleCount)
            attemptedCount += 1
            let clip = Array(samples[candidate])
            guard let audible = AudioBoundarySilenceTrimmer.audibleSpan(samples: clip, sampleRate: rate) else {
                return false
            }
            var lower = candidate.lowerBound + max(0, audible.lowerBound - paddingSamples)
            let audibleEnd = candidate.lowerBound + audible.upperBound
            let upper = audibleEnd + min(paddingSamples, candidate.upperBound - audibleEnd)
            guard upper - lower >= minimumAcceptedSamples else { return false }
            if upper - lower > maximumAcceptedSamples {
                if candidate.upperBound == samples.count {
                    lower = upper - maximumAcceptedSamples
                } else if candidate.lowerBound != 0 {
                    lower += (upper - lower - maximumAcceptedSamples) / 2
                }
            }
            let proposed = lower..<min(upper, lower + maximumAcceptedSamples)
            guard !accepted.contains(where: { $0.overlaps(proposed) }) else { return false }
            accepted.append(proposed)
            return true
        }

        for slot in 0..<targetCount where accepted.count < targetCount {
            let base = targetCount == 1 ? 0 : slot * policy.attemptsPerSlot
            var candidateIndices = [base]
            if targetCount > 1 {
                if slot == 0 {
                    candidateIndices += (1..<policy.attemptsPerSlot).map { base + $0 }
                } else if slot == targetCount - 1 {
                    candidateIndices += (1..<policy.attemptsPerSlot).map { base - $0 }
                } else {
                    candidateIndices += (1..<policy.attemptsPerSlot).map { attempt in
                        let distance = (attempt + 1) / 2
                        return attempt.isMultiple(of: 2) ? base + distance : base - distance
                    }
                }
            }
            for gridIndex in candidateIndices {
                if acceptCandidate(at: gridIndex) { break }
            }
        }
        if accepted.count < targetCount {
            for gridIndex in 0..<gridCount where accepted.count < targetCount {
                _ = acceptCandidate(at: gridIndex)
            }
        }

        let windows = accepted.sorted { $0.lowerBound < $1.lowerBound }.map { range in
            ASRLanguageIdentificationWindow(slices: [ASRSpeechRange(
                start: Double(range.lowerBound) / rate,
                end: Double(range.upperBound) / rate
            )])
        }
        return .init(windows: windows, targetCount: targetCount, attemptedCount: attemptedCount)
    }
}
