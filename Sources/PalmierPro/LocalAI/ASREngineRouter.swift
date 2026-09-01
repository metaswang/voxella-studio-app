import Foundation

struct ASRLanguageIdentificationWindow: Equatable, Sendable {
    let slices: [ASRSpeechRange]

    var start: Double { slices.first?.start ?? 0 }
    var duration: Double { slices.reduce(0) { $0 + $1.duration } }
}

enum ASREngineRouter {
    static let minimumSpeechDuration: Double = 2.5
    static let shortWindowDuration: Double = 3
    static let extendedWindowDuration: Double = 5
    static let identificationWindowCount = 3
    static let minimumIdentificationWindowDuration: Double = 3
    static let maximumIdentificationWindowDuration: Double = 5
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

    static func rankedLanguages(_ posterior: [String: Float], limit: Int = 5) -> [(language: String, confidence: Float)] {
        posterior
            .sorted { $0.value > $1.value }
            .prefix(max(0, limit))
            .map { (ASREngineLanguagePolicy.ecapaRoutingCode($0.key), $0.value) }
    }

    static func averagePosteriors(_ posteriors: [[String: Float]]) -> [String: Float] {
        guard !posteriors.isEmpty else { return [:] }
        var sums: [String: Float] = [:]
        for posterior in posteriors {
            for (language, probability) in posterior {
                sums[language, default: 0] += probability
            }
        }
        let count = Float(posteriors.count)
        return sums.mapValues { $0 / count }
    }

    static func summary(of posterior: [String: Float], limit: Int = 5) -> String {
        rankedLanguages(posterior, limit: limit)
            .map { "\($0.language):\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ",")
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

    static func identificationWindows(
        speechRanges: [ASRSpeechRange],
        audioDuration: Double
    ) -> [ASRLanguageIdentificationWindow] {
        let ranges = normalizedSpeechRanges(speechRanges, audioDuration: audioDuration)
        let totalSpeech = ranges.reduce(0.0) { $0 + $1.duration }
        guard totalSpeech > 0 else { return [] }

        let windowLength = min(
            maximumIdentificationWindowDuration,
            max(minimumIdentificationWindowDuration, min(totalSpeech, maximumIdentificationWindowDuration))
        )
        let lastOrigin = max(0, totalSpeech - windowLength)
        let count: Int
        if lastOrigin < windowLength * 0.5 {
            count = 1
        } else if lastOrigin < windowLength * 1.5 {
            count = 2
        } else {
            count = identificationWindowCount
        }

        return (0..<count).compactMap { index in
            let origin = count == 1 ? 0 : lastOrigin * Double(index) / Double(count - 1)
            let slices = concatenatedSlices(from: ranges, origin: origin, duration: windowLength)
            return slices.isEmpty ? nil : ASRLanguageIdentificationWindow(slices: slices)
        }
    }

    static func decide(
        windowPosteriors: [[String: Float]],
        speechDuration: Double
    ) -> ASREngineRouteDecision {
        decide(posterior: averagePosteriors(windowPosteriors), speechDuration: speechDuration)
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

    private static func normalizedSpeechRanges(
        _ speechRanges: [ASRSpeechRange],
        audioDuration: Double
    ) -> [ASRSpeechRange] {
        guard audioDuration.isFinite, audioDuration > 0 else { return [] }
        return speechRanges.compactMap { range in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = min(audioDuration, max(0, range.start))
            let end = min(audioDuration, max(start, range.end))
            return end > start ? ASRSpeechRange(start: start, end: end) : nil
        }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
    }

    private static func concatenatedSlices(
        from ranges: [ASRSpeechRange],
        origin: Double,
        duration: Double
    ) -> [ASRSpeechRange] {
        guard duration > 0 else { return [] }
        var skipped = 0.0
        var remaining = duration
        var slices: [ASRSpeechRange] = []
        for range in ranges {
            if remaining <= 1e-9 { break }
            let length = range.duration
            if skipped + length <= origin {
                skipped += length
                continue
            }
            let localSkip = max(0, origin - skipped)
            let takeStart = range.start + localSkip
            let take = min(remaining, range.end - takeStart)
            if take > 1e-9 {
                slices.append(ASRSpeechRange(start: takeStart, end: takeStart + take))
                remaining -= take
            }
            skipped += length
        }
        return slices
    }
}
