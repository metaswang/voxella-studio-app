import Accelerate
import Foundation

/// `torchaudio.compliance.kaldi.fbank` with the options pyannote passes for
/// WeSpeaker ResNet models (80 bins, 25 ms / 10 ms, Hamming, dither 0,
/// snip_edges, no energy), applied to int16-scaled audio, followed by
/// per-utterance mean normalization.
public struct KaldiFbankOptions: Equatable, Sendable {
    public var sampleRate = 16_000
    public var frameLength = 400
    public var frameShift = 160
    public var paddedLength = 512
    public var melBins = 80
    public var lowFrequency: Double = 20
    public var highFrequency: Double = 0 // ≤ 0 means Nyquist + value, as in Kaldi
    public var preemphasis: Float = 0.97
    public var inputScale: Float = 32_768

    public static let weSpeaker = KaldiFbankOptions()

    public init() {}

    /// Version tag for caches keyed by front-end behavior.
    public static let frontEndVersion = "kaldi-fbank-v1"

    /// `1 + (n - frameLength) / frameShift` with snip_edges, else 0.
    public func frameCount(sampleCount: Int) -> Int {
        sampleCount < frameLength ? 0 : 1 + (sampleCount - frameLength) / frameShift
    }
}

public final class KaldiFbank {
    public let options: KaldiFbankOptions
    private let log2FFT: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    /// Row-major `[bins, melBins]`, Nyquist row zero (torchaudio pads it).
    private let banks: [Float]

    /// `torch.finfo(torch.float).eps`
    static let epsilon: Float = 1.1920929e-07

    public init(options: KaldiFbankOptions = .weSpeaker) {
        self.options = options
        log2FFT = vDSP_Length(log2(Double(options.paddedLength)).rounded())
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create vDSP FFT setup")
        }
        fftSetup = setup
        let length = options.frameLength
        window = (0..<length).map {
            Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(length - 1)))
        }
        banks = Self.melBanks(options: options)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Mean-normalized log-mel features `[frames, melBins]`, row-major.
    public func features(_ audio: [Float]) -> (values: [Float], frames: Int) {
        let frames = options.frameCount(sampleCount: audio.count)
        guard frames > 0 else { return ([], 0) }
        let length = options.frameLength
        let padded = options.paddedLength
        let half = padded / 2
        let bins = half + 1
        let mels = options.melBins
        var power = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: padded)
        var emphasized = [Float](repeating: 0, count: length)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)

        for index in 0..<frames {
            let start = index * options.frameShift
            var mean: Float = 0
            for offset in 0..<length { mean += audio[start + offset] * options.inputScale }
            mean /= Float(length)
            // DC removal, then pre-emphasis with x[-1] replicated from x[0].
            for offset in 0..<length {
                let current = audio[start + offset] * options.inputScale - mean
                let previous = offset == 0 ? current : audio[start + offset - 1] * options.inputScale - mean
                emphasized[offset] = current - options.preemphasis * previous
            }
            for offset in 0..<length { frame[offset] = emphasized[offset] * window[offset] }
            for offset in length..<padded { frame[offset] = 0 }
            for k in 0..<half {
                real[k] = frame[2 * k]
                imaginary[k] = frame[2 * k + 1]
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2FFT, FFTDirection(kFFTDirection_Forward))
                }
            }
            // vDSP's forward real FFT is scaled by 2.
            let base = index * bins
            power[base] = 0.25 * real[0] * real[0]
            power[base + half] = 0.25 * imaginary[0] * imaginary[0]
            for k in 1..<half {
                power[base + k] = 0.25 * (real[k] * real[k] + imaginary[k] * imaginary[k])
            }
        }

        var mel = [Float](repeating: 0, count: frames * mels)
        vDSP_mmul(power, 1, banks, 1, &mel, 1, vDSP_Length(frames), vDSP_Length(mels), vDSP_Length(bins))
        var floor = Self.epsilon
        var ceiling = Float.greatestFiniteMagnitude
        vDSP_vclip(mel, 1, &floor, &ceiling, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlogf(&mel, mel, &count)

        // Cepstral mean normalization over the utterance.
        for bin in 0..<mels {
            var sum: Double = 0
            for row in 0..<frames { sum += Double(mel[row * mels + bin]) }
            let mean = Float(sum / Double(frames))
            for row in 0..<frames { mel[row * mels + bin] -= mean }
        }
        return (mel, frames)
    }

    /// Kaldi `get_mel_banks` (no VTLN), triangles in the 1127·ln mel domain,
    /// transposed to `[paddedLength / 2 + 1, melBins]` with a zero Nyquist row.
    static func melBanks(options: KaldiFbankOptions) -> [Float] {
        let mels = options.melBins
        let fftBins = options.paddedLength / 2
        let nyquist = Double(options.sampleRate) / 2
        let high = options.highFrequency <= 0 ? nyquist + options.highFrequency : options.highFrequency
        func mel(_ hz: Double) -> Double { 1127 * log(1 + hz / 700) }
        let lowMel = mel(options.lowFrequency)
        let highMel = mel(high)
        let delta = (highMel - lowMel) / Double(mels + 1)
        let binWidth = Double(options.sampleRate) / Double(options.paddedLength)
        var banks = [Float](repeating: 0, count: (fftBins + 1) * mels)
        for bank in 0..<mels {
            let left = lowMel + Double(bank) * delta
            let center = left + delta
            let right = center + delta
            for bin in 0..<fftBins {
                let value = mel(binWidth * Double(bin))
                let up = (value - left) / (center - left)
                let down = (right - value) / (right - center)
                banks[bin * mels + bank] = Float(max(0, min(up, down)))
            }
        }
        return banks
    }
}
