import Foundation

#if BUNDLED_SPEECH
import MLX
import Nemotron3Diarization
#endif

enum DiarizationBackend: String, Codable, Sendable {
    case disabled
    case singleSpeaker
    case unavailable
    case nemotron3
    /// Results produced by retired engines. Historical transcripts stay readable;
    /// reprocessing uses Nemotron 3.
    case legacyModel

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .legacyModel
    }

    var title: String {
        switch self {
        case .disabled: "Speaker identification disabled"
        case .singleSpeaker: "Single-speaker bypass"
        case .unavailable: "Speaker labels unavailable"
        case .nemotron3, .legacyModel: "Speaker identification"
        }
    }

    /// Whether the timeline carries model speaker activity.
    var producesSpeakerActivity: Bool {
        self == .nemotron3 || self == .legacyModel
    }
}

enum DiarizationStage: String, Sendable {
    case preparing
    case diarizing
    case postprocessing
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
    var speechCoverage: Double? = nil
    var processedAudioDuration: Double? = nil
    var chunkDuration: Double? = nil
    var fifoMax: Int? = nil
    var spkcacheMax: Int? = nil
    /// Clean single-speaker evidence per final label, used for identity matching.
    var speakerEvidence: [SpeakerChannelEvidence]? = nil

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
        copy.speechCoverage = speechCoverage
        copy.processedAudioDuration = processedAudioDuration
        copy.chunkDuration = chunkDuration
        copy.fifoMax = fifoMax
        copy.spkcacheMax = spkcacheMax
        copy.speakerEvidence = speakerEvidence
        return copy
    }
}

struct SpeakerAttribution: Equatable, Sendable {
    let speakerID: Int
    let confidence: Double
    let margin: Double
    /// Mean winning probability over actual audio support, independent of the ratio.
    var absoluteProbability: Double = 0
    var supportDuration: Double = 0
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
        guard rawStart.isFinite, rawEnd.isFinite, audioDuration.isFinite,
              rawEnd > rawStart else { return nil }
        let start = min(audioDuration, max(0, rawStart))
        let end = min(audioDuration, max(start, rawEnd))
        guard end > start else { return nil }

        if frameDuration > 0, speakerCapacity > 0, !probabilities.isEmpty {
            let frameCount = probabilities.count / speakerCapacity
            guard frameCount > 0 else { return nil }
            let first = min(frameCount - 1, max(0, Int(floor(start / frameDuration))))
            let last = min(frameCount - 1, max(first, Int(ceil(end / frameDuration)) - 1))
            if first >= 0, last >= first {
                var scores = [Double](repeating: 0, count: speakerCapacity)
                var support = 0.0
                for frame in first...last {
                    let frameStart = Double(frame) * frameDuration
                    let frameEnd = frameStart + frameDuration
                    let overlap = max(0, min(end, frameEnd) - max(start, frameStart))
                    guard overlap > 0 else { continue }
                    support += overlap
                    for speaker in 0..<speakerCapacity {
                        let probability = Double(probabilities[frame * speakerCapacity + speaker])
                        if probability.isFinite {
                            scores[speaker] += min(1, max(0, probability)) * overlap
                        }
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
                        margin: total > 0 ? margin / total : 0,
                        absoluteProbability: support > 0 ? scores[best] / support : 0,
                        supportDuration: support
                    )
                }
            }
            // A present probability track is authoritative, including silent frames.
            return nil
        }

        var overlapBySpeaker: [Int: Double] = [:]
        for interval in intervals {
            guard interval.start.isFinite, interval.end.isFinite else { continue }
            let overlap = min(end, interval.end) - max(start, interval.start)
            if overlap > 0, interval.confidence.isFinite, interval.confidence > 0 {
                overlapBySpeaker[interval.speakerID, default: 0] += overlap * min(1, interval.confidence)
            }
        }
        if let best = overlapBySpeaker.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        })?.key {
            let ordered = overlapBySpeaker.values.sorted(by: >)
            let total = overlapBySpeaker.values.reduce(0, +)
            let confidence = total > 0 ? (overlapBySpeaker[best] ?? 0) / total : 0
            let margin = ordered.count > 1 ? ordered[0] - ordered[1] : ordered[0]
            var support = 0.0
            var cursor = start
            for interval in intervals.filter({ $0.speakerID == best && $0.confidence > 0
                && $0.start.isFinite && $0.end.isFinite }).sorted(by: { $0.start < $1.start }) {
                let upper = min(end, interval.end)
                support += max(0, upper - max(cursor, interval.start))
                cursor = max(cursor, upper)
            }
            return SpeakerAttribution(
                speakerID: best,
                confidence: confidence,
                margin: total > 0 ? margin / total : 0,
                absoluteProbability: min(1, (overlapBySpeaker[best] ?? 0) / (end - start)),
                supportDuration: support
            )
        }
        return nil
    }
}

struct SpeakerDiarizationPolicy: Equatable, Sendable {
    var requestedSpeakerCount: Int?
    /// Initial Nemotron 3 activity threshold (the source postprocessor default).
    var onsetThreshold: Float = 0.5
    var offsetThreshold: Float = 0.5
    var minimumTurnDuration: Double = 0.16
    var mergeGap: Double = 0.24
    var shortTurnDuration: Double = 0.6
    /// Minimum same-speaker run that can promote a soft change to a hard split.
    /// Longer than `shortTurnDuration` so brief replies stay soft.
    var sustainedTurnDuration: Double = 1
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
            warnings.append("Expected \(requested) speakers; \(detected) were detected.")
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

/// Offline Nemotron 3 diarization: eight anonymous arrival-order channels at
/// 10 ms. Runs inside the caller's MLX inference lease; state resets per call.
final class Nemotron3DiarizationEngine: SpeakerDiarizationEngine, @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer
    private let modelRevision: String

    init(modelDirectory: URL, modelRevision: String) throws {
        diarizer = try Nemotron3Diarizer(modelDirectory: modelDirectory)
        self.modelRevision = modelRevision
    }

    @concurrent
    func diarize(
        audio: [Float],
        sampleRate: Int,
        speechRanges: [SpeechTimeRange],
        policy: SpeakerDiarizationPolicy,
        progress: @escaping @Sendable (DiarizationProgress) -> Void
    ) async throws -> SpeakerActivityTimeline {
        let geometry = diarizer.geometry
        guard sampleRate == geometry.sampleRate else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try Task.checkCancellation()
        let startedAt = ContinuousClock.now
        let audioDuration = Double(audio.count) / Double(sampleRate)
        // Silence is removed without reordering speech, which keeps the cache
        // fed with speech in original time order.
        let pack = DiarizationSpeechPacker.pack(
            audio: audio,
            sampleRate: sampleRate,
            speechRanges: speechRanges,
            audioDuration: audioDuration
        )
        let totalChunks = max(1, geometry.chunkCount(sampleCount: pack.samples.count))
        Log.transcription.notice(
            "Diarization start backend=\(DiarizationBackend.nemotron3.rawValue) "
                + "revision=\(modelRevision) audio=\(Self.formatSeconds(audioDuration))s "
                + "speech=\(Self.formatSeconds(pack.speechDuration))s "
                + "coverage=\(Self.formatCoverage(pack.coverage)) "
                + "processed=\(Self.formatSeconds(pack.processedAudioDuration))s "
                + "chunk=\(Self.formatSeconds(geometry.chunkDuration))s "
                + "right=\(Self.formatSeconds(geometry.rightContextDuration))s identity=\(pack.usedIdentity)"
        )
        progress(DiarizationProgress(
            stage: .preparing,
            completed: 0,
            total: totalChunks,
            message: "Preparing speaker analysis…"
        ))

        var chunkStartedAt = ContinuousClock.now
        let concatProbabilities = try diarizer.activityProbabilities(audio: pack.samples) { completed, total in
            try Task.checkCancellation()
            let chunkElapsed = Self.seconds(from: chunkStartedAt.duration(to: .now))
            Log.transcription.notice(
                "Diarization chunk \(completed)/\(total) elapsed=\(Self.formatSeconds(chunkElapsed))s"
            )
            progress(DiarizationProgress(
                stage: .diarizing,
                completed: min(completed, total),
                total: max(total, 1),
                message: "Diarizing chunk \(completed) of \(total)…"
            ))
            chunkStartedAt = ContinuousClock.now
        }
        try Task.checkCancellation()
        progress(DiarizationProgress(
            stage: .postprocessing,
            completed: totalChunks,
            total: totalChunks,
            message: "Stitching speaker activity…"
        ))
        let probabilities = DiarizationSpeechPacker.scatterProbabilities(
            concatProbabilities: concatProbabilities,
            speakerCapacity: diarizer.speakerCapacity,
            frameDuration: diarizer.frameDuration,
            pack: pack,
            audioDuration: audioDuration
        )
        let elapsedSeconds = Self.seconds(from: startedAt.duration(to: .now))
        let timeline = SpeakerActivityPostprocessor.makeTimeline(
            probabilities: probabilities,
            frameDuration: diarizer.frameDuration,
            speakerCapacity: diarizer.speakerCapacity,
            audioDuration: audioDuration,
            speechRanges: speechRanges,
            policy: policy,
            backend: .nemotron3,
            elapsedSeconds: elapsedSeconds,
            processedChunks: totalChunks
        )
        var diagnostics = timeline.diagnostics
        diagnostics.modelRevision = modelRevision
        diagnostics.realTimeFactor = audioDuration > 0 ? elapsedSeconds / audioDuration : nil
        diagnostics.peakMLXMemoryBytes = Memory.peakMemory
        diagnostics.speechCoverage = pack.coverage
        diagnostics.processedAudioDuration = pack.processedAudioDuration
        diagnostics.chunkDuration = geometry.chunkDuration
        diagnostics.fifoMax = geometry.fifoLength
        diagnostics.spkcacheMax = geometry.speakerCacheLength
        Log.transcription.notice(
            "Diarization completed elapsed=\(Self.formatSeconds(elapsedSeconds))s "
                + "rtf=\(Self.formatRTF(diagnostics.realTimeFactor)) "
                + "processedAudio=\(Self.formatSeconds(pack.processedAudioDuration))s "
                + "chunks=\(totalChunks) peakMLX=\(Memory.peakMemory) "
                + "detected=\(timeline.diagnostics.detectedSpeakerCount)"
        )
        return SpeakerActivityTimeline(
            intervals: timeline.intervals,
            probabilities: timeline.probabilities,
            frameDuration: timeline.frameDuration,
            speakerCapacity: timeline.speakerCapacity,
            audioDuration: timeline.audioDuration,
            diagnostics: diagnostics
        )
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatCoverage(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func formatRTF(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.4f", value)
    }
}
#endif
