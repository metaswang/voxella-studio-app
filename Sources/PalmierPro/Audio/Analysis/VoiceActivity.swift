import AVFoundation
#if BUNDLED_SPEECH
import AudioCommon
import SpeechVAD
#endif

/// Silero VAD speech detection; results cache as JSON sidecars keyed to the source file (AudioEnhancer's scheme).
enum VoiceActivity {
    static let cache = DiskCache(named: "AudioAnalysis")
    static let chunkDuration = Double(chunkSize) / Double(sampleRate)
    private static let sampleRate = 16_000
    private static let chunkSize = 512

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

    static func analysis(for sourceURL: URL, mediaRef: String) async throws -> Analysis {
        if let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) { return cached }
        #if BUNDLED_SPEECH
        try await pipelineGate.wait()
        defer { Task { await pipelineGate.signal() } }
        let samples: [Float]
        do {
            samples = try await AudioTrackReader.readMonoFloats(from: sourceURL, sampleRate: Double(sampleRate))
        } catch AudioTrackReader.ReadError.noAudioTrack(_) {
            return cacheNoAudioAnalysis(for: sourceURL, mediaRef: mediaRef)
        }
        let analysis = try await modelBox.analyze(samples: samples)
        cache(analysis, for: sourceURL, mediaRef: mediaRef)
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
        let analysis = try await modelBox.analyze(samples: analysisSamples)
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

    #if BUNDLED_SPEECH
    private static let modelBox = ModelBox()

    /// Silero is not thread-safe; the actor serializes model use.
    private actor ModelBox {
        private var model: SileroVADModel?
        private var modelLoadFailure: (any Error)?

        func analyze(samples: [Float]) async throws -> Analysis {
            guard !samples.isEmpty else { return Analysis(chunkCount: 0, segments: []) }
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }

            // .mlx pinned: the CoreML engine soft-fails per chunk on ANE errors, caching empty segments as truth.
            let vad: SileroVADModel
            if let model {
                vad = model
            } else {
                if let modelLoadFailure { throw modelLoadFailure }
                do {
                    vad = try await SileroVADModel.fromPretrained(engine: .mlx)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    modelLoadFailure = error
                    throw error
                }
                model = vad
            }
            let chunkCount = (samples.count + SileroVADModel.chunkSize - 1) / SileroVADModel.chunkSize
            let segments = try detectSpeech(vad: vad, samples: samples)
            return Analysis(
                chunkCount: chunkCount,
                segments: segments
            )
        }

        private func detectSpeech(vad: SileroVADModel, samples: [Float]) throws -> [Span] {
            vad.resetState()
            var probabilities: [Float] = []
            for offset in stride(from: 0, to: samples.count, by: SileroVADModel.chunkSize) {
                try Task.checkCancellation()
                guard !MLXRuntime.shouldStop else { throw CancellationError() }
                let end = min(offset + SileroVADModel.chunkSize, samples.count)
                var chunk = Array(samples[offset..<end])
                chunk.append(contentsOf: repeatElement(0, count: SileroVADModel.chunkSize - chunk.count))
                probabilities.append(vad.processChunk(chunk))
            }
            var config = VADConfig.sileroDefault
            let chunkDuration = Float(SileroVADModel.chunkSize) / Float(SileroVADModel.sampleRate)
            config.windowDuration = Float(probabilities.count) * chunkDuration
            let pipeline = VADPipeline(
                config: config, sampleRate: SileroVADModel.sampleRate, framesPerChunk: probabilities.count
            )
            return pipeline.binarize(probs: probabilities).map {
                Span(start: Double($0.startTime), end: Double($0.endTime))
            }
        }
    }

    /// Two in flight: one file decodes while the previous one runs inference in the
    /// (serial) model actor, with memory bounded to two decoded files.
    private static let pipelineGate = AsyncSemaphore(value: 2)
    #endif

    static func cachedAnalysis(for sourceURL: URL, mediaRef: String) -> Analysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(Analysis.self, from: data)
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

    private static func cache(_ analysis: Analysis, for sourceURL: URL, mediaRef: String) {
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: outputURL)
        }
    }

    static func cacheNoAudioAnalysis(for sourceURL: URL, mediaRef: String) -> Analysis {
        let analysis = Analysis(chunkCount: 0, segments: [])
        cache(analysis, for: sourceURL, mediaRef: mediaRef)
        return analysis
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_vad.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }
}
