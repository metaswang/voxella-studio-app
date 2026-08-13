import Foundation

struct AlignmentSpeechInterval: Equatable, Sendable {
    var startTime: Double
    var endTime: Double

    var duration: Double { endTime - startTime }
}

struct AlignmentSoundSceneWindow: Equatable, Sendable {
    var startTime: Double
    var endTime: Double
    var speechConfidence: Double
    var musicOrSingingConfidence: Double
    var topLabel: String
    var topConfidence: Double
}

struct AlignmentSpeechSlice: Equatable, Sendable {
    var start: Double
    var end: Double
}

protocol AlignmentSoundSceneClassifying: Sendable {
    func classifySoundScenes(
        samples: [Float],
        sampleRate: Int,
        ranges: [ClosedRange<Double>]
    ) throws -> [AlignmentSoundSceneWindow]
}

struct AlignmentSpeechMask: Equatable, Sendable {
    var policy: AlignmentSpeechGate.Policy
    var audioDuration: Double
    var isAlignableSpeech: [Bool]

    var cellCount: Int { isAlignableSpeech.count }

    func isAlignable(at time: Double) -> Bool {
        guard cellCount > 0, time.isFinite, time >= 0, time < audioDuration else { return false }
        return isAlignableSpeech[cellIndex(for: time)]
    }

    func cellIndex(for time: Double) -> Int {
        guard cellCount > 0 else { return 0 }
        let index = Int((time / policy.cellDuration).rounded(.down))
        return min(cellCount - 1, max(0, index))
    }
}

enum AlignmentSpeechGate {
    struct Policy: Equatable, Sendable {
        var cellDuration: Double
        var absoluteFloor: Double
        var quietRatio: Double
        var pad: Double
        var minSpeechDuration: Double
        var minInteriorPause: Double
        var sceneWindowDuration: Double
        var sceneOverlapFactor: Double
        var sceneVetoConfidence: Double
        var sceneSpeechConfidence: Double

        static let standard = Policy(
            cellDuration: 512.0 / 16_000.0,
            absoluteFloor: 0.003,
            quietRatio: 0.25,
            pad: 0.08,
            minSpeechDuration: 0.25,
            minInteriorPause: 0.30,
            sceneWindowDuration: 0.5,
            sceneOverlapFactor: 0.5,
            sceneVetoConfidence: 0.5,
            sceneSpeechConfidence: 0.3
        )
    }

    static func mask(
        samples: [Float],
        sampleRate: Int,
        speechIntervals: [AlignmentSpeechInterval],
        policy: Policy = .standard,
        sceneClassifier: (any AlignmentSoundSceneClassifying)? = nil
    ) -> AlignmentSpeechMask {
        let duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        let empty = AlignmentSpeechMask(policy: policy, audioDuration: max(0, duration), isAlignableSpeech: [])
        guard sampleRate > 0, !samples.isEmpty, duration.isFinite, duration > 0,
              policy.cellDuration.isFinite, policy.cellDuration > 0 else {
            return empty
        }

        let cellSamples = max(1, Int((policy.cellDuration * Double(sampleRate)).rounded()))
        let cellCount = (samples.count + cellSamples - 1) / cellSamples
        var sileroSpeech = Array(repeating: false, count: cellCount)
        var rms = Array(repeating: 0.0, count: cellCount)
        for index in 0..<cellCount {
            let start = index * cellSamples
            let end = min(samples.count, start + cellSamples)
            rms[index] = cellRMS(samples[start..<end])
            let cellStart = Double(index) * policy.cellDuration
            let cellEnd = min(duration, Double(index + 1) * policy.cellDuration)
            sileroSpeech[index] = speechIntervals.contains { interval in
                interval.startTime.isFinite && interval.endTime.isFinite
                    && interval.endTime > interval.startTime
                    && cellStart < interval.endTime && cellEnd > interval.startTime
            }
        }

        var energySpeech = Array(repeating: false, count: cellCount)
        let validIntervals = speechIntervals.filter {
            $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
        }
        if validIntervals.isEmpty {
            let quietFloor = policy.absoluteFloor
            for index in 0..<cellCount where sileroSpeech[index] {
                energySpeech[index] = rms[index] >= quietFloor
            }
        } else {
            for interval in validIntervals {
                let lower = cellIndex(for: interval.startTime, cellCount: cellCount, policy: policy)
                let upper = cellIndex(for: max(interval.startTime, interval.endTime - 1e-9), cellCount: cellCount, policy: policy)
                let speechRMS = median(rms.enumerated().compactMap { index, value in
                    (index >= lower && index <= upper && sileroSpeech[index]) ? value : nil
                })
                let quietFloor = max(policy.absoluteFloor, (speechRMS ?? 0) * policy.quietRatio)
                let floor = speechRMS == nil ? policy.absoluteFloor : quietFloor
                for index in lower...upper where sileroSpeech[index] {
                    energySpeech[index] = rms[index] >= floor
                }
            }
        }

        var musicWithoutSpeech = Array(repeating: false, count: cellCount)
        if let sceneClassifier {
            let ranges = energySpeechRanges(
                energySpeech: energySpeech,
                policy: policy,
                audioDuration: duration
            )
            let windows: [AlignmentSoundSceneWindow]
            do {
                windows = ranges.isEmpty
                    ? []
                    : try sceneClassifier.classifySoundScenes(
                        samples: samples,
                        sampleRate: sampleRate,
                        ranges: ranges
                    )
            } catch {
                windows = []
            }
            for window in windows {
                guard window.startTime.isFinite, window.endTime.isFinite, window.endTime > window.startTime else {
                    continue
                }
                let musicOrSinging = isMusicOrSinging(window.topLabel)
                    && window.topConfidence >= policy.sceneVetoConfidence
                let spoken = window.speechConfidence >= policy.sceneSpeechConfidence
                guard musicOrSinging && !spoken else { continue }
                let lower = cellIndex(for: window.startTime, cellCount: cellCount, policy: policy)
                let upper = cellIndex(for: max(window.startTime, window.endTime - 1e-9), cellCount: cellCount, policy: policy)
                for index in lower...upper {
                    musicWithoutSpeech[index] = true
                }
            }
        }

        let alignable = zip(energySpeech, musicWithoutSpeech).map { $0 && !$1 }
        return AlignmentSpeechMask(policy: policy, audioDuration: duration, isAlignableSpeech: alignable)
    }

    static func splitIntervals(
        _ intervals: [AlignmentSpeechInterval],
        mask: AlignmentSpeechMask
    ) -> [AlignmentSpeechInterval] {
        let policy = mask.policy
        guard mask.cellCount > 0, policy.minInteriorPause.isFinite, policy.minInteriorPause > 0 else {
            return intervals.filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
        }

        var result: [AlignmentSpeechInterval] = []
        for interval in intervals {
            guard interval.startTime.isFinite, interval.endTime.isFinite, interval.endTime > interval.startTime else {
                continue
            }
            let pieces = splitInterval(interval, mask: mask)
            result.append(contentsOf: pieces)
        }
        return result
    }

    static func alignableIntervals(mask: AlignmentSpeechMask) -> [AlignmentSpeechInterval] {
        guard mask.cellCount > 0 else { return [] }
        let policy = mask.policy
        var result: [AlignmentSpeechInterval] = []
        var runStart: Int?
        for index in 0..<mask.cellCount {
            if mask.isAlignableSpeech[index] {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let startTime = Double(start) * policy.cellDuration
                let endTime = min(mask.audioDuration, Double(index) * policy.cellDuration)
                if endTime > startTime {
                    result.append(AlignmentSpeechInterval(startTime: startTime, endTime: endTime))
                }
                runStart = nil
            }
        }
        if let start = runStart {
            let startTime = Double(start) * policy.cellDuration
            if mask.audioDuration > startTime {
                result.append(AlignmentSpeechInterval(startTime: startTime, endTime: mask.audioDuration))
            }
        }
        return result
    }

    static func trimmedAlignmentSlice(
        spanStart: Double,
        spanEnd: Double,
        contextDuration: Double,
        audioDuration: Double,
        mask: AlignmentSpeechMask?
    ) -> AlignmentSpeechSlice {
        let context = contextDuration.isFinite && contextDuration > 0 ? contextDuration : 0
        let duration = audioDuration.isFinite && audioDuration > 0 ? audioDuration : 0
        let windowStart = max(0, (spanStart.isFinite ? spanStart : 0) - context)
        let windowEnd = min(duration, max(windowStart, (spanEnd.isFinite ? spanEnd : 0) + context))
        let untrimmed = AlignmentSpeechSlice(start: windowStart, end: windowEnd)
        guard let mask, mask.cellCount > 0, windowEnd > windowStart else { return untrimmed }

        let policy = mask.policy
        let first = firstAlignableCell(
            in: windowStart..<windowEnd,
            mask: mask,
            fromStart: true
        )
        let last = firstAlignableCell(
            in: windowStart..<windowEnd,
            mask: mask,
            fromStart: false
        )
        guard let first, let last, last >= first else { return untrimmed }

        let pad = policy.pad.isFinite && policy.pad > 0 ? policy.pad : 0
        let trimmedStart = max(windowStart, Double(first) * policy.cellDuration - pad)
        let trimmedEnd = min(windowEnd, Double(last + 1) * policy.cellDuration + pad)
        guard trimmedEnd - trimmedStart >= policy.minSpeechDuration else { return untrimmed }
        return AlignmentSpeechSlice(start: trimmedStart, end: trimmedEnd)
    }

    private static func splitInterval(
        _ interval: AlignmentSpeechInterval,
        mask: AlignmentSpeechMask
    ) -> [AlignmentSpeechInterval] {
        let policy = mask.policy
        let lower = mask.cellIndex(for: interval.startTime)
        let upper = mask.cellIndex(for: max(interval.startTime, interval.endTime - 1e-9))
        var pieces: [AlignmentSpeechInterval] = []
        var speechStart: Int?
        var pauseStart: Int?

        func emitSpeech(from start: Int, to end: Int) {
            guard end >= start else { return }
            let startTime = max(interval.startTime, Double(start) * policy.cellDuration)
            let endTime = min(interval.endTime, Double(end + 1) * policy.cellDuration)
            guard endTime > startTime else { return }
            pieces.append(AlignmentSpeechInterval(startTime: startTime, endTime: endTime))
        }

        for index in lower...upper {
            let alignable = mask.isAlignableSpeech[index]
            if alignable {
                if let pause = pauseStart {
                    let pauseDuration = Double(index - pause) * policy.cellDuration
                    if pauseDuration >= policy.minInteriorPause, let start = speechStart {
                        emitSpeech(from: start, to: pause - 1)
                        speechStart = index
                    }
                    pauseStart = nil
                }
                if speechStart == nil { speechStart = index }
            } else if speechStart != nil, pauseStart == nil {
                pauseStart = index
            }
        }
        if let start = speechStart {
            if let pause = pauseStart {
                let trailingPause = Double(upper - pause + 1) * policy.cellDuration
                emitSpeech(from: start, to: trailingPause >= policy.minInteriorPause ? pause - 1 : upper)
            } else {
                emitSpeech(from: start, to: upper)
            }
        }
        return pieces
    }

    private static func firstAlignableCell(
        in range: Range<Double>,
        mask: AlignmentSpeechMask,
        fromStart: Bool
    ) -> Int? {
        let lower = mask.cellIndex(for: range.lowerBound)
        let upper = mask.cellIndex(for: max(range.lowerBound, range.upperBound - 1e-9))
        let indices = fromStart ? Array(lower...upper) : Array((lower...upper).reversed())
        return indices.first { mask.isAlignableSpeech[$0] }
    }

    private static func energySpeechRanges(
        energySpeech: [Bool],
        policy: Policy,
        audioDuration: Double
    ) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?
        for index in energySpeech.indices {
            if energySpeech[index] {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let startTime = Double(start) * policy.cellDuration
                let endTime = min(audioDuration, Double(index) * policy.cellDuration)
                if endTime > startTime {
                    ranges.append(startTime...endTime)
                }
                runStart = nil
            }
        }
        if let start = runStart {
            let startTime = Double(start) * policy.cellDuration
            if audioDuration > startTime {
                ranges.append(startTime...audioDuration)
            }
        }
        return ranges
    }

    private static func cellIndex(for time: Double, cellCount: Int, policy: Policy) -> Int {
        guard cellCount > 0 else { return 0 }
        let index = Int((time / policy.cellDuration).rounded(.down))
        return min(cellCount - 1, max(0, index))
    }

    private static func cellRMS(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    static func isMusicOrSinging(_ label: String) -> Bool {
        let normalized = label.lowercased()
        return normalized == "music" || normalized == "singing"
            || normalized.hasPrefix("music") || normalized.contains("singing")
    }

    static func isSpeechLabel(_ label: String) -> Bool {
        label.lowercased().contains("speech")
    }
}
