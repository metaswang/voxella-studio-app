import Foundation

struct ASRLanguageVotePolicy: Equatable, Sendable {
    var minimumAnchorConfidence: Double = 0.75
    var minimumMargin: Double = 0.15
    var minimumPooledConfidence: Double = 0.50
    var maximumSpeechDuration: Double = 5
    var minimumWindowConflictConfidence: Double = 0.65
    var minimumBilingualEvidence: Double = 0.25
    var minimumMajorityShare: Double = 0.5

    static let standard = ASRLanguageVotePolicy()

    var isValid: Bool {
        [minimumAnchorConfidence, minimumMargin, minimumPooledConfidence,
         maximumSpeechDuration, minimumWindowConflictConfidence, minimumBilingualEvidence,
         minimumMajorityShare].allSatisfy(\.isFinite)
            && minimumAnchorConfidence > 0 && minimumAnchorConfidence <= 1
            && minimumMargin >= 0 && minimumMargin <= 1
            && minimumPooledConfidence >= 0.5 && minimumPooledConfidence <= 1
            && maximumSpeechDuration > 0
            && minimumWindowConflictConfidence >= 0.5 && minimumWindowConflictConfidence <= 1
            && minimumBilingualEvidence > 0 && minimumBilingualEvidence <= 0.5
            && minimumMajorityShare >= 0.5 && minimumMajorityShare <= 1
    }
}

struct ASRLanguageEvidence: Equatable, Sendable {
    let window: ASRLanguageIdentificationWindow
    let posterior: [String: Float]
}

struct ASRLanguageVoteResult: Equatable, Sendable {
    var posterior: [String: Float] = [:]
    var weightShares: [Double] = []
    var windowPosteriors: [[String: Float]] = []
    var anchorLanguages: [String] = []
    var speechDuration: Double = 0
    var validWindowCount: Int = 0
    var invalidWindowCount: Int = 0
    var confidence: Float = 0
    var margin: Float = 0
    var reason: ASREngineRouteReason = .insufficientSpeech
    var policy: ASRLanguageVotePolicy = .standard

    var accepted: Bool { reason == .weightedEvidence }
}

enum ASRLanguageVote {
    static func pool(
        _ evidence: [ASRLanguageEvidence],
        policy: ASRLanguageVotePolicy = .standard
    ) -> ASRLanguageVoteResult {
        var result = ASRLanguageVoteResult(policy: policy)
        guard policy.isValid else {
            result.reason = .invalidLanguageEvidence
            return result
        }
        var windows: [ASRLanguageIdentificationWindow] = []
        var distributions: [[String: Double]] = []
        var weights: [Double] = []
        var anchors: Set<String> = []
        var invalidWindowCount = 0
        for sample in evidence {
            let slices = sample.window.slices
            guard !slices.isEmpty, slices.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
            }), zip(slices, slices.dropFirst()).allSatisfy({ $0.end <= $1.start }),
                  sample.window.duration.isFinite,
                  !sample.posterior.isEmpty,
                  sample.posterior.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                invalidWindowCount += 1
                continue
            }
            if let index = windows.firstIndex(of: sample.window) {
                if evidence.first(where: { $0.window == windows[index] })?.posterior == sample.posterior { continue }
                invalidWindowCount += 1
                continue
            }
            guard !windows.contains(where: { previous in
                previous.slices.contains { a in slices.contains { b in a.start < b.end && b.start < a.end } }
            }) else {
                invalidWindowCount += 1
                continue
            }
            var posterior: [String: Double] = [:]
            for (language, probability) in sample.posterior {
                posterior[ASREngineLanguagePolicy.ecapaRoutingCode(language), default: 0] += Double(probability)
            }
            let total = posterior.values.reduce(0, +)
            guard total.isFinite, total > 0 else {
                invalidWindowCount += 1
                continue
            }
            posterior = posterior.mapValues { $0 / total }
            let ranked = posterior.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let top = ranked[0]
            let margin = top.value - (ranked.dropFirst().first?.value ?? 0)
            if top.value >= policy.minimumAnchorConfidence, margin >= policy.minimumMargin {
                anchors.insert(top.key)
            }
            windows.append(sample.window)
            distributions.append(posterior)
            // LID windows are sampled at a common target duration. Keep each
            // valid window as one vote instead of treating a longer waveform
            // as stronger evidence; the model's posterior is only comparable
            // under its intended input-duration regime.
            weights.append(1)
            result.speechDuration += sample.window.duration
        }
        result.validWindowCount = distributions.count
        result.invalidWindowCount = invalidWindowCount
        result.windowPosteriors = distributions.map { $0.mapValues(Float.init) }
        result.anchorLanguages = anchors.sorted()
        let totalWeight = weights.reduce(0, +)
        result.weightShares = weights.map { totalWeight > 0 ? $0 / totalWeight : 0 }
        var pooled: [String: Double] = [:]
        for (posterior, share) in zip(distributions, result.weightShares) {
            for (language, probability) in posterior { pooled[language, default: 0] += share * probability }
        }
        result.posterior = pooled.mapValues(Float.init)
        let ranking = pooled.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let winner = ranking.first
        let confidence = winner?.value ?? 0
        let margin = confidence - (ranking.dropFirst().first?.value ?? 0)
        result.confidence = Float(confidence)
        result.margin = Float(margin)
        if result.speechDuration == 0 {
            result.reason = invalidWindowCount > 0 ? .invalidLanguageEvidence : .insufficientSpeech
        } else if invalidWindowCount > 0 {
            // Keep the data-quality signal for diagnostics, but retain and use all valid windows.
            result.reason = .invalidLanguageEvidence
        } else if anchors.count > 1 {
            result.reason = .mixedLanguages
        } else if !anchors.contains(winner?.key ?? "") {
            result.reason = .noReliableLanguageAnchor
        } else if confidence <= policy.minimumPooledConfidence || margin < policy.minimumMargin {
            result.reason = .insufficientWeightedEvidence
        } else {
            result.reason = .weightedEvidence
        }
        return result
    }

    static func reliableTop(
        of posterior: [String: Float],
        minimumConfidence: Double,
        policy: ASRLanguageVotePolicy
    ) -> (language: String, confidence: Double, margin: Double)? {
        var ranked: [(language: String, confidence: Double)] = []
        ranked.reserveCapacity(posterior.count)
        for (language, probability) in posterior {
            ranked.append((ASREngineLanguagePolicy.ecapaRoutingCode(language), Double(probability)))
        }
        ranked.sort { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.language < rhs.language }
            return lhs.confidence > rhs.confidence
        }
        guard let top = ranked.first else { return nil }
        let runnerUp = ranked.dropFirst().first?.confidence ?? 0
        let margin = top.confidence - runnerUp
        guard top.confidence >= minimumConfidence, margin >= policy.minimumMargin else { return nil }
        return (top.language, top.confidence, margin)
    }

    static func outlierLanguages(
        in posteriors: [[String: Float]],
        policy: ASRLanguageVotePolicy
    ) -> Set<String> {
        let languages = posteriors.compactMap {
            reliableTop(
                of: $0,
                minimumConfidence: policy.minimumWindowConflictConfidence,
                policy: policy
            )?.language
        }
        guard !languages.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for language in languages { counts[language, default: 0] += 1 }
        let total = languages.count
        guard let majorityCount = counts.values.max(),
              Double(majorityCount) / Double(total) > policy.minimumMajorityShare else {
            return []
        }
        return Set(counts.compactMap { language, count -> String? in
            guard count == 1, majorityCount > count else { return nil }
            // zh/en stay eligible for bilingual Qwen routing even as a singleton.
            if language == "zh" || language == "en" { return nil }
            return language
        })
    }
}
