import AVFoundation
import Foundation

struct VoiceReferenceSpeechInterval: Equatable, Sendable {
    var startTime: Double
    var endTime: Double
}

enum VoiceReferenceSpeechGate {
    static let absoluteFloor: Float = 0.003
    static let quietRatio: Float = 0.4
    static let cellDuration = 512.0 / 16_000.0
    static let minSpeechDuration = 0.15
    static let padding = 0.1
    static let vadSampleRate = 16_000.0
    static let vadEntryThreshold: Float = 0.85
    static let vadExitThreshold: Float = 0.35
    static let denoiseWetMix: Float = 0.6
    static let targetPeakDBFS = -3.0
    static let maximumGainDB = 30.0
    static let truePeakCeilingDBTP = -1.5
    static let quietFlatPeak: Float = 0.05
    static let minimumQuietDynamicRange: Float = 2.5

    static func trimmedSpan(
        samples: [Float],
        sampleRate: Double,
        speechIntervals: [VoiceReferenceSpeechInterval],
        padding: Double = padding
    ) -> Range<Int>? {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else { return nil }
        let duration = Double(samples.count) / sampleRate
        let valid = speechIntervals.filter {
            $0.startTime.isFinite && $0.endTime.isFinite
                && $0.endTime > $0.startTime
                && $0.startTime < duration
                && $0.endTime > 0
        }
        guard !valid.isEmpty else { return nil }

        let cellSamples = max(1, Int((cellDuration * sampleRate).rounded()))
        let cellCount = (samples.count + cellSamples - 1) / cellSamples
        var kept = Array(repeating: false, count: cellCount)
        var rms = Array(repeating: 0.0 as Float, count: cellCount)
        for index in 0..<cellCount {
            let start = index * cellSamples
            let end = min(samples.count, start + cellSamples)
            rms[index] = cellRMS(samples[start..<end])
        }

        for interval in valid {
            let lower = cellIndex(for: max(0, interval.startTime), cellCount: cellCount)
            let upper = cellIndex(
                for: min(duration, max(interval.startTime, interval.endTime - 1e-9)),
                cellCount: cellCount
            )
            let speechRMS = median(rms[lower...upper].filter { $0 >= absoluteFloor })
            let floor = max(absoluteFloor, (speechRMS ?? 0) * quietRatio)
            for index in lower...upper where rms[index] >= floor {
                kept[index] = true
            }
        }

        guard let first = kept.firstIndex(of: true),
              let last = kept.lastIndex(of: true) else { return nil }

        // Silero (+ in-interval energy) outer edges, before padding.
        var start = first * cellSamples
        var end = min(samples.count, (last + 1) * cellSamples)

        // Intersect with RMS/energy audible edges so continuous light noise beds
        // that Silero still marks as speech are cut at the tighter outer bound.
        if let rmsSpan = VoiceReferenceSilenceTrimmer.audibleSpan(
            samples: samples,
            sampleRate: sampleRate
        ) {
            start = max(start, rmsSpan.lowerBound)
            end = min(end, rmsSpan.upperBound)
        }
        guard start < end else { return nil }

        let keptDuration = Double(end - start) / sampleRate
        guard keptDuration + 1e-9 >= minSpeechDuration else { return nil }

        let paddingFrames = max(0, Int((padding * sampleRate).rounded()))
        start = max(0, start - paddingFrames)
        end = min(samples.count, end + paddingFrames)
        guard start < end else { return nil }
        return start..<end
    }

    static func trim(
        samples: [Float],
        sampleRate: Double,
        speechIntervals: [VoiceReferenceSpeechInterval],
        padding: Double = padding
    ) -> [Float] {
        guard let span = trimmedSpan(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: speechIntervals,
            padding: padding
        ) else {
            return samples
        }
        return Array(samples[span])
    }

    static func normalizeLoudness(_ samples: [Float]) -> [Float] {
        let metrics = ASRAudioPreprocessor.metrics(for: samples)
        guard !metrics.isEffectivelySilent, metrics.peakDBFS.isFinite else { return samples }
        let ceiling = pow(10.0, truePeakCeilingDBTP / 20.0)
        let target = min(ceiling, pow(10.0, targetPeakDBFS / 20.0))
        let peak = pow(10.0, metrics.peakDBFS / 20.0)
        guard peak > 0 else { return samples }
        var gain = target / peak
        let maxGain = pow(10.0, maximumGainDB / 20.0)
        gain = min(gain, maxGain)
        let ceilingFloat = Float(ceiling)
        return samples.map { sample in
            let finite = sample.isFinite ? sample : 0
            return min(ceilingFloat, max(-ceilingFloat, finite * Float(gain)))
        }
    }

    static func mix(dry: [Float], wet: [Float], wetMix: Float) -> [Float] {
        let mix = min(1, max(0, wetMix))
        let dryMix = 1 - mix
        let count = min(dry.count, wet.count)
        guard count > 0 else { return dry }
        var mixed = [Float](repeating: 0, count: count)
        for index in 0..<count {
            mixed[index] = dry[index] * dryMix + wet[index] * mix
        }
        return mixed
    }

    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate > 0, targetRate > 0 else {
            throw VoiceLibraryError.unsupportedAudio
        }
        if abs(sourceRate - targetRate) < 0.5 { return samples }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let inputChannel = inputBuffer.floatChannelData?[0] else {
            throw VoiceLibraryError.unsupportedAudio
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            inputChannel.update(from: base, count: samples.count)
        }
        let ratio = targetRate / sourceRate
        let outputCapacity = AVAudioFrameCount(
            max(1, Int((Double(samples.count) * ratio).rounded(.up)) + 64)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw VoiceLibraryError.unsupportedAudio
        }
        let conversionInput = VoiceConversionInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, state in
            conversionInput.next(status: state)
        }
        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0,
              let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw conversionError ?? VoiceLibraryError.unsupportedAudio
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
    }

    private static func cellRMS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            sum += finite * finite
        }
        return sqrt(sum / Float(samples.count))
    }

    private static func cellIndex(for time: Double, cellCount: Int) -> Int {
        guard cellCount > 0 else { return 0 }
        let index = Int((time / cellDuration).rounded(.down))
        return min(cellCount - 1, max(0, index))
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
