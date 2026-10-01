import Foundation

enum SpeechAdmissionIntent: String, Codable, Sendable {
    case standard
    case lowLevelRecovery
}

enum SpeechAdmissionRejectionReason: String, Codable, Sendable {
    case noOriginalVADAnchor
    case belowMinimumDuration
    case insufficientOriginalEnergy
    case rescuedWithoutOriginalAnchor
    case effectivelySilent
}

struct SpeechAdmissionPolicy: Codable, Equatable, Sendable {
    let version: String
    let sampleRate: Int
    let frameSize: Int
    let entryThreshold: Float
    let exitThreshold: Float
    let minimumSpeechDuration: Double
    let minimumSilenceDuration: Double
    let padding: Double
    let rescueAnchorThreshold: Float
    let minimumSignalAboveNoiseDB: Double

    static let standard = SpeechAdmissionPolicy(
        version: "silero-coreml-session-v1",
        sampleRate: LocalSpeechVAD.sampleRate,
        frameSize: LocalSpeechVAD.chunkSize,
        entryThreshold: 0.60,
        exitThreshold: 0.45,
        minimumSpeechDuration: 0.50,
        minimumSilenceDuration: 0.50,
        padding: AudioBoundarySilenceTrimmer.boundaryPadding,
        rescueAnchorThreshold: 0.15,
        minimumSignalAboveNoiseDB: 3.0
    )
}

struct SpeechAdmissionInterval: Codable, Equatable, Sendable {
    let range: ASRSpeechRange
    let originalMean: Float
    let originalPeak: Float
    let originalActiveFrameRatio: Double
    let originalRMSDBFS: Double
    let signalAboveNoiseDB: Double
    let source: String
}

struct SpeechAdmissionDiagnostics: Codable, Equatable, Sendable {
    let policyVersion: String
    let modelRevision: String
    let originalFrameCount: Int
    let originalCandidateCount: Int
    let acceptedCount: Int
    let acceptedSeconds: Double
    let rejectedSeconds: Double
    let originalProbabilityP10: Float
    let originalProbabilityP50: Float
    let originalProbabilityP90: Float
    let rejectionReasons: [String: Double]
    let intervals: [SpeechAdmissionInterval]
}

struct SpeechAdmissionDecision: Sendable {
    let acceptedRanges: [ASRSpeechRange]
    let diagnostics: SpeechAdmissionDiagnostics

    var hasAcceptedSpeech: Bool { !acceptedRanges.isEmpty }
}

enum SpeechAdmission {
    static func tightenEdges(
        _ ranges: [ASRSpeechRange],
        samples: [Float],
        policy: SpeechAdmissionPolicy = .standard,
        padding: Double? = nil
    ) -> [ASRSpeechRange] {
        let duration = Double(samples.count) / Double(max(1, policy.sampleRate))
        let tightened = ranges.compactMap {
            tighten($0, samples: samples, policy: policy, padding: padding ?? policy.padding)
        }
        return merge(tightened, duration: duration)
    }

    static func decide(
        samples: [Float],
        originalProbabilities: [Float],
        originalSegments: [SpeechRegion]? = nil,
        rescuedProbabilities: [Float]? = nil,
        modelRevision: String,
        intent: SpeechAdmissionIntent = .standard,
        policy: SpeechAdmissionPolicy = .standard
    ) -> SpeechAdmissionDecision {
        let duration = Double(samples.count) / Double(max(1, policy.sampleRate))
        let fallback = SpeechAdmissionDiagnostics(
            policyVersion: policy.version,
            modelRevision: modelRevision,
            originalFrameCount: originalProbabilities.count,
            originalCandidateCount: 0,
            acceptedCount: 0,
            acceptedSeconds: 0,
            rejectedSeconds: max(0, duration),
            originalProbabilityP10: 0,
            originalProbabilityP50: 0,
            originalProbabilityP90: 0,
            rejectionReasons: [SpeechAdmissionRejectionReason.noOriginalVADAnchor.rawValue: max(0, duration)],
            intervals: []
        )

        guard !samples.isEmpty, policy.sampleRate > 0, policy.frameSize > 0 else {
            return SpeechAdmissionDecision(acceptedRanges: [], diagnostics: fallback)
        }

        let probabilities = originalProbabilities.map { value in
            value.isFinite ? min(1, max(0, value)) : 0
        }
        let originalRanges: [ASRSpeechRange]
        if let originalSegments {
            originalRanges = originalSegments.compactMap { segment in
                let start = Double(segment.startTime)
                let end = Double(segment.endTime)
                guard start.isFinite, end.isFinite,
                      end > start,
                      end - start >= policy.minimumSpeechDuration else {
                    return nil
                }
                return ASRSpeechRange(start: start, end: end)
            }
        } else {
            originalRanges = SpeechProbabilitySegmenter.sampleRanges(
                probabilities: probabilities,
                sampleCount: samples.count,
                sampleRate: policy.sampleRate,
                frameSize: policy.frameSize,
                entryThreshold: policy.entryThreshold,
                exitThreshold: policy.exitThreshold,
                minimumSpeechDuration: policy.minimumSpeechDuration,
                minimumSilenceDuration: policy.minimumSilenceDuration,
                padding: 0
            )
        }

        let noiseFloor = noiseFloorDBFS(samples: samples, policy: policy)
        var accepted: [ASRSpeechRange] = []
        var intervals: [SpeechAdmissionInterval] = []
        var rejectionReasons: [SpeechAdmissionRejectionReason: Double] = [:]

        for range in originalRanges {
            let frames = frameIndices(
                for: range,
                probabilitiesCount: probabilities.count,
                policy: policy
            )
            let metrics = intervalMetrics(
                samples: samples,
                probabilities: probabilities,
                frames: frames,
                range: range,
                policy: policy,
                noiseFloorDBFS: noiseFloor
            )
            let source = "original"
            if metrics.signalAboveNoiseDB >= policy.minimumSignalAboveNoiseDB
                || metrics.originalMean >= policy.entryThreshold {
                guard let tightened = tighten(range, samples: samples, policy: policy) else {
                    rejectionReasons[.effectivelySilent, default: 0] += range.duration
                    continue
                }
                accepted.append(tightened)
                intervals.append(
                    SpeechAdmissionInterval(
                        range: tightened,
                        originalMean: metrics.originalMean,
                        originalPeak: metrics.originalPeak,
                        originalActiveFrameRatio: metrics.activeFrameRatio,
                        originalRMSDBFS: metrics.rmsDBFS,
                        signalAboveNoiseDB: metrics.signalAboveNoiseDB,
                        source: source
                    )
                )
            } else {
                rejectionReasons[.insufficientOriginalEnergy, default: 0] += range.duration
            }
        }

        if intent == .lowLevelRecovery, accepted.isEmpty, let rescuedProbabilities {
            let rescued = rescuedProbabilities.map { value in
                value.isFinite ? min(1, max(0, value)) : 0
            }
            let rescuedRanges = SpeechProbabilitySegmenter.sampleRanges(
                probabilities: rescued,
                sampleCount: samples.count,
                sampleRate: policy.sampleRate,
                frameSize: policy.frameSize,
                entryThreshold: policy.entryThreshold,
                exitThreshold: policy.exitThreshold,
                minimumSpeechDuration: policy.minimumSpeechDuration,
                minimumSilenceDuration: policy.minimumSilenceDuration,
                padding: 0
            )
            for range in rescuedRanges {
                let frames = frameIndices(
                    for: range,
                    probabilitiesCount: probabilities.count,
                    policy: policy
                )
                let hasOriginalAnchor = frames.contains {
                    probabilities.indices.contains($0)
                        && probabilities[$0] >= policy.rescueAnchorThreshold
                }
                let metrics = intervalMetrics(
                    samples: samples,
                    probabilities: probabilities,
                    frames: frames,
                    range: range,
                    policy: policy,
                    noiseFloorDBFS: noiseFloor
                )
                guard hasOriginalAnchor else {
                    rejectionReasons[.rescuedWithoutOriginalAnchor, default: 0] += range.duration
                    continue
                }
                guard metrics.signalAboveNoiseDB >= policy.minimumSignalAboveNoiseDB else {
                    rejectionReasons[.insufficientOriginalEnergy, default: 0] += range.duration
                    continue
                }
                guard let tightened = tighten(range, samples: samples, policy: policy) else {
                    rejectionReasons[.effectivelySilent, default: 0] += range.duration
                    continue
                }
                accepted.append(tightened)
                intervals.append(
                    SpeechAdmissionInterval(
                        range: tightened,
                        originalMean: metrics.originalMean,
                        originalPeak: metrics.originalPeak,
                        originalActiveFrameRatio: metrics.activeFrameRatio,
                        originalRMSDBFS: metrics.rmsDBFS,
                        signalAboveNoiseDB: metrics.signalAboveNoiseDB,
                        source: "rescued"
                    )
                )
            }
        } else if originalRanges.isEmpty, rescuedProbabilities != nil {
            let rescueDuration = duration
            rejectionReasons[.noOriginalVADAnchor, default: 0] += rescueDuration
        }

        let normalized = merge(accepted, duration: duration)
        let acceptedSeconds = normalized.reduce(0) { $0 + $1.duration }
        let rejectedSeconds = max(0, duration - acceptedSeconds)
        let diagnostics = SpeechAdmissionDiagnostics(
            policyVersion: policy.version,
            modelRevision: modelRevision,
            originalFrameCount: probabilities.count,
            originalCandidateCount: originalRanges.count,
            acceptedCount: normalized.count,
            acceptedSeconds: acceptedSeconds,
            rejectedSeconds: rejectedSeconds,
            originalProbabilityP10: percentile(probabilities, fraction: 0.10),
            originalProbabilityP50: percentile(probabilities, fraction: 0.50),
            originalProbabilityP90: percentile(probabilities, fraction: 0.90),
            rejectionReasons: rejectionReasons.reduce(into: [:]) { result, entry in
                result[entry.key.rawValue] = entry.value
            },
            intervals: intervals
        )
        return SpeechAdmissionDecision(acceptedRanges: normalized, diagnostics: diagnostics)
    }

    private struct IntervalMetrics {
        let originalMean: Float
        let originalPeak: Float
        let activeFrameRatio: Double
        let rmsDBFS: Double
        let signalAboveNoiseDB: Double
    }

    private static func intervalMetrics(
        samples: [Float],
        probabilities: [Float],
        frames: [Int],
        range: ASRSpeechRange,
        policy: SpeechAdmissionPolicy,
        noiseFloorDBFS: Double
    ) -> IntervalMetrics {
        let values = frames.compactMap { probabilities.indices.contains($0) ? probabilities[$0] : nil }
        let start = min(samples.count, max(0, Int((range.start * Double(policy.sampleRate)).rounded(.down))))
        let end = min(samples.count, max(start, Int((range.end * Double(policy.sampleRate)).rounded(.up))))
        let samplesInRange = start < end ? Array(samples[start..<end]) : []
        let rms = ASRAudioPreprocessor.metrics(for: samplesInRange)
        return IntervalMetrics(
            originalMean: values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count),
            originalPeak: values.max() ?? 0,
            activeFrameRatio: frames.isEmpty ? 0 : Double(values.filter { $0 >= policy.exitThreshold }.count) / Double(frames.count),
            rmsDBFS: rms.rmsDBFS,
            signalAboveNoiseDB: rms.rmsDBFS - noiseFloorDBFS
        )
    }

    private static func frameIndices(
        for range: ASRSpeechRange,
        probabilitiesCount: Int,
        policy: SpeechAdmissionPolicy
    ) -> [Int] {
        guard probabilitiesCount > 0 else { return [] }
        let first = max(0, Int((range.start * Double(policy.sampleRate) / Double(policy.frameSize)).rounded(.down)))
        let last = min(
            probabilitiesCount - 1,
            max(first, Int((range.end * Double(policy.sampleRate) / Double(policy.frameSize)).rounded(.up)) - 1)
        )
        guard last >= first else { return [] }
        return Array(first...last)
    }

    private static func noiseFloorDBFS(samples: [Float], policy: SpeechAdmissionPolicy) -> Double {
        let count = LocalSpeechVAD.chunkCount(for: samples.count)
        guard count > 0 else { return -.infinity }
        let levels = (0..<count).map { index in
            let start = index * policy.frameSize
            let end = min(samples.count, start + policy.frameSize)
            return ASRAudioPreprocessor.metrics(for: Array(samples[start..<end])).rmsDBFS
        }.filter(\.isFinite).sorted()
        guard !levels.isEmpty else { return -.infinity }
        let quietCount = max(1, Int(ceil(Double(levels.count) * 0.2)))
        return levels.prefix(quietCount).reduce(0, +) / Double(quietCount)
    }

    private static func tighten(
        _ range: ASRSpeechRange,
        samples: [Float],
        policy: SpeechAdmissionPolicy,
        padding: Double? = nil
    ) -> ASRSpeechRange? {
        let rate = Double(policy.sampleRate)
        guard rate > 0, range.end > range.start else { return nil }
        let start = min(samples.count, max(0, Int((range.start * rate).rounded(.down))))
        let end = min(samples.count, max(start, Int((range.end * rate).rounded(.up))))
        guard let tightened = AudioBoundarySilenceTrimmer.tighten(
            samples: samples,
            sampleRate: rate,
            candidate: start..<end,
            padding: padding ?? policy.padding
        ) else {
            return nil
        }
        let tightenedRange = ASRSpeechRange(
            start: Double(tightened.lowerBound) / rate,
            end: Double(tightened.upperBound) / rate
        )
        return tightenedRange.duration > 0 ? tightenedRange : nil
    }

    private static func merge(_ ranges: [ASRSpeechRange], duration: Double) -> [ASRSpeechRange] {
        var result: [ASRSpeechRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            let start = min(duration, max(0, range.start))
            let end = min(duration, max(start, range.end))
            guard end > start else { continue }
            if let last = result.last, start <= last.end {
                result[result.count - 1] = ASRSpeechRange(start: last.start, end: max(last.end, end))
            } else {
                result.append(ASRSpeechRange(start: start, end: end))
            }
        }
        return result
    }

    private static func percentile(_ values: [Float], fraction: Double) -> Float {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
