import Accelerate
import Foundation

/// 128-band log-mel front end of the source checkpoint's feature extractor:
/// 0.97 pre-emphasis, symmetric 400-sample Hann window centered in a 512-point
/// zero-padded STFT (`center=True`, constant padding), Slaney mel filters over
/// 0–8 kHz, `log(power + 2^-24)`, no normalization.
///
/// Frames are computed on demand for a frame range, so a chunked caller never
/// holds the spectrogram of a whole recording. Each frame depends only on the
/// samples under its window, so chunked and whole-file extraction are identical.
final class Nemotron3MelExtractor {
    let geometry: Nemotron3Geometry
    private let log2FFT: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    /// Row-major `[nBins, nMels]` for `vDSP_mmul(power, filters)`.
    private let filters: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imaginary: [Float]

    static let logZeroGuard: Float = 0x1p-24

    init(geometry: Nemotron3Geometry = .offline) {
        self.geometry = geometry
        log2FFT = vDSP_Length(log2(Double(geometry.fftLength)).rounded())
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create vDSP FFT setup")
        }
        fftSetup = setup
        let length = geometry.windowLength
        window = (0..<length).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(length - 1)))
        }
        filters = Self.slaneyFilters(geometry: geometry)
        frame = [Float](repeating: 0, count: geometry.fftLength)
        real = [Float](repeating: 0, count: geometry.fftLength / 2)
        imaginary = [Float](repeating: 0, count: geometry.fftLength / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    var binCount: Int { geometry.fftLength / 2 + 1 }

    /// Log-mel rows `[frames.count, nMels]` for `frames` of the whole recording.
    func extract(audio: [Float], frames: Range<Int>) -> [Float] {
        let mels = geometry.melBins
        guard !frames.isEmpty else { return [] }
        let bins = binCount
        let half = geometry.fftLength / 2
        let length = geometry.windowLength
        let hop = geometry.hopLength
        let centerOffset = length / 2
        var power = [Float](repeating: 0, count: frames.count * bins)

        audio.withUnsafeBufferPointer { samples in
            for (row, frameIndex) in frames.enumerated() {
                let origin = frameIndex * hop - centerOffset
                for index in 0..<length {
                    frame[index] = window[index] * preemphasized(samples, at: origin + index)
                }
                for index in length..<geometry.fftLength {
                    frame[index] = 0
                }
                for index in 0..<half {
                    real[index] = frame[2 * index]
                    imaginary[index] = frame[2 * index + 1]
                }
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!
                        )
                        vDSP_fft_zrip(fftSetup, &split, 1, log2FFT, FFTDirection(kFFTDirection_Forward))
                    }
                }
                // vDSP's forward real FFT is scaled by 2, so |X|^2 is scaled by 4.
                let base = row * bins
                power[base] = 0.25 * real[0] * real[0]
                power[base + half] = 0.25 * imaginary[0] * imaginary[0]
                for bin in 1..<half {
                    power[base + bin] = 0.25 * (real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
                }
            }
        }

        var mel = [Float](repeating: 0, count: frames.count * mels)
        vDSP_mmul(power, 1, filters, 1, &mel, 1,
                  vDSP_Length(frames.count), vDSP_Length(mels), vDSP_Length(bins))
        var guardValue = Self.logZeroGuard
        vDSP_vsadd(mel, 1, &guardValue, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlogf(&mel, mel, &count)
        return mel
    }

    /// Pre-emphasized sample with zero padding outside the recording.
    @inline(__always)
    private func preemphasized(_ samples: UnsafeBufferPointer<Float>, at index: Int) -> Float {
        guard index >= 0, index < samples.count else { return 0 }
        guard index > 0 else { return samples[0] }
        return samples[index] - geometry.preemphasis * samples[index - 1]
    }

    /// librosa `filters.mel(sr, n_fft, n_mels, fmin=0, fmax=sr/2, htk=False, norm="slaney")`,
    /// transposed to `[nBins, nMels]`.
    static func slaneyFilters(geometry: Nemotron3Geometry) -> [Float] {
        let mels = geometry.melBins
        let bins = geometry.fftLength / 2 + 1
        let sampleRate = Double(geometry.sampleRate)
        let linearStep = 200.0 / 3.0
        let minimumLogHz = 1000.0
        let minimumLogMel = minimumLogHz / linearStep
        let logStep = log(6.4) / 27.0
        func hzToMel(_ hz: Double) -> Double {
            hz >= minimumLogHz ? minimumLogMel + log(hz / minimumLogHz) / logStep : hz / linearStep
        }
        func melToHz(_ mel: Double) -> Double {
            mel >= minimumLogMel ? minimumLogHz * exp(logStep * (mel - minimumLogMel)) : linearStep * mel
        }
        let melMaximum = hzToMel(sampleRate / 2)
        let edges = (0..<(mels + 2)).map { melToHz(Double($0) * melMaximum / Double(mels + 1)) }
        var filters = [Float](repeating: 0, count: bins * mels)
        for mel in 0..<mels {
            let lower = edges[mel]
            let center = edges[mel + 1]
            let upper = edges[mel + 2]
            let normalization = 2 / (upper - lower)
            for bin in 0..<bins {
                let frequency = Double(bin) * sampleRate / Double(geometry.fftLength)
                let rising = (frequency - lower) / (center - lower)
                let falling = (upper - frequency) / (upper - center)
                filters[bin * mels + mel] = Float(max(0, min(rising, falling)) * normalization)
            }
        }
        return filters
    }
}
