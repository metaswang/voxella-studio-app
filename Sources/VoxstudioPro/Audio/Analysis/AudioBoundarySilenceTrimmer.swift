import Foundation

enum AudioBoundarySilenceTrimmer {
    static let analysisWindowDuration = 0.02
    static let minimumAudibleDuration = 0.06
    static let boundaryPadding = 0.1
    static let quietFlatPeak: Float = 0.05
    static let minimumQuietDynamicRange: Float = 2.5

    static func trim(
        samples: [Float],
        sampleRate: Double,
        padding: Double = boundaryPadding
    ) -> [Float] {
        guard sampleRate.isFinite,
              sampleRate > 0,
              padding.isFinite,
              padding >= 0,
              sampleRate <= Double(Int.max) / analysisWindowDuration,
              padding <= Double(Int.max) / sampleRate,
              let span = audibleSpan(samples: samples, sampleRate: sampleRate) else {
            return samples
        }
        let paddingFrames = max(0, Int((padding * sampleRate).rounded()))
        let start = max(0, span.lowerBound - paddingFrames)
        let paddedEnd = span.upperBound.addingReportingOverflow(paddingFrames)
        let end = min(samples.count, paddedEnd.overflow ? samples.count : paddedEnd.partialValue)
        guard start < end else { return samples }
        return Array(samples[start..<end])
    }

    static func hasAudibleSpeech(samples: [Float], sampleRate: Double) -> Bool {
        audibleSpan(samples: samples, sampleRate: sampleRate) != nil
    }

    static func tighten(
        samples: [Float],
        sampleRate: Double,
        candidate: Range<Int>,
        padding: Double = boundaryPadding
    ) -> Range<Int>? {
        guard sampleRate.isFinite,
              sampleRate > 0,
              padding.isFinite,
              padding >= 0,
              candidate.lowerBound >= 0,
              candidate.upperBound <= samples.count,
              candidate.lowerBound < candidate.upperBound,
              sampleRate <= Double(Int.max) / analysisWindowDuration,
              padding <= Double(Int.max) / sampleRate else {
            return nil
        }
        let slice = Array(samples[candidate])
        guard let audible = audibleSpan(samples: slice, sampleRate: sampleRate) else {
            return nil
        }
        var start = candidate.lowerBound + audible.lowerBound
        var end = candidate.lowerBound + audible.upperBound
        let paddingFrames = max(0, Int((padding * sampleRate).rounded()))
        start = max(0, start - paddingFrames)
        let paddedEnd = end.addingReportingOverflow(paddingFrames)
        end = min(samples.count, paddedEnd.overflow ? samples.count : paddedEnd.partialValue)
        return start < end ? start..<end : nil
    }

    static func audibleSpan(
        samples: [Float],
        sampleRate: Double
    ) -> Range<Int>? {
        guard !samples.isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= Double(Int.max) / analysisWindowDuration else {
            return nil
        }
        let windowSize = max(1, Int((sampleRate * analysisWindowDuration).rounded()))
        let windowCount = samples.count / windowSize
            + (samples.count % windowSize == 0 ? 0 : 1)
        var levels: [Float] = []
        levels.reserveCapacity(windowCount)
        var cursor = 0
        while cursor < samples.count {
            let end = cursor + min(windowSize, samples.count - cursor)
            var sum: Float = 0
            for sample in samples[cursor..<end] {
                let finiteSample = sample.isFinite ? sample : 0
                sum += finiteSample * finiteSample
            }
            levels.append(sqrt(sum / Float(max(1, end - cursor))))
            cursor = end
        }

        let sorted = levels.sorted()
        guard let peakLevel = sorted.last, peakLevel >= 0.006 else { return nil }
        let floorIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.1))
        let noiseFloor = max(sorted[floorIndex], 0.0001)
        if peakLevel < quietFlatPeak,
           peakLevel / noiseFloor < minimumQuietDynamicRange {
            return nil
        }
        let threshold = max(0.003, min(noiseFloor * 3, peakLevel * 0.35))
        let requiredWindows = max(1, Int((minimumAudibleDuration / analysisWindowDuration).rounded(.up)))

        var spans: [Range<Int>] = []
        var runStart: Int?
        for index in levels.indices {
            if levels[index] >= threshold {
                runStart = runStart ?? index
            } else if let start = runStart {
                if index - start >= requiredWindows {
                    spans.append(start..<index)
                }
                runStart = nil
            }
        }
        if let start = runStart, levels.count - start >= requiredWindows {
            spans.append(start..<levels.count)
        }
        guard let first = spans.first, let last = spans.last,
              first.lowerBound <= Int.max / windowSize,
              last.upperBound <= Int.max / windowSize else {
            return nil
        }
        let startFrame = first.lowerBound * windowSize
        let endFrame = min(samples.count, last.upperBound * windowSize)
        return startFrame < endFrame ? startFrame..<endFrame : nil
    }
}
