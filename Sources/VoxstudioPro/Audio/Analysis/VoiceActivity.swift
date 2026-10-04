import AVFoundation
#if BUNDLED_SPEECH
import AudioCommon
#endif

/// Silero VAD speech detection at the source file's native analysis resolution.
enum VoiceActivity {
    static let chunkDuration = Double(chunkSize) / Double(sampleRate)
    private static let sampleRate = 16_000
    private static let chunkSize = 512

    static func chunkCount(for sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        return ((sampleCount - 1) / chunkSize) + 1
    }

    struct Span: Codable {
        let start: Double
        let end: Double
    }

    struct Analysis: Codable {
        /// Number of 32 ms VAD cells spanning the full source duration.
        let chunkCount: Int
        /// Speech spans in source seconds.
        let segments: [Span]

        /// Per-cell speech flags; index maps uniformly onto the source duration.
        var mask: [Bool] {
            var mask = [Bool](repeating: false, count: chunkCount)
            for span in segments {
                let lo = max(0, Int(span.start / VoiceActivity.chunkDuration))
                let hi = min(chunkCount, Int((span.end / VoiceActivity.chunkDuration).rounded(.up)))
                guard lo < hi else { continue }
                for i in lo..<hi { mask[i] = true }
            }
            return mask
        }
    }

    static func analysis(for sourceURL: URL, mediaRef _: String) async throws -> Analysis {
        #if BUNDLED_SPEECH
        let samples: [Float]
        let preparedURL: URL
        do {
            preparedURL = try await DecodedAudioCache.file(for: sourceURL)
            let decoded = try AudioFileLoader.load(url: preparedURL, targetSampleRate: sampleRate)
            let preprocessing = ASRAudioPreprocessor.prepare(samples: decoded)
            samples = preprocessing.samples
        } catch AudioTrackReader.ReadError.noAudioTrack(_) {
            return noAudioAnalysis()
        }
        guard !samples.isEmpty else {
            return noAudioAnalysis()
        }
        let result = try await SpeechAnalysisService.shared.analyze(
            samples: samples,
            progress: { _, _, _ in }
        )
        let analysis = Analysis(
            chunkCount: chunkCount(for: samples.count),
            segments: result.segments.map {
                Span(start: Double($0.startTime), end: Double($0.endTime))
            }
        )
        return analysis
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    static func repairLongSilence(
        in samples: [Float],
        sampleRate: Int,
        maximumSilenceSeconds: Double = 0.35
    ) async throws -> [Float] {
        guard !samples.isEmpty,
              sampleRate > 0,
              maximumSilenceSeconds.isFinite,
              maximumSilenceSeconds >= 0 else {
            return samples
        }
        #if BUNDLED_SPEECH
        let analysisSamples = sampleRate == Self.sampleRate
            ? samples
            : AudioFileLoader.resample(samples, from: sampleRate, to: Self.sampleRate)
        let analysisResult = try await SpeechAnalysisService.shared.analyze(
            samples: analysisSamples,
            progress: { _, _, _ in }
        )
        return repairingLongSilence(
            in: samples,
            sampleRate: sampleRate,
            speechSpans: analysisResult.segments.map {
                Span(start: Double($0.startTime), end: Double($0.endTime))
            },
            maximumSilenceSeconds: maximumSilenceSeconds
        )
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    /// VAD spans are in seconds, independent of the analysis sample rate.
    static func repairingLongSilence(
        in samples: [Float],
        sampleRate: Int,
        speechSpans: [Span],
        maximumSilenceSeconds: Double = 0.35
    ) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0,
              maximumSilenceSeconds.isFinite, maximumSilenceSeconds >= 0 else {
            return samples
        }
        let duration = Double(samples.count) / Double(sampleRate)
        let paddingFrames = Int((0.04 * Double(sampleRate)).rounded(.down))
        let boundaryFrames = Int((0.08 * Double(sampleRate)).rounded(.down))
        let maximumGapFrames = Int((min(maximumSilenceSeconds, duration)
            * Double(sampleRate)).rounded(.down))
        let ranges = speechSpans.compactMap { span -> Range<Int>? in
            guard span.start.isFinite, span.end.isFinite, span.end > span.start else {
                return nil
            }
            let start = Int((min(duration, max(0, span.start))
                * Double(sampleRate)).rounded(.down))
            let end = Int((min(duration, max(0, span.end))
                * Double(sampleRate)).rounded(.up))
            guard end > start else { return nil }
            return max(0, start - paddingFrames)..<min(samples.count, end + paddingFrames)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        guard let first = merged.first, let last = merged.last else { return samples }

        var output: [Float] = []
        output.reserveCapacity(samples.count)
        output.append(contentsOf: samples[max(0, first.lowerBound - boundaryFrames)..<first.lowerBound])
        var previousEnd = first.lowerBound
        for range in merged {
            let keptGap = min(range.lowerBound - previousEnd, maximumGapFrames)
            let leading = keptGap / 2
            let trailing = keptGap - leading
            output.append(contentsOf: samples[previousEnd..<(previousEnd + leading)])
            output.append(contentsOf: samples[(range.lowerBound - trailing)..<range.lowerBound])
            output.append(contentsOf: samples[range])
            previousEnd = range.upperBound
        }
        output.append(contentsOf: samples[last.upperBound..<min(samples.count, last.upperBound + boundaryFrames)])

        // Protect speech that VAD missed without rejecting repairs just because
        // silence makes up more than 40% of the generated recording.
        func energy(_ values: [Float]) -> Double {
            values.reduce(0) { sum, sample in
                guard sample.isFinite else { return sum }
                return sum + Double(sample) * Double(sample)
            }
        }
        guard energy(output) >= energy(samples) * 0.99 else { return samples }
        return output
    }

    static func isDamagedMedia(_ error: Error) -> Bool {
        let nsError: NSError
        if let readError = error as? AudioTrackReader.ReadError,
           case .readFailed(_, let underlying) = readError,
           let underlying {
            nsError = underlying
        } else {
            nsError = error as NSError
        }
        return nsError.domain == AVFoundationErrorDomain && nsError.code == -11829
    }

    static func noAudioAnalysis() -> Analysis {
        Analysis(chunkCount: 0, segments: [])
    }
}
