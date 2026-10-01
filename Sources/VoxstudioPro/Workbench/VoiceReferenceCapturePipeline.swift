import Foundation

#if BUNDLED_SPEECH
import FluidAudio
#endif

struct VoiceReferenceCaptureResult: Sendable {
    var samples: [Float]
    var confirmedNoSpeech: Bool
}

enum VoiceReferenceCapturePipeline {
    static func process(
        samples: [Float],
        sampleRate: Double
    ) async throws -> VoiceReferenceCaptureResult {
        var current = samples
        current = await denoiseIfAvailable(current, sampleRate: sampleRate)

        #if BUNDLED_SPEECH
        do {
            let (trimmed, foundSpeech) = try await trimWithSilero(current, sampleRate: sampleRate)
            current = VoiceReferenceSpeechGate.normalizeLoudness(trimmed)
            return VoiceReferenceCaptureResult(samples: current, confirmedNoSpeech: !foundSpeech)
        } catch {
            Log.recording.notice("voice reference Silero trim unavailable, falling back to RMS: \(error.localizedDescription)")
        }
        #endif

        current = VoiceReferenceSilenceTrimmer.trim(samples: current, sampleRate: sampleRate)
        current = VoiceReferenceSpeechGate.normalizeLoudness(current)
        return VoiceReferenceCaptureResult(samples: current, confirmedNoSpeech: false)
    }

    private static func denoiseIfAvailable(_ samples: [Float], sampleRate: Double) async -> [Float] {
        #if BUNDLED_SPEECH
        do {
            let wet48k = try await MossFormerSpeechEnhancer.shared.enhance(
                audio: samples,
                sampleRate: Int(sampleRate.rounded())
            )
            let wet = try VoiceReferenceSpeechGate.resample(
                wet48k,
                from: Double(MossFormerSpeechEnhancer.sampleRate),
                to: sampleRate
            )
            return VoiceReferenceSpeechGate.mix(
                dry: samples,
                wet: wet,
                wetMix: VoiceReferenceSpeechGate.denoiseWetMix
            )
        } catch {
            Log.recording.notice("voice reference denoise skipped: \(error.localizedDescription)")
            return samples
        }
        #else
        return samples
        #endif
    }

    #if BUNDLED_SPEECH
    private static func trimWithSilero(
        _ samples: [Float],
        sampleRate: Double
    ) async throws -> (samples: [Float], foundSpeech: Bool) {
        let vadSamples = try VoiceReferenceSpeechGate.resample(
            samples,
            from: sampleRate,
            to: VoiceReferenceSpeechGate.vadSampleRate
        )
        var segmentation = VadSegmentationConfig(
            minSpeechDuration: VoiceReferenceSpeechGate.minSpeechDuration,
            speechPadding: VoiceReferenceSpeechGate.padding,
            silenceThresholdForSplit: VoiceReferenceSpeechGate.vadExitThreshold,
            negativeThreshold: VoiceReferenceSpeechGate.vadExitThreshold
        )
        segmentation.maxSpeechDuration = .infinity
        let analysis = try await SpeechAnalysisService.shared.analyze(
            samples: vadSamples,
            threshold: VoiceReferenceSpeechGate.vadEntryThreshold,
            segmentation: segmentation,
            progress: { _, _, _ in }
        )
        let intervals = analysis.segments.map {
            VoiceReferenceSpeechInterval(startTime: Double($0.startTime), endTime: Double($0.endTime))
        }
        guard let span = VoiceReferenceSpeechGate.trimmedSpan(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: intervals
        ) else {
            return (samples, false)
        }
        return (Array(samples[span]), true)
    }
    #endif
}
