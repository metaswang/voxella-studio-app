import Foundation

struct ASRLanguageIdentificationWindow: Equatable, Sendable {
    let slices: [ASRSpeechRange]

    var start: Double { slices.first?.start ?? 0 }
    var duration: Double { slices.reduce(0) { $0 + $1.duration } }
}

enum ASREngineRouter {
    static let identificationWindowCount = 3
    static let targetIdentificationWindowDuration = 3.0
    static let maximumIdentificationWindowDuration = ASRLanguageVotePolicy.standard.maximumSpeechDuration

    static func scores(from posterior: [String: Float]) -> ASREngineScores {
        var qwen: Float = 0
        var parakeet: Float = 0
        for (language, probability) in posterior {
            let iso = ASREngineLanguagePolicy.ecapaRoutingCode(language)
            if ASREngineLanguagePolicy.qwenSupportedLanguages.contains(iso) {
                qwen += probability
            }
            if ASREngineLanguagePolicy.parakeetLanguages.contains(iso) {
                parakeet += probability
            }
        }
        let covered = ASREngineLanguagePolicy.qwenSupportedLanguages.union(ASREngineLanguagePolicy.parakeetLanguages)
        let whisper = posterior.reduce(Float(0)) { total, entry in
            total + (covered.contains(ASREngineLanguagePolicy.ecapaRoutingCode(entry.key)) ? 0 : entry.value)
        }
        return ASREngineScores(qwen: qwen, parakeet: parakeet, whisper: whisper)
    }

    static func topLanguage(in posterior: [String: Float]) -> (language: String, confidence: Float)? {
        posterior.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    static func rankedLanguages(_ posterior: [String: Float], limit: Int = 5) -> [(language: String, confidence: Float)] {
        posterior
            .sorted { $0.value > $1.value }
            .prefix(max(0, limit))
            .map { (ASREngineLanguagePolicy.ecapaRoutingCode($0.key), $0.value) }
    }

    static func summary(of posterior: [String: Float], limit: Int = 5) -> String {
        rankedLanguages(posterior, limit: limit)
            .map { "\($0.language):\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ",")
    }

    static func identificationWindows(
        speechRanges: [ASRSpeechRange],
        audioDuration: Double
    ) -> [ASRLanguageIdentificationWindow] {
        let ranges = normalizedSpeechRanges(speechRanges, audioDuration: audioDuration)
        let totalSpeech = ranges.reduce(0.0) { $0 + $1.duration }
        guard totalSpeech > 0 else { return [] }

        let count = min(identificationWindowCount, max(1, Int(min(
            Double(identificationWindowCount), totalSpeech / targetIdentificationWindowDuration
        ))))
        let windowLength = min(maximumIdentificationWindowDuration, totalSpeech / Double(count))
        let lastOrigin = max(0, totalSpeech - windowLength)

        return (0..<count).compactMap { index in
            let origin = count == 1 ? 0 : lastOrigin * Double(index) / Double(count - 1)
            let slices = concatenatedSlices(from: ranges, origin: origin, duration: windowLength)
            return slices.isEmpty ? nil : ASRLanguageIdentificationWindow(slices: slices)
        }
    }

    static func decide(
        evidence: [ASRLanguageEvidence],
        policy: ASRLanguageVotePolicy = .standard
    ) -> ASREngineRouteDecision {
        let vote = ASRLanguageVote.pool(evidence, policy: policy)
        let top = topLanguage(in: vote.posterior)?.language
        let coverage = scores(from: vote.posterior)
        let selection = selectEngine(vote: vote, coverage: coverage)
        let engine = selection.engine
        return ASREngineRouteDecision(
            engine: engine,
            scores: coverage,
            reason: selection.reason,
            topLanguage: top,
            parakeetDomainLanguage: engine == .parakeet ? topLanguage(in: vote.posterior.filter {
                ASREngineLanguagePolicy.parakeetLanguages.contains($0.key)
            })?.language : nil,
            whisperHint: nil,
            routeConfidence: engine == .whisper ? vote.confidence : coverage[engine],
            speechDuration: vote.speechDuration,
            languageVote: vote
        )
    }

    private static func selectEngine(
        vote: ASRLanguageVoteResult,
        coverage: ASREngineScores
    ) -> (engine: ASREngine, reason: ASREngineRouteReason) {
        if vote.reason == .invalidLanguageEvidence || vote.reason == .insufficientSpeech {
            return (.whisper, vote.reason)
        }
        let policy = vote.policy
        let anchors = Set(vote.anchorLanguages)
        let windowScores = vote.windowPosteriors.map { scores(from: $0) }
        func qualifies(_ engine: ASREngine, languages: Set<String>) -> Bool {
            let score = Double(coverage[engine])
            return score > policy.minimumPooledConfidence
                && score - (1 - score) >= policy.minimumMargin
                && anchors.isSubset(of: languages)
                && windowScores.allSatisfy { Double($0[engine]) > policy.minimumWindowCoverage }
        }
        let qwen = qualifies(.qwen, languages: ASREngineLanguagePolicy.qwenSupportedLanguages)
        let parakeet = qualifies(.parakeet, languages: ASREngineLanguagePolicy.parakeetLanguages)
        let bilingual = anchors.isSuperset(of: ["zh", "en"]) || vote.windowPosteriors.contains {
            let chinese = Double($0["zh", default: 0])
            let english = Double($0["en", default: 0])
            return min(chinese, english) >= policy.minimumBilingualEvidence
                && chinese + english >= policy.minimumAnchorConfidence
        }
        if qwen && bilingual { return (.qwen, .chineseEnglishConflict) }
        if parakeet { return (.parakeet, .engineCoverage) }
        if qwen { return (.qwen, .engineCoverage) }
        return (.whisper, .insufficientEngineCoverage)
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

        return decide(evidence: [ASRLanguageEvidence(
            window: .init(slices: [.init(start: 0, end: speechDuration)]),
            posterior: posterior
        )])
    }

    private static func normalizedSpeechRanges(
        _ speechRanges: [ASRSpeechRange],
        audioDuration: Double
    ) -> [ASRSpeechRange] {
        guard audioDuration.isFinite, audioDuration > 0 else { return [] }
        let sorted: [ASRSpeechRange] = speechRanges.compactMap { range -> ASRSpeechRange? in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = min(audioDuration, max(0, range.start))
            let end = min(audioDuration, max(start, range.end))
            return end > start ? ASRSpeechRange(start: start, end: end) : nil
        }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var merged: [ASRSpeechRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
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
