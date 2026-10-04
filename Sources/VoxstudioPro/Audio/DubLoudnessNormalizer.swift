import Foundation

/// Match synthesized mono voices with one gain per segment, preserving their
/// dynamics and timing. K-weighting is used only for measurement, not playback.
enum DubLoudnessNormalizer {
    static let targetLUFS = -18.0
    static let samplePeakCeilingDBFS = -1.0

    static func gains(for segments: [[Float]], sampleRate: Int) -> [Float] {
        segments.map { samples in
            guard let loudness = integratedLUFS(in: samples, sampleRate: sampleRate),
                  loudness > -60 else { return 1 }
            // Avoid turning near-silent model output into loud background noise.
            let gainDB = min(30, max(-30, targetLUFS - loudness))
            return Float(pow(10, gainDB / 20))
        }
    }

    /// A shared gain after mixing avoids both clipping overlapping voices and
    /// undoing the loudness match by peak-limiting each voice independently.
    static func applyHeadroom(to samples: inout [Float]) {
        let peak = LinearLoudnessNormalizer.samplePeak(samples)
        let ceiling = Float(pow(10, samplePeakCeilingDBFS / 20))
        let scale = peak > ceiling ? ceiling / peak : 1
        for index in samples.indices {
            samples[index] = samples[index].isFinite ? samples[index] * scale : 0
        }
    }

    /// Mono BS.1770-style integrated measurement: K-weighting, 400 ms blocks
    /// with 75% overlap, an absolute -70 LUFS gate and a relative -10 LU gate.
    /// Utterances shorter than a block use their available frames.
    static func integratedLUFS(in samples: [Float], sampleRate: Int) -> Double? {
        guard !samples.isEmpty, (8_000...192_000).contains(sampleRate) else { return nil }
        var shelf = Biquad(
            b: [1.53512485958697, -2.69169618940638, 1.19839281085285],
            a: [1, -1.69065929318241, 0.73248077421585],
            sampleRate: sampleRate
        )
        var highPass = Biquad(
            b: [1, -2, 1], a: [1, -1.99004745483398, 0.99007225036621],
            sampleRate: sampleRate
        )
        let window = min(samples.count, Int((Double(sampleRate) * 0.4).rounded()))
        let hop = max(1, Int((Double(sampleRate) * 0.1).rounded()))
        var ring = [Double](repeating: 0, count: window)
        var energy = 0.0
        var blocks: [Double] = []
        for index in samples.indices {
            let input = samples[index].isFinite ? Double(samples[index]) : 0
            let weighted = highPass.process(shelf.process(input))
            let square = weighted * weighted
            let slot = index % window
            energy += square - ring[slot]
            ring[slot] = square
            if index >= window - 1, (index - window + 1) % hop == 0 {
                blocks.append(max(0, energy / Double(window)))
            }
        }
        let absoluteThreshold = pow(10, (-70 + 0.691) / 10)
        let audible = blocks.filter { $0 > absoluteThreshold }
        guard !audible.isEmpty else { return nil }
        let relativeThreshold = audible.reduce(0, +) / Double(audible.count) * 0.1
        let gated = audible.filter { $0 > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }

    private struct Biquad {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var state1 = 0.0
        var state2 = 0.0

        init(b: [Double], a: [Double], sampleRate: Int) {
            // ITU-R BS.1770's published 48 kHz coefficients, transformed through
            // the bilinear domain to retain the response at the TTS sample rate.
            let ratio = Double(sampleRate) / 48_000
            let n0 = 1 - ratio, n1 = 1 + ratio
            let d0 = n1, d1 = n0
            func transform(_ c: [Double]) -> [Double] {
                [
                    c[0] * d0 * d0 + c[1] * n0 * d0 + c[2] * n0 * n0,
                    2 * c[0] * d0 * d1 + c[1] * (n0 * d1 + n1 * d0) + 2 * c[2] * n0 * n1,
                    c[0] * d1 * d1 + c[1] * n1 * d1 + c[2] * n1 * n1
                ]
            }
            let numerator = transform(b), denominator = transform(a)
            b0 = numerator[0] / denominator[0]
            b1 = numerator[1] / denominator[0]
            b2 = numerator[2] / denominator[0]
            a1 = denominator[1] / denominator[0]
            a2 = denominator[2] / denominator[0]
        }

        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + state1
            state1 = b1 * input - a1 * output + state2
            state2 = b2 * input - a2 * output
            return output
        }
    }
}
