import Foundation

struct ASRLanguageIdentificationWindow: Equatable, Sendable {
    let slices: [ASRSpeechRange]

    var start: Double { slices.first?.start ?? 0 }
    var duration: Double { slices.reduce(0) { $0 + $1.duration } }
}

enum ASREngineRouter {
    static let standardIdentificationWindowCount = 5
    static let longFormIdentificationWindowCount = 7
    static let longFormAudioDuration = 30 * 60.0
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

    /// Projects a language posterior onto one preferred engine per language.
    ///
    /// `scores(from:)` intentionally reports raw capability coverage, where a
    /// language supported by both models contributes to both scores. Routing
    /// needs a real vote, so overlapping capabilities use the language policy's
    /// preferred engine and cannot be counted twice.
    static func projectedScores(from posterior: [String: Float]) -> ASREngineScores {
        var scores = ASREngineScores.zero
        for (language, probability) in posterior {
            switch ASREngineLanguagePolicy.engine(forLanguageCode: language) {
            case .qwen:
                scores.qwen += probability
            case .parakeet:
                scores.parakeet += probability
            case .whisper:
                scores.whisper += probability
            }
        }
        return scores
    }

    /// Aggregates per-window projected engine votes using the equal-window
    /// shares produced by the language vote.
    static func projectedScores(
        from posteriors: [[String: Float]],
        weightShares: [Double]
    ) -> ASREngineScores {
        guard posteriors.count == weightShares.count else { return .zero }
        var result = ASREngineScores.zero
        for (posterior, share) in zip(posteriors, weightShares) {
            guard share.isFinite, share > 0 else { continue }
            let projected = projectedScores(from: posterior)
            result.qwen += Float(share) * projected.qwen
            result.parakeet += Float(share) * projected.parakeet
            result.whisper += Float(share) * projected.whisper
        }
        return result
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

        let preferredCount = audioDuration >= longFormAudioDuration
            ? longFormIdentificationWindowCount
            : standardIdentificationWindowCount
        let availableCount = max(1, Int((totalSpeech / targetIdentificationWindowDuration).rounded(.down)))
        let count = min(preferredCount, availableCount)
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
        let engineVotes = projectedScores(
            from: vote.windowPosteriors,
            weightShares: vote.weightShares
        )
        let selection = selectEngine(vote: vote, coverage: coverage, engineVotes: engineVotes)
        let engine = selection.engine
        return ASREngineRouteDecision(
            engine: engine,
            scores: coverage,
            engineVoteScores: engineVotes,
            reason: selection.reason,
            topLanguage: top,
            parakeetDomainLanguage: engine == .parakeet ? topLanguage(in: vote.posterior.filter {
                ASREngineLanguagePolicy.parakeetLanguages.contains($0.key)
            })?.language : nil,
            whisperHint: whisperHint(engine: engine, reason: selection.reason, topLanguage: top),
            routeConfidence: routeConfidence(
                engine: engine,
                reason: selection.reason,
                vote: vote,
                coverage: coverage,
                engineVotes: engineVotes
            ),
            speechDuration: vote.speechDuration,
            languageVote: vote
        )
    }

    /// Language lock and engine coverage are independent gates.
    /// A close Qwen/Parakeet family vote is not a coverage hole.
    private static func selectEngine(
        vote: ASRLanguageVoteResult,
        coverage: ASREngineScores,
        engineVotes: ASREngineScores
    ) -> (engine: ASREngine, reason: ASREngineRouteReason) {
        let policy = vote.policy
        let anchors = Set(vote.anchorLanguages)
        let outliers = ASRLanguageVote.outlierLanguages(in: vote.windowPosteriors, policy: policy)
        let bilingualHasReliableUnsupportedLanguage = hasReliableUnsupportedWindow(
            vote.windowPosteriors,
            supportedLanguages: ASREngineLanguagePolicy.qwenSupportedLanguages,
            outliers: outliers,
            policy: policy
        )
        let bilingual = anchors.isSuperset(of: ["zh", "en"]) || vote.windowPosteriors.contains {
            let chinese = Double($0["zh", default: 0])
            let english = Double($0["en", default: 0])
            return min(chinese, english) >= policy.minimumBilingualEvidence
                && chinese + english >= policy.minimumAnchorConfidence
        }
        func canUse(_ engine: ASREngine) -> Bool {
            switch engine {
            case .qwen:
                Double(coverage.qwen) >= policy.minimumPooledConfidence
                    && !hasReliableUnsupportedWindow(
                        vote.windowPosteriors,
                        supportedLanguages: ASREngineLanguagePolicy.qwenSupportedLanguages,
                        outliers: outliers,
                        policy: policy
                    )
            case .parakeet:
                Double(coverage.parakeet) >= policy.minimumPooledConfidence
                    && !hasReliableUnsupportedWindow(
                        vote.windowPosteriors,
                        supportedLanguages: ASREngineLanguagePolicy.parakeetLanguages,
                        outliers: outliers,
                        policy: policy
                    )
            case .whisper:
                false
            }
        }
        func coverageWinner() -> (engine: ASREngine, reason: ASREngineRouteReason)? {
            let qwenOK = canUse(.qwen)
            let parakeetOK = canUse(.parakeet)
            if qwenOK, parakeetOK {
                return coverage.parakeet > coverage.qwen
                    ? (.parakeet, .engineCoverage)
                    : (.qwen, .engineCoverage)
            }
            if qwenOK { return (.qwen, .engineCoverage) }
            if parakeetOK { return (.parakeet, .engineCoverage) }
            return nil
        }

        if vote.reason == .weightedEvidence,
           Double(vote.confidence) >= policy.minimumAnchorConfidence,
           let top = topLanguage(in: vote.posterior)?.language {
            let preferred = ASREngineLanguagePolicy.engine(forLanguageCode: top)
            if preferred == .whisper {
                return (.whisper, .whisperLanguage)
            }
            if canUse(preferred) {
                return (preferred, .weightedEvidence)
            }
            let other: ASREngine = preferred == .qwen ? .parakeet : .qwen
            if canUse(other) {
                return (other, .engineCoverage)
            }
            return (.whisper, .insufficientEngineCoverage)
        }

        // Qwen is the only routing target that can intentionally retain a
        // Chinese/English mixture. Use raw Qwen capability coverage for this
        // explicit exception, but still require a sufficiently strong LID score.
        if bilingual,
           !bilingualHasReliableUnsupportedLanguage,
           Double(coverage.qwen) >= policy.minimumPooledConfidence {
            return (.qwen, .chineseEnglishConflict)
        }

        let leading = engineVotes.leading
        let runnerUp = engineVotes.runnerUp
        let score = Double(leading.score)
        let margin = Double(leading.score - runnerUp.score)
        if leading.engine != .whisper,
           score >= policy.minimumPooledConfidence,
           margin >= policy.minimumMargin,
           canUse(leading.engine) {
            return (leading.engine, .engineCoverage)
        }

        return coverageWinner() ?? (.whisper, .insufficientEngineCoverage)
    }

    private static func whisperHint(
        engine: ASREngine,
        reason: ASREngineRouteReason,
        topLanguage: String?
    ) -> String? {
        guard engine == .whisper, reason == .whisperLanguage else { return nil }
        return ASREngineLanguagePolicy.whisperLanguageCode(from: topLanguage)
    }

    private static func routeConfidence(
        engine: ASREngine,
        reason: ASREngineRouteReason,
        vote: ASRLanguageVoteResult,
        coverage: ASREngineScores,
        engineVotes: ASREngineScores
    ) -> Float {
        switch reason {
        case .weightedEvidence, .whisperLanguage:
            vote.confidence
        case .chineseEnglishConflict, .engineCoverage:
            coverage[engine]
        default:
            engineVotes.leading.score
        }
    }

    private static func hasReliableUnsupportedWindow(
        _ posteriors: [[String: Float]],
        supportedLanguages: Set<String>,
        outliers: Set<String>,
        policy: ASRLanguageVotePolicy
    ) -> Bool {
        posteriors.contains { posterior in
            guard let top = ASRLanguageVote.reliableTop(
                of: posterior,
                minimumConfidence: policy.minimumWindowConflictConfidence,
                policy: policy
            ) else {
                return posterior.isEmpty
            }
            return !supportedLanguages.contains(top.language) && !outliers.contains(top.language)
        }
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
