import Foundation

enum ASREngineRouter {
    static let minimumSpeechDuration: Double = 2.5
    static let shortWindowDuration: Double = 3
    static let extendedWindowDuration: Double = 5
    static let confidentScore: Float = 0.80
    static let confidentMargin: Float = 0.25
    static let whisperDominantScore: Float = 0.50
    static let whisperHintConfidence: Float = 0.80

    static func scores(from posterior: [String: Float]) -> ASREngineScores {
        var qwen: Float = 0
        var parakeet: Float = 0
        for (language, probability) in posterior {
            let iso = ASREngineLanguagePolicy.ecapaRoutingCode(language)
            if ASREngineLanguagePolicy.qwenLanguages.contains(iso) {
                qwen += probability
            } else if ASREngineLanguagePolicy.parakeetLanguages.contains(iso) {
                parakeet += probability
            }
        }
        let whisper = max(0, 1 - qwen - parakeet)
        return ASREngineScores(qwen: qwen, parakeet: parakeet, whisper: whisper)
    }

    static func isConfident(_ scores: ASREngineScores) -> Bool {
        scores.leading.score >= confidentScore && scores.margin >= confidentMargin
    }

    static func topLanguage(in posterior: [String: Float]) -> (language: String, confidence: Float)? {
        posterior.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    static func highestLanguage(
        in posterior: [String: Float],
        belongingTo languages: Set<String>
    ) -> String? {
        posterior
            .filter { languages.contains(ASREngineLanguagePolicy.ecapaRoutingCode($0.key)) }
            .max { $0.value < $1.value }?
            .key
    }

    static func decide(
        posterior: [String: Float],
        speechDuration: Double,
        userLanguageCode: String? = nil
    ) -> ASREngineRouteDecision {
        if let userLanguageCode {
            let engine = ASREngineLanguagePolicy.engine(forLanguageCode: userLanguageCode)
            let iso = ASREngineLanguagePolicy.normalizedISO(userLanguageCode)
            return ASREngineRouteDecision(
                engine: engine,
                scores: scores(from: posterior),
                reason: .userLocked,
                topLanguage: iso,
                parakeetDomainLanguage: engine == .parakeet ? iso : nil,
                whisperHint: engine == .whisper
                    ? ASREngineLanguagePolicy.whisperLanguageCode(from: userLanguageCode)
                    : nil,
                routeConfidence: 1,
                speechDuration: speechDuration
            )
        }

        let engineScores = scores(from: posterior)
        let top = topLanguage(in: posterior)
        let parakeetLanguage = highestLanguage(
            in: posterior,
            belongingTo: ASREngineLanguagePolicy.parakeetLanguages
        )
        let ranked = engineScores.ranked
        let leading = ranked[0]
        let reason: ASREngineRouteReason
        let engine: ASREngine

        if speechDuration >= minimumSpeechDuration, isConfident(engineScores) {
            engine = leading.engine
            reason = .confident
        } else if leading.engine == .whisper, leading.score >= whisperDominantScore {
            engine = .whisper
            reason = .whisperDominant
        } else if shouldResolveAsQwen(engineScores) {
            engine = .qwen
            reason = .qwenParakeetAmbiguous
        } else {
            engine = leading.engine
            reason = .topEngine
        }

        let whisperHint: String?
        if engine == .whisper,
           let top,
           top.confidence >= whisperHintConfidence,
           ASREngineLanguagePolicy.engine(forLanguageCode: top.language) == .whisper {
            whisperHint = ASREngineLanguagePolicy.whisperLanguageCode(from: top.language)
        } else if engine == .whisper, reason == .userLocked {
            whisperHint = ASREngineLanguagePolicy.whisperLanguageCode(from: top?.language)
        } else {
            whisperHint = nil
        }

        return ASREngineRouteDecision(
            engine: engine,
            scores: engineScores,
            reason: reason,
            topLanguage: top.map { ASREngineLanguagePolicy.ecapaRoutingCode($0.language) },
            parakeetDomainLanguage: parakeetLanguage.map(ASREngineLanguagePolicy.ecapaRoutingCode),
            whisperHint: whisperHint,
            routeConfidence: leading.score,
            speechDuration: speechDuration
        )
    }

    private static func shouldResolveAsQwen(_ scores: ASREngineScores) -> Bool {
        let qwenParakeetGap = abs(scores.qwen - scores.parakeet)
        return qwenParakeetGap < confidentMargin
            && max(scores.qwen, scores.parakeet) >= scores.whisper
    }
}
