import Foundation

struct ASRAudioLevelMetrics: Equatable, Sendable {
    let sampleCount: Int
    let rmsDBFS: Double
    let peakDBFS: Double
    let activeSampleRatio: Double

    var isEffectivelySilent: Bool {
        sampleCount == 0 || (
            rmsDBFS < ASRAudioPreprocessor.silenceRMSDBFS
                && peakDBFS < ASRAudioPreprocessor.silencePeakDBFS
                && activeSampleRatio < ASRAudioPreprocessor.silenceActiveSampleRatio
        )
    }
}

struct ASRAudioPreprocessingResult: Sendable {
    let samples: [Float]
    let original: ASRAudioLevelMetrics
    let processed: ASRAudioLevelMetrics
    let appliedGainDB: Double

    var didApplyGain: Bool { appliedGainDB > 0.01 }
}

enum ASRAudioPreprocessor {
    static let cacheVersion = 2
    static let sampleRate = 16_000
    static let targetPeakDBFS = -3.0
    /// Linear loudness target (approximate LUFS). No dynamic AGC.
    static let targetIntegratedLUFS = -20.0
    static let truePeakCeilingDBTP = -3.0
    static let maximumGainDB = 30.0
    static let maximumVADRescueGainDB = 12.0
    static let lowLevelRMSDBFS = -40.0
    static let silenceRMSDBFS = -60.0
    static let silencePeakDBFS = -50.0
    static let silenceActiveSampleRatio = 0.001
    private static let activeSampleDBFS = -55.0

    static func prepare(samples: [Float]) -> ASRAudioPreprocessingResult {
        let original = metrics(for: samples)
        guard !samples.isEmpty, !original.isEffectivelySilent else {
            return ASRAudioPreprocessingResult(
                samples: samples,
                original: original,
                processed: original,
                appliedGainDB: 0
            )
        }

        // Only boost clearly low-level captures; healthy levels stay untouched.
        guard original.rmsDBFS < lowLevelRMSDBFS || original.peakDBFS < -24 else {
            return ASRAudioPreprocessingResult(
                samples: samples,
                original: original,
                processed: original,
                appliedGainDB: 0
            )
        }

        let beforePeak = original.peakDBFS
        let normalized = LinearLoudnessNormalizer.normalizeLinear(
            samples,
            targetLUFS: targetIntegratedLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP,
            maximumGainDB: maximumGainDB
        )
        let processed = metrics(for: normalized)
        let appliedGainDB: Double
        if beforePeak.isFinite, processed.peakDBFS.isFinite {
            appliedGainDB = max(0, processed.peakDBFS - beforePeak)
        } else {
            appliedGainDB = 0
        }

        // If linear loudness would reduce level, keep the prior peak-only boost path.
        if appliedGainDB <= 0.01 {
            return preparePeakGain(samples: samples, original: original)
        }

        return ASRAudioPreprocessingResult(
            samples: normalized,
            original: original,
            processed: processed,
            appliedGainDB: appliedGainDB
        )
    }

    static func prepareVADRescue(samples: [Float]) -> ASRAudioPreprocessingResult {
        let original = metrics(for: samples)
        guard !samples.isEmpty, !original.isEffectivelySilent,
              original.rmsDBFS < lowLevelRMSDBFS || original.peakDBFS < -24 else {
            return ASRAudioPreprocessingResult(
                samples: samples,
                original: original,
                processed: original,
                appliedGainDB: 0
            )
        }
        let gainDB = min(maximumVADRescueGainDB, max(0, targetPeakDBFS - original.peakDBFS))
        guard gainDB > 0.01 else {
            return ASRAudioPreprocessingResult(
                samples: samples,
                original: original,
                processed: original,
                appliedGainDB: 0
            )
        }
        let gain = Float(pow(10, gainDB / 20))
        let ceiling = Float(pow(10, truePeakCeilingDBTP / 20))
        let rescued = samples.map { min(ceiling, max(-ceiling, $0 * gain)) }
        return ASRAudioPreprocessingResult(
            samples: rescued,
            original: original,
            processed: metrics(for: rescued),
            appliedGainDB: gainDB
        )
    }

    private static func preparePeakGain(
        samples: [Float],
        original: ASRAudioLevelMetrics
    ) -> ASRAudioPreprocessingResult {
        let requestedGainDB = max(0, targetPeakDBFS - original.peakDBFS)
        let gainDB = min(maximumGainDB, requestedGainDB)
        guard gainDB > 0.01 else {
            return ASRAudioPreprocessingResult(
                samples: samples,
                original: original,
                processed: original,
                appliedGainDB: 0
            )
        }

        let gain = Float(pow(10, gainDB / 20))
        let ceiling = Float(pow(10, truePeakCeilingDBTP / 20))
        let processedSamples = samples.map { sample in
            min(ceiling, max(-ceiling, sample * gain))
        }
        return ASRAudioPreprocessingResult(
            samples: processedSamples,
            original: original,
            processed: metrics(for: processedSamples),
            appliedGainDB: gainDB
        )
    }

    static func metrics(for samples: [Float]) -> ASRAudioLevelMetrics {
        guard !samples.isEmpty else {
            return ASRAudioLevelMetrics(
                sampleCount: 0,
                rmsDBFS: -.infinity,
                peakDBFS: -.infinity,
                activeSampleRatio: 0
            )
        }

        var sumSquares = 0.0
        var peak = 0.0
        var activeCount = 0
        let activeThreshold = pow(10, activeSampleDBFS / 20)
        for sample in samples {
            let magnitude = min(1.0, abs(Double(sample)))
            sumSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= activeThreshold { activeCount += 1 }
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        return ASRAudioLevelMetrics(
            sampleCount: samples.count,
            rmsDBFS: decibels(for: rms),
            peakDBFS: decibels(for: peak),
            activeSampleRatio: Double(activeCount) / Double(samples.count)
        )
    }

    private static func decibels(for amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
}
