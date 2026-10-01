import Foundation

/// Linear (non-AGC) loudness helpers shared by listen-track bake and ASR prep.
enum LinearLoudnessNormalizer {
    /// Approximate integrated loudness in LUFS from mean-square energy (no K-weighting).
    /// Good enough for linear gain targeting; not a certified BS.1770 meter.
    static func approximateIntegratedLUFS(samples: [Float], silenceFloorDBFS: Double = -70) -> Double? {
        guard !samples.isEmpty else { return nil }
        let floor = pow(10.0, silenceFloorDBFS / 20.0)
        var sumSquares = 0.0
        var count = 0
        for sample in samples {
            let magnitude = abs(Double(sample.isFinite ? sample : 0))
            guard magnitude >= floor else { continue }
            sumSquares += magnitude * magnitude
            count += 1
        }
        guard count > 0 else { return nil }
        let meanSquare = sumSquares / Double(count)
        guard meanSquare > 0 else { return nil }
        // BS.1770 offsets mean-square by −0.691 for LUFS; keep the same convention.
        return -0.691 + 10.0 * log10(meanSquare)
    }

    static func samplePeak(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample.isFinite ? sample : 0)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    /// Apply a single linear gain toward `targetLUFS`, then hard-clip at true-peak ceiling.
    static func normalizeLinear(
        _ samples: [Float],
        targetLUFS: Double,
        truePeakCeilingDBTP: Double,
        maximumGainDB: Double = 30
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let ceiling = Float(pow(10.0, truePeakCeilingDBTP / 20.0))
        guard let integrated = approximateIntegratedLUFS(samples: samples), integrated.isFinite else {
            return limitTruePeak(samples, ceiling: ceiling)
        }

        let requestedGainDB = targetLUFS - integrated
        let gainDB = min(maximumGainDB, max(-maximumGainDB, requestedGainDB))
        let gain = Float(pow(10.0, gainDB / 20.0))
        let peak = samplePeak(samples) * abs(gain)
        var scale = gain
        if peak > ceiling, peak > 0 {
            scale *= ceiling / peak
        }
        return samples.map { sample in
            let finite = sample.isFinite ? sample : 0
            return min(ceiling, max(-ceiling, finite * scale))
        }
    }

    static func limitTruePeak(_ samples: [Float], ceiling: Float) -> [Float] {
        samples.map { sample in
            let finite = sample.isFinite ? sample : 0
            return min(ceiling, max(-ceiling, finite))
        }
    }

    /// First-order high-pass (DC / rumble cut). Cutoff should stay ≤ 80 Hz for lecture halls.
    static func highPass(
        _ samples: [Float],
        sampleRate: Double,
        cutoffHz: Double
    ) -> [Float] {
        guard !samples.isEmpty,
              sampleRate.isFinite, sampleRate > 0,
              cutoffHz.isFinite, cutoffHz > 0,
              cutoffHz < sampleRate * 0.45 else {
            return samples
        }
        let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var previousInput: Float = 0
        var previousOutput: Float = 0
        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            let input = samples[index].isFinite ? samples[index] : 0
            let filtered = alpha * (previousOutput + input - previousInput)
            output[index] = filtered
            previousInput = input
            previousOutput = filtered
        }
        return output
    }
}
