import Foundation

struct ASRLanguageVotePolicy: Equatable, Sendable {
    var minimumAnchorConfidence: Double = 0.75
    var minimumMargin: Double = 0.15
    var minimumPooledConfidence: Double = 0.50
    var maximumSpeechDuration: Double = 5
    var minimumWindowCoverage: Double = 0.50
    var minimumBilingualEvidence: Double = 0.25

    static let standard = ASRLanguageVotePolicy()

    var isValid: Bool {
        [minimumAnchorConfidence, minimumMargin, minimumPooledConfidence,
         maximumSpeechDuration, minimumWindowCoverage, minimumBilingualEvidence].allSatisfy(\.isFinite)
            && minimumAnchorConfidence > 0 && minimumAnchorConfidence <= 1
            && minimumMargin >= 0 && minimumMargin <= 1
            && minimumPooledConfidence >= 0.5 && minimumPooledConfidence <= 1
            && maximumSpeechDuration > 0
            && minimumWindowCoverage >= 0.5 && minimumWindowCoverage <= 1
            && minimumBilingualEvidence > 0 && minimumBilingualEvidence <= 0.5
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
        for sample in evidence {
            let slices = sample.window.slices
            guard !slices.isEmpty, slices.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
            }), zip(slices, slices.dropFirst()).allSatisfy({ $0.end <= $1.start }),
                  sample.window.duration.isFinite,
                  !sample.posterior.isEmpty,
                  sample.posterior.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                result.reason = .invalidLanguageEvidence
                return result
            }
            if let index = windows.firstIndex(of: sample.window) {
                if evidence.first(where: { $0.window == windows[index] })?.posterior == sample.posterior { continue }
                result.reason = .invalidLanguageEvidence
                return result
            }
            guard !windows.contains(where: { previous in
                previous.slices.contains { a in slices.contains { b in a.start < b.end && b.start < a.end } }
            }) else {
                result.reason = .invalidLanguageEvidence
                return result
            }
            var posterior: [String: Double] = [:]
            for (language, probability) in sample.posterior {
                posterior[ASREngineLanguagePolicy.ecapaRoutingCode(language), default: 0] += Double(probability)
            }
            let total = posterior.values.reduce(0, +)
            guard total.isFinite, total > 0 else {
                result.reason = .invalidLanguageEvidence
                return result
            }
            posterior = posterior.mapValues { $0 / total }
            let ranked = posterior.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let top = ranked[0]
            let margin = top.value - (ranked.dropFirst().first?.value ?? 0)
            let weight = min(sample.window.duration, policy.maximumSpeechDuration)
            if top.value >= policy.minimumAnchorConfidence, margin >= policy.minimumMargin {
                anchors.insert(top.key)
            }
            windows.append(sample.window)
            distributions.append(posterior)
            weights.append(weight)
            result.speechDuration += sample.window.duration
        }
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
            result.reason = .insufficientSpeech
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
}
