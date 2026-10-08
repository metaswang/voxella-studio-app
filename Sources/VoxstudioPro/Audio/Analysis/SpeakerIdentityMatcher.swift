import Foundation

/// Accept rule for naming an anonymous speaker channel with a known person.
/// Values come from `calibrate(trials:targetFalseNameRate:)` on a validation
/// set that is independent of enrollment samples.
struct SpeakerMatchCalibration: Codable, Equatable, Sendable {
    /// Minimum cosine between channel and person voiceprints.
    var acceptThreshold: Double
    /// Minimum gap between the best and second-best candidate.
    var minimumMargin: Double
    /// Minimum clean single-speaker evidence for the channel, in seconds.
    var minimumEvidence: Double
    var version: String

    /// Provisional until a calibration run replaces it; deliberately stricter
    /// than the former fixed 0.45 floor so uncertain voices stay anonymous.
    static let current = SpeakerMatchCalibration(
        acceptThreshold: 0.62,
        minimumMargin: 0.10,
        minimumEvidence: 2.0,
        version: "provisional-2026-10-08"
    )

    struct Trial: Equatable, Sendable {
        var bestScore: Double
        var margin: Double
        /// The best candidate is the true person.
        var isCorrect: Bool
        /// The true person is enrolled among the candidates.
        var personEnrolled: Bool
    }

    struct Report: Equatable, Sendable {
        var calibration: SpeakerMatchCalibration
        var falseNameRate: Double
        /// Upper bound of the 95% Wilson interval of the false-name rate.
        var falseNameRateUpper: Double
        var recall: Double
        var recallInterval: ClosedRange<Double>
        var namedCount: Int
        var trialCount: Int
    }

    /// Chooses the most permissive (threshold, margin) whose observed
    /// false-name rate stays at or below `targetFalseNameRate`, preferring
    /// recall. False names count wrong-person and not-enrolled acceptances.
    static func calibrate(
        trials: [Trial],
        targetFalseNameRate: Double = 0.01,
        minimumEvidence: Double = 2.0,
        version: String
    ) -> Report? {
        guard !trials.isEmpty else { return nil }
        let thresholds = stride(from: 0.30, through: 0.90, by: 0.01).map { $0 }
        let margins = stride(from: 0.0, through: 0.30, by: 0.02).map { $0 }
        let enrolled = trials.filter(\.personEnrolled).count
        var best: Report?
        for threshold in thresholds {
            for margin in margins {
                let named = trials.filter { $0.bestScore >= threshold && $0.margin >= margin }
                let falseNames = named.filter { !$0.isCorrect }.count
                let rate = named.isEmpty ? 0 : Double(falseNames) / Double(named.count)
                guard rate <= targetFalseNameRate else { continue }
                let correct = named.count - falseNames
                let recall = enrolled == 0 ? 0 : Double(correct) / Double(enrolled)
                let report = Report(
                    calibration: SpeakerMatchCalibration(
                        acceptThreshold: threshold, minimumMargin: margin,
                        minimumEvidence: minimumEvidence, version: version
                    ),
                    falseNameRate: rate,
                    falseNameRateUpper: wilson(successes: falseNames, total: named.count).upperBound,
                    recall: recall,
                    recallInterval: wilson(successes: correct, total: enrolled),
                    namedCount: named.count,
                    trialCount: trials.count
                )
                if best.map({ report.recall > $0.recall }) ?? true { best = report }
            }
        }
        return best
    }

    static func wilson(successes: Int, total: Int, z: Double = 1.96) -> ClosedRange<Double> {
        guard total > 0 else { return 0...1 }
        let n = Double(total)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let spread = z * ((p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()) / denominator
        let lower = successes == 0 ? 0 : max(0, center - spread)
        let upper = successes == total ? 1 : min(1, center + spread)
        return min(lower, p)...max(upper, p)
    }
}

enum SpeakerMatchStatus: String, Codable, Sendable {
    /// Named automatically from a candidate person.
    case matched
    /// Linked or named by the user; never overwritten by automatic matching.
    case manual
    /// No candidate is close enough.
    case unknown
    /// Two candidates are too close to tell apart.
    case ambiguous
    /// Not enough clean single-speaker speech to compare.
    case insufficientEvidence
    /// The channel's own segments disagree; it may contain more than one person.
    case needsReview
    /// The best person is already assigned to a channel speaking at the same time.
    case conflict
}

struct SpeakerChannelProfile: Equatable, Sendable {
    var label: String
    var voiceprint: SpeakerVoiceprint?
    /// Labels with simultaneous speech; they cannot be the same person.
    var overlapsWith: Set<String>
}

struct SpeakerMatchCandidate: Equatable, Sendable {
    var personID: UUID
    var name: String
    var voiceprint: SpeakerVoiceprint
}

struct SpeakerMatchDecision: Codable, Equatable, Sendable {
    var label: String
    var personID: UUID?
    var nameSnapshot: String?
    var status: SpeakerMatchStatus
    var score: Double?
    var margin: Double?
}

enum SpeakerIdentityMatcher {
    static func match(
        channels: [SpeakerChannelProfile],
        candidates: [SpeakerMatchCandidate],
        calibration: SpeakerMatchCalibration = .current
    ) -> [SpeakerMatchDecision] {
        struct Proposal {
            var label: String
            var candidate: SpeakerMatchCandidate
            var score: Double
            var margin: Double
        }
        var decisions: [String: SpeakerMatchDecision] = [:]
        var proposals: [Proposal] = []
        for channel in channels {
            guard let voiceprint = channel.voiceprint,
                  voiceprint.effectiveDuration >= calibration.minimumEvidence else {
                decisions[channel.label] = .init(label: channel.label, status: .insufficientEvidence)
                continue
            }
            let scored = candidates
                .filter { $0.voiceprint.version == voiceprint.version }
                .map { ($0, Double(SpeakerVoiceprintPolicy.cosine(voiceprint.vector, $0.voiceprint.vector))) }
                .sorted { $0.1 > $1.1 }
            guard let best = scored.first else {
                decisions[channel.label] = .init(label: channel.label, status: .unknown)
                continue
            }
            let margin = best.1 - (scored.dropFirst().first?.1 ?? -1)
            let base = SpeakerMatchDecision(label: channel.label, status: .unknown, score: best.1, margin: margin)
            if voiceprint.quality == .needsReview {
                decisions[channel.label] = with(base, status: .needsReview)
            } else if best.1 < calibration.acceptThreshold {
                decisions[channel.label] = base
            } else if margin < calibration.minimumMargin {
                decisions[channel.label] = with(base, status: .ambiguous)
            } else {
                decisions[channel.label] = base
                proposals.append(Proposal(label: channel.label, candidate: best.0, score: best.1, margin: margin))
            }
        }

        let overlaps = Dictionary(uniqueKeysWithValues: channels.map { ($0.label, $0.overlapsWith) })
        var assigned: [String: UUID] = [:]
        for proposal in proposals.sorted(by: { $0.score == $1.score ? $0.label < $1.label : $0.score > $1.score }) {
            // Non-overlapping channels may share a person; simultaneous ones may not.
            let clashes = assigned.contains { label, personID in
                personID == proposal.candidate.personID
                    && ((overlaps[proposal.label]?.contains(label) ?? false)
                        || (overlaps[label]?.contains(proposal.label) ?? false))
            }
            if clashes {
                decisions[proposal.label]?.status = .conflict
                continue
            }
            assigned[proposal.label] = proposal.candidate.personID
            decisions[proposal.label] = SpeakerMatchDecision(
                label: proposal.label,
                personID: proposal.candidate.personID,
                nameSnapshot: proposal.candidate.name,
                status: .matched,
                score: proposal.score,
                margin: proposal.margin
            )
        }
        return channels.compactMap { decisions[$0.label] }
    }

    private static func with(_ decision: SpeakerMatchDecision, status: SpeakerMatchStatus) -> SpeakerMatchDecision {
        var copy = decision
        copy.status = status
        return copy
    }
}
