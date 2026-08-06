import Foundation

/// Builds a standalone target-language subtitle track from a prepared source
/// track, aligned with the postprocess worker's `build_translated_subtitle_track`.
///
/// The model owns target-language cue boundaries and may merge or split cues,
/// but never owns absolute time: every target cue reports the source indices it
/// covers, and timing is re-derived from those source cues.
struct TranslationTrackBuilder: Sendable {
    let client: any LLMTextClient

    private enum Policy {
        static let windowMaximumCues = 24
        static let windowMaximumCharacters = 3000
        static let windowSoftCharacters = 2200
        static let windowMinimumCues = 4
        static let windowGapSeconds = 0.6
        static let minimumCueDuration = 0.5
        static let minimumCueSpan = 0.001
        static let contextCues = 4
        static let userInstructionCharacters = 400
        static let splitDepthLimit = 2
    }

    // MARK: - Model

    private struct SourceCue: Sendable {
        var position: Int
        var id: Int
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
    }

    /// A target cue before timing: text plus the source positions it covers.
    private struct TargetDraft: Sendable {
        var text: String
        var positions: [Int]
    }

    private struct WindowOutcome: Sendable {
        var drafts: [TargetDraft]
        var summary: String?
    }

    // MARK: - Entry point

    func build(
        sourceTrack: SubtitleTrack,
        options: TranslationFlowPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitleTrack {
        let target = options.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw MediaFlowError.missingTargetLanguage }
        let sourceLanguage = sourceTrack.language ?? sourceTrack.sourceLanguage
        let source = Self.normalizedSource(sourceTrack)
        guard !source.isEmpty else { throw MediaFlowError.missingSubtitleTrack }

        if let sourcePrimary = SubtitleReadabilityPolicy.primaryLanguage(sourceLanguage),
           sourcePrimary == SubtitleReadabilityPolicy.primaryLanguage(target) {
            progress(1, 1, 1, "Translation ready")
            return Self.passthroughTrack(
                source: source,
                sourceLanguage: sourceLanguage,
                target: target
            )
        }

        let denseTarget = SubtitleReadabilityPolicy.usesDenseScript(
            languageCode: target,
            sampleText: ""
        )
        let limits = SubtitleReadabilityPolicy.limits(denseScript: denseTarget)
        let windows = Self.windows(
            source: source,
            maximumCues: options.maximumCuesPerBatch
        )

        var drafts: [TargetDraft] = []
        var previousSummary: String?
        // Sequential so each window can carry the previous window's summary.
        for (index, positions) in windows.enumerated() {
            try Task.checkCancellation()
            progress(
                Double(index) / Double(windows.count),
                index,
                windows.count,
                "Translating subtitle window \(index + 1) of \(windows.count)…"
            )
            let outcome = try await translateWindow(
                source: source,
                positions: positions,
                sourceLanguage: sourceLanguage,
                target: target,
                previousSummary: previousSummary,
                limits: limits,
                options: options
            )
            if let summary = outcome.summary { previousSummary = summary }
            drafts.append(
                contentsOf: Self.resplitOverlongDrafts(
                    outcome.drafts,
                    languageCode: target,
                    denseScript: denseTarget,
                    limits: limits
                )
            )
        }

        guard !drafts.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("Translation produced no target cues.")
        }

        let cues = Self.timedCues(
            drafts: drafts,
            source: source,
            target: target,
            denseScript: denseTarget
        )
        progress(1, windows.count, windows.count, "Translation ready")
        return SubtitleTrack(sourceLanguage: sourceLanguage, language: target, cues: cues)
    }

    // MARK: - Source normalization

    private static func normalizedSource(_ track: SubtitleTrack) -> [SourceCue] {
        let ordered = track.cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                return lhs.id < rhs.id
            }
        return ordered.enumerated().map { position, cue in
            SourceCue(
                position: position,
                id: cue.id,
                text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: cue.start,
                end: cue.end,
                speaker: normalizedSpeaker(cue.speaker)
            )
        }
    }

    private static func passthroughTrack(
        source: [SourceCue],
        sourceLanguage: String?,
        target: String
    ) -> SubtitleTrack {
        let charactersPerSecond = TranslationDurationPolicy.charactersPerSecond(for: target)
        return SubtitleTrack(
            sourceLanguage: sourceLanguage,
            language: target,
            cues: source.enumerated().map { index, cue in
                let budget = characterBudget(
                    start: cue.start,
                    end: cue.end,
                    charactersPerSecond: charactersPerSecond
                )
                return SubtitleCue(
                    id: index,
                    sourceIDs: [cue.id],
                    text: cue.text,
                    start: cue.start,
                    end: cue.end,
                    speaker: cue.speaker,
                    characterBudget: budget,
                    overBudget: TranslationDurationPolicy.visibleCharacterCount(cue.text) > budget
                )
            }
        )
    }

    // MARK: - Window chunking

    /// Port of `_chunk_source_subtitle_indices`: a hard budget picks the widest
    /// legal window, then a boundary score picks the most natural cut inside it.
    private static func windows(source: [SourceCue], maximumCues: Int) -> [[Int]] {
        let limitCues = max(1, min(Policy.windowMaximumCues, maximumCues))
        let limitCharacters = max(500, Policy.windowMaximumCharacters)
        let targetCharacters = max(1, min(limitCharacters, Policy.windowSoftCharacters))
        let targetCues = max(1, min(limitCues, Int((Double(limitCues) * 0.75).rounded(.up))))
        let minimumBoundaryCues = max(1, min(limitCues, Policy.windowMinimumCues))
        let count = source.count

        var output: [[Int]] = []
        var start = 0
        while start < count {
            var endExclusive = start
            var characters = 0
            while endExclusive < count {
                let cueLength = source[endExclusive].text.count
                if endExclusive > start,
                   (endExclusive - start) >= limitCues || characters + cueLength > limitCharacters {
                    break
                }
                characters += cueLength
                endExclusive += 1
            }
            if endExclusive >= count {
                output.append(Array(start..<count))
                break
            }

            var bestEnd = max(start, endExclusive - 1)
            var bestScore = -Double.infinity
            var runningCharacters = 0
            for candidate in start..<endExclusive {
                runningCharacters += source[candidate].text.count
                let cueCount = candidate - start + 1
                var score = boundaryScore(source: source, endPosition: candidate)
                if cueCount < minimumBoundaryCues, candidate < endExclusive - 1 { score -= 500 }
                let characterRatio = Double(runningCharacters) / Double(targetCharacters)
                score += max(0, min(240, characterRatio * 180))
                score -= abs(Double(runningCharacters - targetCharacters))
                    / Double(targetCharacters) * 160
                score -= Double(abs(cueCount - targetCues)) * 8
                if runningCharacters < max(1, Int(Double(targetCharacters) * 0.45)),
                   candidate < endExclusive - 1 {
                    score -= 180
                }
                if candidate == endExclusive - 1 { score += 35 }
                if score > bestScore {
                    bestScore = score
                    bestEnd = candidate
                }
            }
            output.append(Array(start...bestEnd))
            start = bestEnd + 1
        }
        return output
    }

    /// Port of `_translation_window_boundary_score`.
    private static func boundaryScore(source: [SourceCue], endPosition: Int) -> Double {
        guard source.indices.contains(endPosition) else { return -.infinity }
        let cue = source[endPosition]
        var score = 0.0
        if let last = cue.text.last.map(String.init) {
            if SubtitleReadabilityPolicy.strongEndPunctuation.contains(last) {
                score += 1000
            } else if SubtitleReadabilityPolicy.weakEndPunctuation.contains(last) {
                score += 360
            }
        }
        guard endPosition + 1 < source.count else { return score }
        let next = source[endPosition + 1]
        if let speaker = cue.speaker, let nextSpeaker = next.speaker, speaker != nextSpeaker {
            score += 620
        }
        let gap = next.start - cue.end
        if gap >= Policy.windowGapSeconds {
            score += 420 + min(240, gap * 80)
        }
        return score
    }

    // MARK: - Window translation

    private struct RequestCue: Encodable {
        let index: Int
        let subtitleID: Int
        let startSeconds: Double
        let endSeconds: Double
        let speaker: String?
        let text: String

        enum CodingKeys: String, CodingKey {
            case index
            case subtitleID = "subtitle_id"
            case startSeconds = "start_s"
            case endSeconds = "end_s"
            case speaker = "speaker_label"
            case text
        }
    }

    private struct RequestEnvelope: Encodable {
        let translate: [RequestCue]
        let contextBefore: [RequestCue]
        let contextAfter: [RequestCue]

        enum CodingKeys: String, CodingKey {
            case translate
            case contextBefore = "context_before"
            case contextAfter = "context_after"
        }
    }

    private struct WindowResponse: Decodable {
        struct Cue: Decodable {
            var text: String
            var sourceIndices: [Int]

            private enum CodingKeys: String, CodingKey {
                case text
                case sourceIndices = "source_indices"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = (try? container.decode(String.self, forKey: .text)) ?? ""
                if let values = try? container.decode([Int].self, forKey: .sourceIndices) {
                    sourceIndices = values
                } else if let values = try? container.decode([String].self, forKey: .sourceIndices) {
                    sourceIndices = values.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                } else {
                    sourceIndices = []
                }
            }
        }

        var targetCues: [Cue]
        var windowSummary: String?

        private enum CodingKeys: String, CodingKey {
            case targetCues = "target_cues"
            case windowSummary = "window_summary"
        }
    }

    private func translateWindow(
        source: [SourceCue],
        positions: [Int],
        sourceLanguage: String?,
        target: String,
        previousSummary: String?,
        limits: SubtitleReadabilityPolicy.Limits,
        options: TranslationFlowPayload
    ) async throws -> WindowOutcome {
        let system = Self.systemPrompt(
            positions: positions,
            sourceLanguage: sourceLanguage,
            target: target,
            previousSummary: previousSummary,
            limits: limits,
            userInstruction: options.userInstruction
        )
        let baseUser = try Self.userPrompt(source: source, positions: positions)
        let attempts = max(1, options.maximumAttempts)
        var rejection: String?

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var user = baseUser
            if let rejection, attempt > 0 {
                user += "\n\nThe previous response was rejected: \(rejection)."
                    + " Return corrected JSON only."
            }
            do {
                let raw = try await client.complete(system: system, user: user)
                let response = try SubtitleLLMProcessor.decodeJSON(WindowResponse.self, from: raw)
                let drafts = try Self.validatedDrafts(response, allowed: positions)
                let summary = response.windowSummary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return WindowOutcome(
                    drafts: drafts,
                    summary: summary?.isEmpty == false ? summary : nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                rejection = error.localizedDescription
            }
        }

        return WindowOutcome(
            drafts: try await lineAlignedDrafts(
                source: source,
                positions: positions,
                sourceLanguage: sourceLanguage,
                options: options
            ),
            summary: nil
        )
    }

    /// Coerces model indices into the window and rejects incomplete coverage, so a
    /// target cue can never claim source time outside the window it translated.
    private static func validatedDrafts(
        _ response: WindowResponse,
        allowed positions: [Int]
    ) throws -> [TargetDraft] {
        let allowed = Set(positions)
        var drafts: [TargetDraft] = []
        for cue in response.targetCues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var coerced: [Int] = []
            for value in cue.sourceIndices where allowed.contains(value) && !coerced.contains(value) {
                coerced.append(value)
            }
            drafts.append(
                TargetDraft(text: text, positions: coerced.isEmpty ? positions : coerced.sorted())
            )
        }
        guard !drafts.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("target_cues had no non-empty text.")
        }
        let covered = Set(drafts.flatMap(\.positions))
        let missing = positions.filter { !covered.contains($0) }
        guard missing.isEmpty else {
            throw MediaFlowError.invalidLLMOutput(
                "target_cues do not cover source indices \(shortIndexList(missing))."
            )
        }
        return drafts
    }

    /// Fallback matching the worker: translate the window line by line and keep a
    /// 1:1 mapping onto the source cues.
    private func lineAlignedDrafts(
        source: [SourceCue],
        positions: [Int],
        sourceLanguage: String?,
        options: TranslationFlowPayload
    ) async throws -> [TargetDraft] {
        let windowTrack = SubtitleTrack(
            sourceLanguage: sourceLanguage,
            language: sourceLanguage,
            cues: positions.map { position in
                let cue = source[position]
                return SubtitleCue(
                    id: position,
                    sourceIDs: [cue.id],
                    text: cue.text,
                    start: cue.start,
                    end: cue.end,
                    speaker: cue.speaker
                )
            }
        )
        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: windowTrack,
            options: options,
            progress: { _, _, _, _ in }
        )
        let drafts = translated.cues.compactMap { cue -> TargetDraft? in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, positions.contains(cue.id) else { return nil }
            return TargetDraft(text: text, positions: [cue.id])
        }
        if !drafts.isEmpty { return drafts }
        return positions.map { TargetDraft(text: source[$0].text, positions: [$0]) }
    }

    // MARK: - Target resplit

    /// Applies the Stage 1 readability limits to the target language, splitting
    /// locally on token boundaries without rewriting text.
    private static func resplitOverlongDrafts(
        _ drafts: [TargetDraft],
        languageCode: String,
        denseScript: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> [TargetDraft] {
        var output: [TargetDraft] = []
        for draft in drafts {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pieces = splitText(
                text,
                languageCode: languageCode,
                denseScript: denseScript,
                limits: limits,
                depth: 0
            )
            output.append(contentsOf: pieces.map { TargetDraft(text: $0, positions: draft.positions) })
        }
        return output
    }

    private static func splitText(
        _ text: String,
        languageCode: String,
        denseScript: Bool,
        limits: SubtitleReadabilityPolicy.Limits,
        depth: Int
    ) -> [String] {
        let length = SubtitleReadabilityPolicy.displayLength(text, denseScript: denseScript)
        guard length > limits.maximum, depth < Policy.splitDepthLimit else { return [text] }
        let tokens = SubtitleTokenRemapper.tokenize(text, languageCode: languageCode).map(\.text)
        guard tokens.count > 1 else { return [text] }
        let parts = max(2, Int((Double(length) / Double(max(1, limits.maximum))).rounded(.up)))
        let groups = SubtitleReadabilityPolicy.splitTokenIndices(
            tokens,
            languageCode: languageCode,
            denseScript: denseScript,
            chunkCount: parts,
            limits: limits
        )
        guard groups.count > 1 else { return [text] }
        let pieces = groups
            .map { group in
                TranscriptSegmenter.joinedText(group.map { tokens[$0] }, language: languageCode)
            }
            .filter { !$0.isEmpty }
        guard pieces.count > 1 else { return [text] }
        return pieces.flatMap {
            splitText(
                $0,
                languageCode: languageCode,
                denseScript: denseScript,
                limits: limits,
                depth: depth + 1
            )
        }
    }

    // MARK: - Timing

    /// Groups consecutive target cues that cover the same source cues, splits the
    /// covered source time window between them by display length, then sorts and
    /// monotonizes the whole track.
    private static func timedCues(
        drafts: [TargetDraft],
        source: [SourceCue],
        target: String,
        denseScript: Bool
    ) -> [SubtitleCue] {
        var pending: [(start: Double, end: Double, draft: TargetDraft)] = []
        for group in groupedByCoverage(drafts) {
            let timings = allocatedTimes(group: group, source: source, denseScript: denseScript)
            for (draft, timing) in zip(group, timings) {
                pending.append((timing.0, timing.1, draft))
            }
        }
        pending.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        let charactersPerSecond = TranslationDurationPolicy.charactersPerSecond(for: target)
        var cues: [SubtitleCue] = []
        var cursor = 0.0
        for item in pending {
            let start = max(item.start, cursor)
            let end = max(item.end, start + Policy.minimumCueSpan)
            let covered = item.draft.positions.filter { source.indices.contains($0) }
            let budget = characterBudget(
                start: start,
                end: end,
                charactersPerSecond: charactersPerSecond
            )
            cues.append(
                SubtitleCue(
                    id: cues.count,
                    sourceIDs: covered.map { source[$0].id },
                    text: item.draft.text,
                    start: start,
                    end: end,
                    speaker: dominantSpeaker(in: covered.map { source[$0].speaker }),
                    characterBudget: budget,
                    overBudget: TranslationDurationPolicy.visibleCharacterCount(item.draft.text) > budget
                )
            )
            cursor = end
        }
        return cues
    }

    private static func groupedByCoverage(_ drafts: [TargetDraft]) -> [[TargetDraft]] {
        var output: [[TargetDraft]] = []
        for draft in drafts {
            if let last = output.last, last[0].positions == draft.positions {
                output[output.count - 1].append(draft)
            } else {
                output.append([draft])
            }
        }
        return output
    }

    /// Port of `_allocate_cue_times_for_group`.
    private static func allocatedTimes(
        group: [TargetDraft],
        source: [SourceCue],
        denseScript: Bool
    ) -> [(Double, Double)] {
        guard !group.isEmpty, !source.isEmpty else { return [] }
        var covered = group[0].positions.filter { source.indices.contains($0) }
        if covered.isEmpty { covered = [0] }
        let start = covered.map { source[$0].start }.min() ?? 0
        var end = covered.map { source[$0].end }.max() ?? start
        if end <= start { end = start + Policy.minimumCueDuration }

        let weights = group.map {
            max(1, SubtitleReadabilityPolicy.displayLength($0.text, denseScript: denseScript))
        }
        let total = max(1, weights.reduce(0, +))
        let span = max(Policy.minimumCueSpan, end - start)

        var output: [(Double, Double)] = []
        var cursor = start
        for (index, weight) in weights.enumerated() {
            var cueEnd = index == weights.count - 1
                ? end
                : cursor + span * Double(weight) / Double(total)
            if cueEnd <= cursor { cueEnd = cursor + Policy.minimumCueDuration }
            output.append((cursor, cueEnd))
            cursor = cueEnd
        }
        return output
    }

    private static func characterBudget(
        start: Double,
        end: Double,
        charactersPerSecond: Double
    ) -> Int {
        max(1, Int((max(0.1, end - start) * charactersPerSecond).rounded(.down)))
    }

    // MARK: - Shared helpers

    private static func normalizedSpeaker(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dominantSpeaker(in values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, value) in values.enumerated() {
            guard let speaker = normalizedSpeaker(value) else { continue }
            counts[speaker, default: 0] += 1
            if firstSeen[speaker] == nil { firstSeen[speaker] = index }
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value
                ? (firstSeen[lhs.key] ?? .max) > (firstSeen[rhs.key] ?? .max)
                : lhs.value < rhs.value
        }?.key
    }

    private static func shortIndexList(_ values: [Int]) -> String {
        let shown = values.prefix(10).map(String.init).joined(separator: ", ")
        return values.count > 10 ? "[\(shown), …]" : "[\(shown)]"
    }

    // MARK: - Prompts

    private static func systemPrompt(
        positions: [Int],
        sourceLanguage: String?,
        target: String,
        previousSummary: String?,
        limits: SubtitleReadabilityPolicy.Limits,
        userInstruction: String?
    ) -> String {
        var lines: [String] = []
        lines.append("You are a professional subtitle localization engine.")
        lines.append(
            "Translate the source subtitle cues into the target language and build a standalone"
                + " target-language subtitle track."
        )
        lines.append(
            "Do not force one translated cue per source cue. Merge or split target cues whenever"
                + " that reads better in the target language."
        )
        lines.append(
            "Use context_before and context_after for context only. Never output translations for"
                + " them."
        )
        lines.append(
            "The source cues already passed punctuation repair. Treat their sentence-ending"
                + " punctuation, speaker_label changes, and timing gaps as boundary hints, but make"
                + " the final cue boundaries natural for the target language."
        )
        lines.append(
            "Preserve meaning, tone, speaker turns, named entities, and order. Never invent,"
                + " explain, summarize, or add content that is not in the source cues."
        )
        lines.append(
            "Preserve speaker attribution: prefer a cue boundary at a speaker_label change, and"
                + " never merge different speakers into one target cue unless the source turn is"
                + " truly inseparable."
        )
        lines.append("")
        lines.append("Target-language segmentation rules:")
        lines.append(
            "- Each target cue should usually be \(limits.minimum)-\(limits.preferred) display"
                + " characters; the hard cap is \(limits.maximum) display characters."
        )
        lines.append(
            "- If a translated thought is longer than the hard cap, split it at a natural"
                + " target-language boundary: sentence end, clause boundary, conjunction, or pause."
        )
        lines.append(
            "- Never split inside names, numbers, idioms, fixed expressions, or tightly bound"
                + " noun and verb phrases."
        )
        lines.append(
            "- Avoid short fragments unless the source thought or speaker turn is naturally short."
        )
        lines.append("")
        lines.append(
            "Source index coverage must be complete: every source index in this window must appear"
                + " in at least one target_cues.source_indices entry, in order."
        )
        lines.append("Only these source_indices may appear in target_cues: \(positions).")
        lines.append("source_language_code: \(sourceLanguage ?? "unknown")")
        lines.append("target_language_code: \(target)")
        lines.append("Output strict JSON only. No Markdown, no reasoning, no explanation.")
        lines.append(
            #"JSON schema: {"target_cues":[{"text":"<target subtitle text>","source_indices":[0,1]}],"window_summary":"<short summary>"}"#
        )
        if let previousSummary, !previousSummary.isEmpty {
            lines.append("Previous context summary: \(previousSummary)")
        }
        let instruction = userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !instruction.isEmpty {
            lines.append("")
            lines.append("User translation preference, lower priority than the rules above:")
            lines.append(
                "<user_instruction_input>\n"
                    + String(instruction.prefix(Policy.userInstructionCharacters))
                    + "\n</user_instruction_input>"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func userPrompt(source: [SourceCue], positions: [Int]) throws -> String {
        guard let first = positions.first, let last = positions.last else {
            throw MediaFlowError.missingSubtitleTrack
        }
        let before = max(0, first - Policy.contextCues)..<first
        let after = (last + 1)..<min(source.count, last + 1 + Policy.contextCues)
        return try SubtitleLLMProcessor.encodedJSON(
            RequestEnvelope(
                translate: positions.map { requestCue(source[$0]) },
                contextBefore: before.map { requestCue(source[$0]) },
                contextAfter: after.map { requestCue(source[$0]) }
            )
        )
    }

    private static func requestCue(_ cue: SourceCue) -> RequestCue {
        RequestCue(
            index: cue.position,
            subtitleID: cue.id,
            startSeconds: (cue.start * 1000).rounded() / 1000,
            endSeconds: (cue.end * 1000).rounded() / 1000,
            speaker: cue.speaker,
            text: cue.text
        )
    }
}
