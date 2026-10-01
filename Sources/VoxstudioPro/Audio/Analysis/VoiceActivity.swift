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
        let analysis = Analysis(
            chunkCount: chunkCount(for: analysisSamples.count),
            segments: analysisResult.segments.map {
                Span(start: Double($0.startTime), end: Double($0.endTime))
            }
        )
        guard !analysis.segments.isEmpty else { return samples }

        let scale = Double(sampleRate) / Double(Self.sampleRate)
        let maximumSilenceFrames = Int((maximumSilenceSeconds * Double(sampleRate)).rounded(.down))
        let maximumLeadingFrames = Int((0.08 * Double(sampleRate)).rounded(.down))
        let paddingFrames = Int((0.04 * Double(sampleRate)).rounded(.down))
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var previousEnd = 0

        for (index, span) in analysis.segments.enumerated() {
            let rawStart: Int = max(0, Int((span.start * scale).rounded(.down)))
            let rawEnd: Int = min(samples.count, Int((span.end * scale).rounded(.up)))
            guard rawEnd > rawStart else { continue }

            let startFrame: Int = max(0, rawStart - paddingFrames)
            let endFrame: Int = min(samples.count, rawEnd + paddingFrames)
            if index == 0 {
                let leadingEnd: Int = min(startFrame, maximumLeadingFrames)
                output.append(contentsOf: samples[0..<leadingEnd])
                output.append(contentsOf: samples[startFrame..<endFrame])
            } else {
                let gapFrames: Int = max(0, startFrame - previousEnd)
                let keptGapFrames: Int = min(gapFrames, maximumSilenceFrames)
                let leadingGapFrames: Int = keptGapFrames / 2
                let trailingGapFrames: Int = keptGapFrames - leadingGapFrames
                if leadingGapFrames > 0 {
                    output.append(contentsOf: samples[
                        previousEnd..<(previousEnd + leadingGapFrames)
                    ])
                }
                if trailingGapFrames > 0 {
                    output.append(contentsOf: samples[
                        (startFrame - trailingGapFrames)..<startFrame
                    ])
                }
                output.append(contentsOf: samples[startFrame..<endFrame])
            }
            previousEnd = endFrame
        }

        let trailingEnd = min(samples.count, previousEnd + maximumLeadingFrames)
        if trailingEnd > previousEnd {
            output.append(contentsOf: samples[previousEnd..<trailingEnd])
        }
        let minimumPreservedFrames = Int(Double(samples.count) * 0.6)
        guard output.count >= minimumPreservedFrames else { return samples }
        return output.isEmpty ? samples : output
        #else
        throw MLXRuntime.Unavailable()
        #endif
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
