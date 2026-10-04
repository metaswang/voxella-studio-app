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
        var timingQuality: SubtitleTimingQuality? = nil
        var boundaryBefore: SpeakerBoundary? = nil
    }

    private struct TranslationUnit: Sendable {
        var id: Int
        var sourceIDs: [Int]
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
        var hardBefore = false
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
        let cues = try Self.spottedCues(
            units: units,
            translated: translated,
            languageCode: target,
            denseScript: denseTarget,
            limits: limits
        )
        guard !cues.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("Translation produced no target cues.")
        }
        return SubtitleTrack(sourceLanguage: sourceLanguage, language: target, cues: cues,
                             processingVersion: ElasticSubtitleSegmenter.processingVersion)
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
                speaker: SpeakerLabelResolver.normalized(cue.speaker),
                timingQuality: cue.timingQuality, boundaryBefore: cue.boundaryBefore
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
                    overBudget: TranslationDurationPolicy.visibleCharacterCount(cue.text) > budget,
                    timingQuality: cue.timingQuality,
                    displayLineBreaks: ElasticSubtitleSegmenter.LayoutProfile().measure(cue.text).breaks,
                    boundaryBefore: cue.boundaryBefore
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
                speaker: SpeakerLabelResolver.dominant(in: group.map(\.speaker)),
                hardBefore: group.first?.boundaryBefore == .hard
                    || (group.first?.boundaryBefore == nil && index > 0 && speakersDiffer(groups[index - 1].last?.speaker, group.first?.speaker))
            )
        }
    }

    private static func shouldStartNewUnit(
        current: [SourceCue],
        next: SourceCue,
        languageCode: String?
    ) -> Bool {
        guard let last = current.last, let first = current.first else { return false }
        if next.boundaryBefore == .hard || (next.boundaryBefore == nil && speakersDiffer(last.speaker, next.speaker)) { return true }
        if next.start - last.end >= Policy.packGapSeconds { return true }
        if hasStrongEndPunctuation(last.text) { return true }
        // The 12-second target is advisory; never sever an unfinished clause to hit it.
        if next.end - first.start > Policy.maximumUnitDuration, last.text.last.map(ElasticSubtitleSegmenter.isTerminal) == true { return true }
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
        guard let last = text.last else { return false }
        return ElasticSubtitleSegmenter.isTerminal(last)
    }

    /// Translation units provide timing ownership, not mandatory output cue cuts.
    private static func spottedCues(
        units: [TranslationUnit], translated: SubtitleTrack, languageCode: String,
        denseScript: Bool, limits: SubtitleReadabilityPolicy.Limits
    ) throws -> [SubtitleCue] {
        let byID = Dictionary(translated.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [[TranslationUnit]] = []
        for unit in units {
            if groups.isEmpty || unit.hardBefore { groups.append([unit]) }
            else { groups[groups.count - 1].append(unit) }
        }
        var output: [SubtitleCue] = []
        for group in groups {
            var text = ""
            var ownership: [(range: NSRange, unit: TranslationUnit)] = []
            var suggestions: [String] = []
            var protections: [String] = []
            for unit in group {
                let target = byID[unit.id]?.text ?? ""
                guard !target.isEmpty else { continue }
                let joined = ElasticSubtitleSegmenter.joinChunks([text, target], languageCode: languageCode)
                // Joining may normalize boundary whitespace, but never rebuild tokens.
                let position = (joined as NSString).length - (target as NSString).length
                guard position >= 0, (joined as NSString).substring(from: position) == target else { throw MediaFlowError.invalidLLMOutput("Translation text projection failed.") }
                text = joined
                ownership.append((NSRange(location: position, length: (target as NSString).length), unit))
                suggestions.append(contentsOf: byID[unit.id]?.segmentationHints ?? [])
                protections.append(contentsOf: byID[unit.id]?.protectedSpans ?? [])
            }
            guard let first = group.first, let last = group.last, !text.isEmpty else { continue }
            let layout = ElasticSubtitleSegmenter.LayoutProfile()
            let optimized = try ElasticSubtitleSegmenter.optimize(.init(
                text: text, languageCode: languageCode, proposedLines: suggestions,
                protectedSpans: protections, start: first.start, end: last.end))
            func projectedTime(at offset: Int, isEnd: Bool) -> Double {
                let owner = ownership.first { isEnd ? NSMaxRange($0.range) >= offset : NSMaxRange($0.range) > offset } ?? ownership.last!
                let local = min(owner.range.length, max(0, offset - owner.range.location))
                let unitText = (text as NSString).substring(with: owner.range)
                let prefix = (unitText as NSString).substring(to: local)
                let total = max(0.001, layout.measure(unitText).em)
                let fraction = min(1, max(0, layout.measure(prefix).em / total))
                return owner.unit.start + (owner.unit.end - owner.unit.start) * fraction
            }
            for cue in optimized.cues {
                let owners = ownership.filter { NSIntersectionRange($0.range, cue.range).length > 0 }
                let start = projectedTime(at: cue.range.location, isEnd: false)
                let end = max(start + 0.001, projectedTime(at: NSMaxRange(cue.range), isEnd: true))
                let count = max(1, TranslationDurationPolicy.visibleCharacterCount(cue.text))
                let em = max(0.001, layout.measure(cue.text).em)
                let budget = max(1, Int((8 * (end - start) * Double(count) / em).rounded(.down)))
                output.append(SubtitleCue(id: output.count, sourceIDs: Array(Set(owners.flatMap { $0.unit.sourceIDs })).sorted(),
                    text: cue.text, start: start, end: end,
                    speaker: SpeakerLabelResolver.dominant(in: owners.map { $0.unit.speaker }),
                    characterBudget: budget, overBudget: em / max(0.001, end - start) > 8 || cue.layoutOverflow,
                    timingQuality: .estimated, displayLineBreaks: cue.displayLineBreaks,
                    boundaryBefore: output.isEmpty || (cue.range.location == optimized.cues.first?.range.location && first.hardBefore) ? SpeakerBoundary.hard : SpeakerBoundary.none))
            }
        }
        Log.llm.notice("translation elastic units=\(units.count) cues=\(output.count) long_cues=\(output.filter { $0.end - $0.start > 8 }.count) over_budget=\(output.filter(\.overBudget).count) timing=estimated")
        return output
    }

    static func spottedLines(
        _ text: String, languageCode: String, denseScript: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> [String] {
        do {
            return try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: languageCode,
                maximumCharacters: limits.maximum)).lines
        } catch {
            Log.llm.error("translation elastic failed reason=\(error.localizedDescription)")
            return []
        }
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
