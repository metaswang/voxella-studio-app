import Foundation

#if BUNDLED_SPEECH
import MLX
import MLXAudioVAD
#endif

enum DiarizationBackend: String, Codable, Sendable {
    case singleSpeaker
    case mlxStreamingSortformer
    case pyannoteWeSpeaker

    var title: String {
        switch self {
        case .singleSpeaker: "Single-speaker bypass"
        case .mlxStreamingSortformer: "MLX Streaming Sortformer"
        case .pyannoteWeSpeaker: "Pyannote + WeSpeaker"
        }
    }
}

enum DiarizationStage: String, Codable, Sendable {
    case preparing
    case diarizing
    case postprocessing
    case embedding
    case clustering
    case assigning
}

struct DiarizationProgress: Equatable, Sendable {
    let stage: DiarizationStage
    let completed: Int
    let total: Int
    let message: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct SpeechTimeRange: Equatable, Codable, Sendable {
    let start: Double
    let end: Double

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

struct SpeakerActivityInterval: Equatable, Codable, Sendable {
    let start: Double
    let end: Double
    let speakerID: Int
    let confidence: Double
}

struct DiarizationDiagnostics: Equatable, Codable, Sendable {
    let backend: DiarizationBackend
    let elapsedSeconds: Double
    let processedChunks: Int
    let detectedSpeakerCount: Int
    let requestedSpeakerCount: Int?
    let warnings: [String]
    var modelRevision: String? = nil
    var realTimeFactor: Double? = nil
    var peakMLXMemoryBytes: Int? = nil

    func addingWarning(_ warning: String) -> DiarizationDiagnostics {
        var copy = DiarizationDiagnostics(
            backend: backend,
            elapsedSeconds: elapsedSeconds,
            processedChunks: processedChunks,
            detectedSpeakerCount: detectedSpeakerCount,
            requestedSpeakerCount: requestedSpeakerCount,
            warnings: warnings + [warning]
        )
        copy.modelRevision = modelRevision
        copy.realTimeFactor = realTimeFactor
        copy.peakMLXMemoryBytes = peakMLXMemoryBytes
        return copy
    }
}

struct SpeakerAttribution: Equatable, Sendable {
    let speakerID: Int
    let confidence: Double
    let margin: Double
}

/// Common diarization representation used by both the neural streaming path and
/// the legacy segmentation/embedding path. Frame probabilities are retained so
/// word attribution can integrate evidence instead of assigning a speaker from
/// a single hard turn boundary. Multiple intervals may overlap.
struct SpeakerActivityTimeline: Equatable, Sendable {
    let intervals: [SpeakerActivityInterval]
    let probabilities: [Float]
    let frameDuration: Double
    let speakerCapacity: Int
    let audioDuration: Double
    let diagnostics: DiarizationDiagnostics

    var speakerCount: Int {
        Set(intervals.map(\.speakerID)).count
    }

    func speakerForWord(start rawStart: Double, end rawEnd: Double) -> Int? {
        attributionForWord(start: rawStart, end: rawEnd)?.speakerID
    }

    func attributionForWord(start rawStart: Double, end rawEnd: Double) -> SpeakerAttribution? {
        let start = min(audioDuration, max(0, rawStart))
        let end = min(audioDuration, max(start, rawEnd))
        guard end >= start else { return nil }

        if frameDuration > 0, speakerCapacity > 0, !probabilities.isEmpty {
            let frameCount = probabilities.count / speakerCapacity
            guard frameCount > 0 else { return nil }
            let first = min(frameCount - 1, max(0, Int(floor(start / frameDuration))))
            let last = min(frameCount - 1, max(first, Int(ceil(max(end, start + frameDuration) / frameDuration)) - 1))
            if first >= 0, last >= first {
                var scores = [Double](repeating: 0, count: speakerCapacity)
                for frame in first...last {
                    let frameStart = Double(frame) * frameDuration
                    let frameEnd = frameStart + frameDuration
                    let overlap = max(0, min(end, frameEnd) - max(start, frameStart))
                    let weight = overlap > 0 ? overlap : frameDuration
                    for speaker in 0..<speakerCapacity {
                        scores[speaker] += Double(probabilities[frame * speakerCapacity + speaker]) * weight
                    }
                }
                if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 {
                    let ordered = scores.sorted(by: >)
                    let total = scores.reduce(0, +)
                    let confidence = total > 0 ? scores[best] / total : 0
                    let margin = ordered.count > 1 ? ordered[0] - ordered[1] : ordered[0]
                    return SpeakerAttribution(
                        speakerID: best,
                        confidence: confidence,
                        margin: total > 0 ? margin / total : 0
                    )
                }
            }
        }

        var overlapBySpeaker: [Int: Double] = [:]
        for interval in intervals {
            let overlap = min(end, interval.end) - max(start, interval.start)
            if overlap > 0 {
                overlapBySpeaker[interval.speakerID, default: 0] += overlap * max(0.01, interval.confidence)
            }
        }
        if let best = overlapBySpeaker.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        })?.key {
            let ordered = overlapBySpeaker.values.sorted(by: >)
            let total = overlapBySpeaker.values.reduce(0, +)
            let confidence = total > 0 ? (overlapBySpeaker[best] ?? 0) / total : 0
            let margin = ordered.count > 1 ? ordered[0] - ordered[1] : ordered[0]
            return SpeakerAttribution(
                speakerID: best,
                confidence: confidence,
                margin: total > 0 ? margin / total : 0
            )
        }

        let midpoint = (start + end) / 2
        guard let nearest = intervals.min(by: { lhs, rhs in
            abs((lhs.start + lhs.end) / 2 - midpoint) < abs((rhs.start + rhs.end) / 2 - midpoint)
        }) else {
            return nil
        }
        return SpeakerAttribution(
            speakerID: nearest.speakerID,
            confidence: max(0, min(1, nearest.confidence)),
            margin: 0
        )
    }
}

struct SpeakerDiarizationPolicy: Equatable, Sendable {
    var requestedSpeakerCount: Int?
    var chunkDuration: Double = 5
    var onsetThreshold: Float = 0.55
    var offsetThreshold: Float = 0.45
    var minimumTurnDuration: Double = 0.16
    var mergeGap: Double = 0.24
    var shortTurnDuration: Double = 0.6
    var maximumShortTurnWords: Int = 2
    var softBoundaryConfidence: Double = 0.72
    var hardBoundaryConfidence: Double = 0.84

    static func standard(requestedSpeakerCount: Int?) -> Self {
        Self(requestedSpeakerCount: requestedSpeakerCount)
    }
}

enum SpeakerActivityPostprocessor {
    static func makeTimeline(
        probabilities: [Float],
        frameDuration: Double,
        speakerCapacity: Int,
        audioDuration: Double,
        speechRanges: [SpeechTimeRange],
        policy: SpeakerDiarizationPolicy,
        backend: DiarizationBackend,
        elapsedSeconds: Double,
        processedChunks: Int
    ) -> SpeakerActivityTimeline {
        guard frameDuration > 0, speakerCapacity > 0 else {
            return SpeakerActivityTimeline(
                intervals: [],
                probabilities: [],
                frameDuration: 0,
                speakerCapacity: 0,
                audioDuration: audioDuration,
                diagnostics: DiarizationDiagnostics(
                    backend: backend,
                    elapsedSeconds: elapsedSeconds,
                    processedChunks: processedChunks,
                    detectedSpeakerCount: 0,
                    requestedSpeakerCount: policy.requestedSpeakerCount,
                    warnings: []
                )
            )
        }

        let completeFrameCount = probabilities.count / speakerCapacity
        var gated = Array(probabilities.prefix(completeFrameCount * speakerCapacity))
        if !speechRanges.isEmpty {
            let sortedRanges = speechRanges.sorted { $0.start < $1.start }
            var rangeIndex = 0
            for frame in 0..<completeFrameCount {
                let midpoint = (Double(frame) + 0.5) * frameDuration
                while rangeIndex < sortedRanges.count, sortedRanges[rangeIndex].end <= midpoint {
                    rangeIndex += 1
                }
                let isSpeech = rangeIndex < sortedRanges.count && sortedRanges[rangeIndex].contains(midpoint)
                if !isSpeech {
                    for speaker in 0..<speakerCapacity {
                        gated[frame * speakerCapacity + speaker] = 0
                    }
                }
            }
        }

        var intervals: [SpeakerActivityInterval] = []
        for speaker in 0..<speakerCapacity {
            var activeStart: Int?
            var confidenceSum: Double = 0
            var confidenceFrames = 0

            func close(at endFrame: Int) {
                guard let startFrame = activeStart else { return }
                let start = Double(startFrame) * frameDuration
                let end = min(audioDuration, Double(endFrame) * frameDuration)
                if end - start >= policy.minimumTurnDuration {
                    intervals.append(SpeakerActivityInterval(
                        start: start,
                        end: end,
                        speakerID: speaker,
                        confidence: confidenceFrames > 0 ? confidenceSum / Double(confidenceFrames) : 0
                    ))
                }
                activeStart = nil
                confidenceSum = 0
                confidenceFrames = 0
            }

            for frame in 0..<completeFrameCount {
                let probability = gated[frame * speakerCapacity + speaker]
                if activeStart == nil {
                    if probability >= policy.onsetThreshold {
                        activeStart = frame
                        confidenceSum = Double(probability)
                        confidenceFrames = 1
                    }
                } else if probability < policy.offsetThreshold {
                    close(at: frame)
                } else {
                    confidenceSum += Double(probability)
                    confidenceFrames += 1
                }
            }
            close(at: completeFrameCount)
        }

        let merged = mergeIntervals(intervals, maximumGap: policy.mergeGap)
        let detected = Set(merged.map(\.speakerID)).count
        var warnings: [String] = []
        if let requested = policy.requestedSpeakerCount, requested > 0, requested != detected {
            warnings.append("Expected \(requested) speakers; the model detected \(detected).")
        }
        return SpeakerActivityTimeline(
            intervals: merged.sorted {
                $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start
            },
            probabilities: gated,
            frameDuration: frameDuration,
            speakerCapacity: speakerCapacity,
            audioDuration: audioDuration,
            diagnostics: DiarizationDiagnostics(
                backend: backend,
                elapsedSeconds: elapsedSeconds,
                processedChunks: processedChunks,
                detectedSpeakerCount: detected,
                requestedSpeakerCount: policy.requestedSpeakerCount,
                warnings: warnings
            )
        )
    }

    static func singleSpeaker(
        speechRanges: [SpeechTimeRange],
        audioDuration: Double
    ) -> SpeakerActivityTimeline {
        let intervals = speechRanges.compactMap { range -> SpeakerActivityInterval? in
            let start = min(audioDuration, max(0, range.start))
            let end = min(audioDuration, max(start, range.end))
            guard end > start else { return nil }
            return SpeakerActivityInterval(start: start, end: end, speakerID: 0, confidence: 1)
        }
        return SpeakerActivityTimeline(
            intervals: intervals,
            probabilities: [],
            frameDuration: 0,
            speakerCapacity: 1,
            audioDuration: audioDuration,
            diagnostics: DiarizationDiagnostics(
                backend: .singleSpeaker,
                elapsedSeconds: 0,
                processedChunks: 0,
                detectedSpeakerCount: intervals.isEmpty ? 0 : 1,
                requestedSpeakerCount: 1,
                warnings: []
            )
        )
    }

    private static func mergeIntervals(
        _ intervals: [SpeakerActivityInterval],
        maximumGap: Double
    ) -> [SpeakerActivityInterval] {
        var result: [SpeakerActivityInterval] = []
        let grouped = Dictionary(grouping: intervals, by: \.speakerID)
        for speaker in grouped.keys.sorted() {
            let ordered = grouped[speaker, default: []].sorted { $0.start < $1.start }
            for interval in ordered {
                guard let last = result.last, last.speakerID == speaker,
                      interval.start - last.end <= maximumGap else {
                    result.append(interval)
                    continue
                }
                let firstDuration = max(0, last.end - last.start)
                let secondDuration = max(0, interval.end - interval.start)
                let totalDuration = firstDuration + secondDuration
                let confidence = totalDuration > 0
                    ? (last.confidence * firstDuration + interval.confidence * secondDuration) / totalDuration
                    : max(last.confidence, interval.confidence)
                result[result.count - 1] = SpeakerActivityInterval(
                    start: last.start,
                    end: max(last.end, interval.end),
                    speakerID: speaker,
                    confidence: confidence
                )
            }
        }
        return result
    }
}

#if BUNDLED_SPEECH
protocol SpeakerDiarizationEngine: AnyObject {
    func diarize(
        audio: [Float],
        sampleRate: Int,
        speechRanges: [SpeechTimeRange],
        policy: SpeakerDiarizationPolicy,
        progress: @escaping @Sendable (DiarizationProgress) -> Void
    ) async throws -> SpeakerActivityTimeline
}

final class MLXStreamingSortformerEngine: SpeakerDiarizationEngine, @unchecked Sendable {
    private let model: SortformerModel
    private let modelRevision: String

    init(modelDirectory: URL, modelRevision: String) throws {
        model = try SortformerModel.fromModelDirectory(modelDirectory)
        self.modelRevision = modelRevision
    }

    func diarize(
        audio: [Float],
        sampleRate: Int,
        speechRanges: [SpeechTimeRange],
        policy: SpeakerDiarizationPolicy,
        progress: @escaping @Sendable (DiarizationProgress) -> Void
    ) async throws -> SpeakerActivityTimeline {
        guard sampleRate == model.config.processorConfig.samplingRate else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try Task.checkCancellation()
        let startedAt = ContinuousClock.now
        let audioDuration = Double(audio.count) / Double(sampleRate)
        let totalChunks = max(1, Int(ceil(audioDuration / policy.chunkDuration)))
        let frameDuration = Double(
            model.config.processorConfig.hopLength * model.config.fcEncoderConfig.subsamplingFactor
        ) / Double(model.config.processorConfig.samplingRate)
        let speakerCapacity = model.config.modulesConfig.numSpeakers
        var flatProbabilities: [Float] = []
        flatProbabilities.reserveCapacity(Int(ceil(audioDuration / frameDuration)) * speakerCapacity)

        progress(DiarizationProgress(
            stage: .preparing,
            completed: 0,
            total: totalChunks,
            message: "Preparing streaming speaker analysis…"
        ))
        let chunkSampleCount = max(1, Int((policy.chunkDuration * Double(sampleRate)).rounded()))
        var streamingState = model.initStreamingState()
        var processedChunks = 0
        var chunkStart = 0
        while chunkStart < audio.count {
            try Task.checkCancellation()
            let chunkEnd = min(audio.count, chunkStart + chunkSampleCount)
            let chunk = MLXArray(Array(audio[chunkStart..<chunkEnd]))
            let (output, nextState) = try await model.feed(
                chunk: chunk,
                state: streamingState,
                sampleRate: sampleRate,
                threshold: policy.onsetThreshold,
                minDuration: 0,
                mergeGap: 0
            )
            streamingState = nextState
            try Task.checkCancellation()
            if let speakerProbabilities = output.speakerProbs {
                eval(speakerProbabilities)
                flatProbabilities.append(contentsOf: speakerProbabilities.asArray(Float.self))
            }
            processedChunks += 1
            progress(DiarizationProgress(
                stage: .diarizing,
                completed: min(processedChunks, totalChunks),
                total: totalChunks,
                message: "Diarizing chunk \(processedChunks) of \(totalChunks)…"
            ))
            chunkStart = chunkEnd
        }
        try Task.checkCancellation()
        progress(DiarizationProgress(
            stage: .postprocessing,
            completed: totalChunks,
            total: totalChunks,
            message: "Stitching speaker activity…"
        ))
        let elapsed = startedAt.duration(to: .now)
        let components = elapsed.components
        let elapsedSeconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let timeline = SpeakerActivityPostprocessor.makeTimeline(
            probabilities: flatProbabilities,
            frameDuration: frameDuration,
            speakerCapacity: speakerCapacity,
            audioDuration: audioDuration,
            speechRanges: speechRanges,
            policy: policy,
            backend: .mlxStreamingSortformer,
            elapsedSeconds: elapsedSeconds,
            processedChunks: processedChunks
        )
        var diagnostics = timeline.diagnostics
        diagnostics.modelRevision = modelRevision
        diagnostics.realTimeFactor = audioDuration > 0 ? elapsedSeconds / audioDuration : nil
        diagnostics.peakMLXMemoryBytes = Memory.peakMemory
        return SpeakerActivityTimeline(
            intervals: timeline.intervals,
            probabilities: timeline.probabilities,
            frameDuration: timeline.frameDuration,
            speakerCapacity: timeline.speakerCapacity,
            audioDuration: timeline.audioDuration,
            diagnostics: diagnostics
        )
    }
}
#endif
