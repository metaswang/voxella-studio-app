import Foundation

/// Builds a target-language subtitle track from a prepared source track.
///
/// Translation is bound 1:1 to packed source units. The model never invents
/// timestamps or free `source_indices`; target-language line splits redistribute
/// time only inside each unit's source span.
struct TranslationTrackBuilder: Sendable {
    let client: any LLMTextClient

    private enum Policy {
        static let packGapSeconds = 0.6
        static let maximumUnitDuration = 12.0
        static let maximumUnitCharacters = 400
        static let minimumCueDuration = 0.5
    }

    private struct SourceCue: Sendable {
        var id: Int
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
    }

    private struct TranslationUnit: Sendable {
        var id: Int
        var sourceIDs: [Int]
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
    }

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
        let units = Self.packedUnits(source, languageCode: sourceLanguage)
        let packedTrack = SubtitleTrack(
            sourceLanguage: sourceLanguage,
            language: sourceLanguage,
            cues: units.map { unit in
                SubtitleCue(
                    id: unit.id,
                    sourceIDs: unit.sourceIDs,
                    text: unit.text,
                    start: unit.start,
                    end: unit.end,
                    speaker: unit.speaker
                )
            }
        )
        Log.llm.notice("translation units=\(units.count) source_cues=\(source.count)")
        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: packedTrack,
            options: options,
            progress: progress
        )
        let cues = Self.spottedCues(
            units: units,
            translated: translated,
            languageCode: target,
            denseScript: denseTarget,
            limits: limits
        )
        guard !cues.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("Translation produced no target cues.")
        }
        return SubtitleTrack(sourceLanguage: sourceLanguage, language: target, cues: cues)
    }

    private static func normalizedSource(_ track: SubtitleTrack) -> [SourceCue] {
        let ordered = track.cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                return lhs.id < rhs.id
            }
        return ordered.map { cue in
            SourceCue(
                id: cue.id,
                text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: cue.start,
                end: cue.end,
                speaker: SpeakerLabelResolver.normalized(cue.speaker)
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

    /// Packs consecutive fragments into sentence-like units. Cuts on strong
    /// punctuation, pauses, speaker changes, and duration or character caps.
    static func packedUnits(
        from track: SubtitleTrack,
        languageCode: String?
    ) -> [[Int]] {
        let source = normalizedSource(track)
        return packedUnits(source, languageCode: languageCode).map(\.sourceIDs)
    }

    private static func packedUnits(
        _ source: [SourceCue],
        languageCode: String?
    ) -> [TranslationUnit] {
        var groups: [[SourceCue]] = []
        var current: [SourceCue] = []
        for cue in source {
            if shouldStartNewUnit(current: current, next: cue, languageCode: languageCode) {
                groups.append(current)
                current = [cue]
            } else {
                current.append(cue)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { index, group in
            let start = group.map(\.start).min() ?? 0
            let end = max(group.map(\.end).max() ?? start, start)
            return TranslationUnit(
                id: index,
                sourceIDs: group.map(\.id),
                text: TranscriptSegmenter.joinedText(group.map(\.text), language: languageCode),
                start: start,
                end: end,
                speaker: SpeakerLabelResolver.dominant(in: group.map(\.speaker))
            )
        }
    }

    private static func shouldStartNewUnit(
        current: [SourceCue],
        next: SourceCue,
        languageCode: String?
    ) -> Bool {
        guard let last = current.last, let first = current.first else { return false }
        if speakersDiffer(last.speaker, next.speaker) { return true }
        if next.start - last.end >= Policy.packGapSeconds { return true }
        if hasStrongEndPunctuation(last.text) { return true }
        if next.end - first.start > Policy.maximumUnitDuration { return true }
        let prospective = TranscriptSegmenter.joinedText(
            current.map(\.text) + [next.text],
            language: languageCode
        )
        return prospective.count > Policy.maximumUnitCharacters
    }

    private static func speakersDiffer(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    private static func hasStrongEndPunctuation(_ text: String) -> Bool {
        guard let last = text.last.map(String.init) else { return false }
        return SubtitleReadabilityPolicy.strongEndPunctuation.contains(last)
    }

    private static func spottedCues(
        units: [TranslationUnit],
        translated: SubtitleTrack,
        languageCode: String,
        denseScript: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> [SubtitleCue] {
        let byID = Dictionary(uniqueKeysWithValues: translated.cues.map { ($0.id, $0) })
        let charactersPerSecond = TranslationDurationPolicy.charactersPerSecond(for: languageCode)
        var cues: [SubtitleCue] = []
        for unit in units {
            let translatedText = byID[unit.id]?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceText = translatedText.isEmpty ? unit.text : translatedText
            let lines = spottedLines(
                sourceText,
                languageCode: languageCode,
                denseScript: denseScript,
                limits: limits
            )
            let timings = allocatedTimes(
                lineCount: lines.count,
                weights: lines.map {
                    max(1, SubtitleReadabilityPolicy.displayLength($0, denseScript: denseScript))
                },
                start: unit.start,
                end: unit.end
            )
            for (index, text) in lines.enumerated() {
                let timing = index < timings.count ? timings[index] : (unit.start, unit.end)
                let budget = characterBudget(
                    start: timing.0,
                    end: timing.1,
                    charactersPerSecond: charactersPerSecond
                )
                cues.append(
                    SubtitleCue(
                        id: cues.count,
                        sourceIDs: unit.sourceIDs,
                        text: text,
                        start: timing.0,
                        end: timing.1,
                        speaker: unit.speaker,
                        characterBudget: budget,
                        overBudget: TranslationDurationPolicy.visibleCharacterCount(text) > budget
                    )
                )
            }
        }
        return cues
    }

    static func spottedLines(
        _ text: String,
        languageCode: String,
        denseScript: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pieces = SubtitleReadabilityPolicy.splitTextByLength(
            trimmed,
            languageCode: languageCode,
            denseScript: denseScript,
            limits: limits
        ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return [trimmed] }
        guard linesPreserveText(pieces, source: trimmed, languageCode: languageCode) else {
            return [trimmed]
        }
        return pieces
    }

    static func linesPreserveText(
        _ lines: [String],
        source: String,
        languageCode: String?
    ) -> Bool {
        canonicalText(lines.joined(separator: languageUsesDenseJoiner(languageCode) ? "" : " "), languageCode: languageCode)
            == canonicalText(source, languageCode: languageCode)
    }

    private static func languageUsesDenseJoiner(_ languageCode: String?) -> Bool {
        SubtitleReadabilityPolicy.usesDenseScript(languageCode: languageCode, sampleText: "")
    }

    private static func canonicalText(_ text: String, languageCode: String?) -> String {
        let normalized = TranscriptSegmenter.normalizeDisplayText(text, language: languageCode)
        if languageUsesDenseJoiner(languageCode) || SubtitleReadabilityPolicy.usesDenseScript(normalized) {
            return normalized.filter { !$0.isWhitespace }
        }
        return normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func allocatedTimes(
        lineCount: Int,
        weights: [Int],
        start: Double,
        end: Double
    ) -> [(Double, Double)] {
        guard lineCount > 0 else { return [] }
        var spanEnd = end
        if spanEnd <= start { spanEnd = start + Policy.minimumCueDuration }
        if lineCount == 1 { return [(start, spanEnd)] }
        let total = max(1, weights.prefix(lineCount).reduce(0, +))
        let span = spanEnd - start
        var output: [(Double, Double)] = []
        var cursor = start
        for index in 0..<lineCount {
            let weight = index < weights.count ? weights[index] : 1
            let cueEnd = index == lineCount - 1
                ? spanEnd
                : cursor + span * Double(weight) / Double(total)
            output.append((cursor, max(cueEnd, cursor)))
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
}
