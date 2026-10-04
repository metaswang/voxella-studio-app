import Foundation

struct TranslationLLMProcessor: Sendable {
    private struct RequestCue: Codable, Sendable {
        let id: Int
        let text: String
        let speaker: String?
        let targetDurationSeconds: Double
        let characterBudget: Int

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case speaker
            case targetDurationSeconds = "target_duration_seconds"
            case characterBudget = "character_budget"
        }
    }

    private struct RequestEnvelope: Codable, Sendable {
        let sourceLanguage: String?
        let targetLanguage: String
        let cues: [RequestCue]
        let contextCues: [RequestCue]?
        let userInstruction: String?
        let contextBefore: String?
        let contextAfter: String?

        enum CodingKeys: String, CodingKey {
            case sourceLanguage = "source_language"
            case targetLanguage = "target_language"
            case cues
            case contextCues = "context_cues"
            case userInstruction = "user_instruction"
        }

        init(
            sourceLanguage: String?,
            targetLanguage: String,
            cues: [RequestCue],
            contextCues: [RequestCue]? = nil,
            userInstruction: String?,
            contextBefore: String? = nil,
            contextAfter: String? = nil
        ) {
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.cues = cues
            self.contextCues = contextCues
            self.userInstruction = userInstruction
            self.contextBefore = contextBefore
            self.contextAfter = contextAfter
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
            try container.encode(targetLanguage, forKey: .targetLanguage)
            try container.encode(cues, forKey: .cues)
            try container.encodeIfPresent(contextCues, forKey: .contextCues)
            try container.encodeIfPresent(userInstruction, forKey: .userInstruction)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
            targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
            cues = try container.decode([RequestCue].self, forKey: .cues)
            contextCues = try container.decodeIfPresent([RequestCue].self, forKey: .contextCues)
            userInstruction = try container.decodeIfPresent(String.self, forKey: .userInstruction)
            contextBefore = nil
            contextAfter = nil
        }
    }

    private struct ResponseEnvelope: Decodable, Sendable {
        struct Translation: Decodable, Sendable {
            let id: Int
            let text: String
            let lines: [String]?
            let protectedSpans: [String]?
            enum CodingKeys: String, CodingKey { case id, text, lines; case protectedSpans = "protected_spans" }
        }

        let translations: [Translation]
    }

    let client: any LLMTextClient

    /// Single translation entry point. Track construction itself lives in
    /// `TranslationTrackBuilder`, which packs source units then translates 1:1.
    func translate(
        track: SubtitleTrack,
        options: TranslationFlowPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitleTrack {
        try await TranslationTrackBuilder(client: client).build(
            sourceTrack: track,
            options: options,
            progress: progress
        )
    }

    /// 1:1 line-aligned translation that keeps every source cue id and timing.
    func lineAlignedTranslate(
        track: SubtitleTrack,
        options: TranslationFlowPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitleTrack {
        let target = options.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw MediaFlowError.missingTargetLanguage }
        guard !track.cues.isEmpty else { throw MediaFlowError.missingSubtitleTrack }
        let batchSize = max(1, min(options.maximumCuesPerBatch, 24))
        let batches = stride(from: 0, to: track.cues.count, by: batchSize).map {
            Array(track.cues[$0..<min(track.cues.count, $0 + batchSize)])
        }
        let maximumConcurrentBatches = min(
            max(1, options.maximumConcurrentBatches),
            batches.count
        )
        let charactersPerSecond = TranslationDurationPolicy.charactersPerSecond(for: target)
        var translationsByID: [Int: ResponseEnvelope.Translation] = [:]
        Log.llm.notice(
            "translation line-aligned batches=\(batches.count) concurrency=\(maximumConcurrentBatches)"
        )
        progress(0, 0, batches.count, "Translating subtitle batches…")

        try await withThrowingTaskGroup(of: (Int, [ResponseEnvelope.Translation]).self) { group in
            var nextBatchIndex = 0
            for _ in 0..<maximumConcurrentBatches {
                let batchIndex = nextBatchIndex
                nextBatchIndex += 1
                group.addTask {
                    let batch = batches[batchIndex]
                    let request = self.lineAlignedRequest(
                        track: track,
                        batch: batch,
                        target: target,
                        charactersPerSecond: charactersPerSecond,
                        options: options
                    )
                    let response = try await self.completeValidated(
                        request: request,
                        expectedIDs: batch.map(\.id),
                        maximumAttempts: options.maximumAttempts
                    )
                    return (batchIndex, response.translations)
                }
            }

            var completedBatches = 0
            while let (batchIndex, translations) = try await group.next() {
                for translation in translations {
                    translationsByID[translation.id] = translation
                }
                completedBatches += 1
                progress(
                    Double(completedBatches) / Double(batches.count),
                    completedBatches,
                    batches.count,
                    "Translated subtitle batch \(batchIndex + 1) (\(completedBatches) of \(batches.count) complete)…"
                )
                if nextBatchIndex < batches.count {
                    let batchIndex = nextBatchIndex
                    nextBatchIndex += 1
                    group.addTask {
                        let batch = batches[batchIndex]
                        let request = self.lineAlignedRequest(
                            track: track,
                            batch: batch,
                            target: target,
                            charactersPerSecond: charactersPerSecond,
                            options: options
                        )
                        let response = try await self.completeValidated(
                            request: request,
                            expectedIDs: batch.map(\.id),
                            maximumAttempts: options.maximumAttempts
                        )
                        return (batchIndex, response.translations)
                    }
                }
            }
        }

        let translatedCues = track.cues.map { source -> SubtitleCue in
            let duration = max(0.1, source.end - source.start)
            let budget = max(1, Int((duration * charactersPerSecond).rounded(.down)))
            let text = translationsByID[source.id]?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SubtitleCue(
                id: source.id,
                sourceIDs: [source.id],
                text: text,
                start: source.start,
                end: source.end,
                speaker: source.speaker,
                characterBudget: budget,
                overBudget: TranslationDurationPolicy.visibleCharacterCount(text) > budget,
                timingQuality: .estimated,
                protectedSpans: translationsByID[source.id]?.protectedSpans,
                segmentationHints: translationsByID[source.id]?.lines
            )
        }
        progress(1, batches.count, batches.count, "Translation ready")
        return SubtitleTrack(
            sourceLanguage: track.language ?? track.sourceLanguage,
            language: target,
            cues: translatedCues, processingVersion: ElasticSubtitleSegmenter.processingVersion
        )
    }

    private func lineAlignedRequest(
        track: SubtitleTrack,
        batch: [SubtitleCue],
        target: String,
        charactersPerSecond: Double,
        options: TranslationFlowPayload
    ) -> RequestEnvelope {
        let batchIDs = Set(batch.map(\.id))
        let (before, after) = Self.neighboringContext(track: track, batchIDs: batchIDs)
        return RequestEnvelope(
            sourceLanguage: track.language ?? track.sourceLanguage,
            targetLanguage: target,
            cues: batch.map {
                let duration = max(0.1, $0.end - $0.start)
                return RequestCue(
                    id: $0.id,
                    text: $0.text,
                    speaker: $0.speaker,
                    targetDurationSeconds: duration,
                    characterBudget: max(1, Int((duration * charactersPerSecond).rounded(.down)))
                )
            },
            contextCues: nil,
            userInstruction: options.userInstruction,
            contextBefore: before,
            contextAfter: after
        )
    }

    private static func neighboringContext(
        track: SubtitleTrack,
        batchIDs: Set<Int>
    ) -> (String?, String?) {
        guard let firstIndex = track.cues.firstIndex(where: { batchIDs.contains($0.id) }),
              let lastIndex = track.cues.lastIndex(where: { batchIDs.contains($0.id) })
        else {
            return (nil, nil)
        }
        let before = track.cues.prefix(firstIndex).map(\.text).joined(separator: "\n")
        let after = track.cues.dropFirst(lastIndex + 1).map(\.text).joined(separator: "\n")
        return (
            clipped(before, keepingSuffix: true),
            clipped(after, keepingSuffix: false)
        )
    }

    private static let contextCharacters = 1_200

    private static func clipped(_ text: String, keepingSuffix: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= contextCharacters { return trimmed }
        return keepingSuffix
            ? String(trimmed.suffix(contextCharacters))
            : String(trimmed.prefix(contextCharacters))
    }

    private func completeValidated(
        request: RequestEnvelope,
        expectedIDs: [Int],
        maximumAttempts: Int
    ) async throws -> ResponseEnvelope {
        let translations = try await completeRecovering(
            request: request,
            maximumAttempts: maximumAttempts
        )
        let byID = Dictionary(
            translations.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let ordered = expectedIDs.compactMap { byID[$0] }
        guard ordered.count == expectedIDs.count else {
            let recoveredIDs = Set(ordered.map(\.id))
            let missing = expectedIDs.filter { !recoveredIDs.contains($0) }
            throw MediaFlowError.invalidLLMOutput(
                "Could not recover non-empty translations for cue ids \(Self.shortIDList(missing))."
            )
        }
        return ResponseEnvelope(translations: ordered)
    }

    private func completeRecovering(
        request: RequestEnvelope,
        maximumAttempts: Int,
        remainingRequestRecoveries: Int = 1
    ) async throws -> [ResponseEnvelope.Translation] {
        let encoded = try Self.encodedUserPrompt(request)
        let expectedIDs = request.cues.map(\.id)
        let expectedIDSet = Set(expectedIDs)
        let budgets = Dictionary(
            request.cues.map { ($0.id, $0.characterBudget) },
            uniquingKeysWith: { current, _ in current }
        )
        var acceptedByID: [Int: ResponseEnvelope.Translation] = [:]
        var priorFailure: String?
        var requestRecoveries = remainingRequestRecoveries
        let attempts = max(1, maximumAttempts)
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var user = encoded
            if let priorFailure {
                user += "\n\nThe previous response was rejected: \(priorFailure). Return corrected JSON only."
            }
            let raw: String
            do {
                raw = try await client.complete(system: Self.translationSystemPrompt, user: user)
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // Compression is advisory. A later request failure must not
                // discard a complete, valid translation already received.
                if acceptedByID.count == expectedIDs.count {
                    Log.llm.notice("translation keeping complete response after refinement failure")
                    return expectedIDs.compactMap { acceptedByID[$0] }
                }
                guard requestRecoveries > 0, request.cues.count > 1,
                      Self.canRecoverWithSmallerBatch(error) else {
                    throw error
                }
                // The client has already tried its model chain. A smaller
                // request can recover timeouts or truncated/empty responses.
                Log.llm.warning("translation shrinking failed batch cues=\(request.cues.count) error=\(LLMDiagnostics.description(error))")
                requestRecoveries -= 1
                break
            }
            do {
                let response = try SubtitleLLMProcessor.decodeJSON(ResponseEnvelope.self, from: raw)
                let grouped = Dictionary(grouping: response.translations) { $0.id }
                for id in expectedIDs {
                    guard let candidates = grouped[id], candidates.count == 1,
                          let candidate = candidates.first,
                          !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    if let current = acceptedByID[id],
                       let budget = budgets[id],
                       TranslationDurationPolicy.visibleCharacterCount(current.text) <= budget,
                       TranslationDurationPolicy.visibleCharacterCount(candidate.text) > budget {
                        continue
                    }
                    acceptedByID[id] = candidate
                }
                let missingIDs = expectedIDs.filter { acceptedByID[$0] == nil }
                let overBudgetIDs = expectedIDs.compactMap { id -> Int? in
                    guard let translation = acceptedByID[id], let budget = budgets[id],
                          TranslationDurationPolicy.visibleCharacterCount(translation.text) > budget
                    else { return nil }
                    return id
                }
                if missingIDs.isEmpty {
                    if !overBudgetIDs.isEmpty, attempt < attempts - 1 {
                        priorFailure = "Cue ids \(Self.shortIDList(overBudgetIDs)) exceed their character_budget. Compress them without losing meaning"
                        continue
                    }
                    return expectedIDs.compactMap { acceptedByID[$0] }
                }

                let duplicateIDs = expectedIDs.filter { (grouped[$0]?.count ?? 0) > 1 }
                let emptyIDs = expectedIDs.filter { id in
                    guard let candidates = grouped[id], candidates.count == 1,
                          let candidate = candidates.first else { return false }
                    return candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let unexpectedIDs = response.translations.map(\.id).filter {
                    !expectedIDSet.contains($0)
                }
                priorFailure = Self.rejectionReason(
                    missingIDs: missingIDs,
                    duplicateIDs: duplicateIDs,
                    emptyIDs: emptyIDs,
                    unexpectedIDs: unexpectedIDs,
                    overBudgetIDs: overBudgetIDs
                )
            } catch {
                priorFailure = error.localizedDescription
            }
        }

        let missingCues = request.cues.filter { acceptedByID[$0.id] == nil }
        guard !missingCues.isEmpty else {
            return expectedIDs.compactMap { acceptedByID[$0] }
        }

        let recoveryGroups: [[RequestCue]]
        if missingCues.count < request.cues.count {
            recoveryGroups = [missingCues]
        } else if missingCues.count > 1 {
            let midpoint = (missingCues.count + 1) / 2
            recoveryGroups = [
                Array(missingCues[..<midpoint]),
                Array(missingCues[midpoint...]),
            ]
        } else {
            throw MediaFlowError.invalidLLMOutput(
                "Could not recover a non-empty translation for cue id \(missingCues[0].id)."
            )
        }

        let originalContext = request.contextCues ?? request.cues
        for group in recoveryGroups where !group.isEmpty {
            let recoveryRequest = RequestEnvelope(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                cues: group,
                contextCues: originalContext,
                userInstruction: request.userInstruction,
                contextBefore: request.contextBefore,
                contextAfter: request.contextAfter
            )
            let recovered = try await completeRecovering(
                request: recoveryRequest,
                maximumAttempts: maximumAttempts,
                remainingRequestRecoveries: requestRecoveries
            )
            for translation in recovered {
                acceptedByID[translation.id] = translation
            }
        }

        let stillMissing = expectedIDs.filter { acceptedByID[$0] == nil }
        guard stillMissing.isEmpty else {
            throw MediaFlowError.invalidLLMOutput(
                "Could not recover non-empty translations for cue ids \(Self.shortIDList(stillMissing))."
            )
        }
        return expectedIDs.compactMap { acceptedByID[$0] }
    }

    private static func encodedUserPrompt(_ request: RequestEnvelope) throws -> String {
        var user = try SubtitleLLMProcessor.encodedJSON(request)
        if let before = request.contextBefore, !before.isEmpty {
            user += "\n<context_before>\n\(before)\n</context_before>"
        }
        if let after = request.contextAfter, !after.isEmpty {
            user += "\n<context_after>\n\(after)\n</context_after>"
        }
        return user
    }

    private static func canRecoverWithSmallerBatch(_ error: Error) -> Bool {
        guard let error = error as? LLMClientError else { return false }
        switch error {
        case .timeout, .emptyResponse, .invalidResponse:
            return true
        case .provider(let status, _, _):
            return status == 413
        case .exhausted(let failures):
            return !failures.isEmpty && failures.allSatisfy {
                ["timeout", "empty_response", "invalid_response", "http_413"].contains($0.reason)
            }
        case .transport, .nonHTTPResponse, .insufficientCredits:
            return false
        }
    }

    private static func rejectionReason(
        missingIDs: [Int],
        duplicateIDs: [Int],
        emptyIDs: [Int],
        unexpectedIDs: [Int],
        overBudgetIDs: [Int]
    ) -> String {
        var issues: [String] = []
        if !missingIDs.isEmpty { issues.append("missing cue ids \(shortIDList(missingIDs))") }
        if !duplicateIDs.isEmpty { issues.append("duplicate cue ids \(shortIDList(duplicateIDs))") }
        if !emptyIDs.isEmpty { issues.append("empty cue ids \(shortIDList(emptyIDs))") }
        if !unexpectedIDs.isEmpty { issues.append("unexpected cue ids \(shortIDList(unexpectedIDs))") }
        if !overBudgetIDs.isEmpty { issues.append("over-budget cue ids \(shortIDList(overBudgetIDs))") }
        return issues.isEmpty
            ? "translations must contain every requested cue id exactly once with non-empty text"
            : issues.joined(separator: "; ")
    }

    private static func shortIDList(_ ids: [Int]) -> String {
        let unique = Array(Set(ids)).sorted()
        let shown = unique.prefix(12).map(String.init).joined(separator: ", ")
        return unique.count > 12 ? "[\(shown), …]" : "[\(shown)]"
    }

    private static let translationSystemPrompt = """
    You translate subtitle cues into the requested target language.
    Return one JSON object only: {"translations":[{"id":0,"text":"...","lines":["..."],"protected_spans":["..."]}]}.
    lines and protected_spans are optional, verbatim semantic boundary hints in the translated text; never change text when proposing them. Preserve tightly bound phrases and names; do not aim for a fixed number of characters per subtitle.
    Keep every id exactly once and in the original order. Do not merge or omit cues.
    If context_cues is present, use it only for linguistic context. Translate only the items in cues.
    If <context_before> or <context_after> is present, use it only for names, pronouns, and terminology. Never translate or quote that context into the output.
    Preserve meaning, tone, names, numbers, and speaker intent without adding information.
    Keep translations natural and concise for the target duration. character_budget is an advisory estimate, not a reason to omit meaning.
    Prefer natural short phrasing over literal expansion. Output only target-language text.
    """
}

enum TranslationDurationPolicy {
    /// Wire compatibility only: the final solver measures shaped glyph width in em.
    static func charactersPerSecond(for language: String) -> Double { 16 }

    static func visibleCharacterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}
