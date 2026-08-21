import Foundation

struct SubtitlePostprocessResult: Sendable {
    var track: SubtitleTrack
    var rebuiltSegments: [TranscriptionSegment]
    var warnings: [String]
}

/// Subtitle postprocessing: correct and punctuate text, segment it without
/// further edits, align the final text to source word timings, then rebuild
/// long transcript segments from the timed cues.
///
/// The LLM never owns absolute time and never translates. Timing always comes
/// from a monotonic partition of ASR words. Low-confidence remap gaps interpolate
/// instead of replacing the corrected text with raw ASR wording.
struct SubtitlePostprocessPipeline: Sendable {
    let client: any LLMTextClient

    private enum Policy {
        static let maximumSegmentDuration: Double = 10
        static let pauseSplitMinimum: Double = 0.25
        static let rebuildTargetDuration: Double = 60
        static let rebuildMaximumDuration: Double = 60
        static let rebuildMinimumDuration: Double = 45
    }

    private static let strongEndPunctuation = SubtitleReadabilityPolicy.strongEndPunctuation
    private static let weakEndPunctuation = SubtitleReadabilityPolicy.weakEndPunctuation

    // MARK: - Entry points

    /// Convenience for callers that only need the cleaned subtitle track.
    func processTrack(
        transcript: TranscriptionResult,
        options: SubtitleProcessingPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitleTrack {
        try await process(transcript: transcript, options: options, progress: progress).track
    }

    func process(
        transcript: TranscriptionResult,
        options: SubtitleProcessingPayload,
        progress: @escaping @Sendable (Double, Int?, Int?, String) -> Void
    ) async throws -> SubtitlePostprocessResult {
        let sourceWords = Self.makeSourceWords(from: transcript)
        guard !sourceWords.isEmpty else { throw MediaFlowError.missingTranscript }

        let languageCode = transcript.language
        let isCJK = Self.usesDenseScript(languageCode: languageCode, sampleText: transcript.text)
        let limits = Self.limits(
            isCJK: isCJK,
            overridingMaximum: options.maximumCharactersPerCue
        )

        let batches = Self.makeBatches(sourceWords: sourceWords, transcript: transcript, options: options)
        guard !batches.isEmpty else { throw MediaFlowError.missingTranscript }

        let batchTexts = batches.map { batch in
            TranscriptSegmenter.joinedText(
                sourceWords[batch].map(\.text),
                language: languageCode
            )
        }

        let maximumConcurrentBatches = min(
            max(1, options.maximumConcurrentBatches),
            batches.count
        )
        progress(
            0,
            0,
            batches.count,
            "Cleaning and segmenting subtitle batches…"
        )

        var outcomes = Array<BatchOutcome?>(repeating: nil, count: batches.count)
        try await withThrowingTaskGroup(of: IndexedBatchOutcome.self) { group in
            var nextBatchIndex = 0
            for _ in 0..<maximumConcurrentBatches {
                let batchIndex = nextBatchIndex
                nextBatchIndex += 1
                group.addTask {
                    try await self.processBatch(
                        index: batchIndex,
                        batch: batches[batchIndex],
                        batchTexts: batchTexts,
                        sourceWords: sourceWords,
                        languageCode: languageCode,
                        isCJK: isCJK,
                        limits: limits,
                        options: options
                    )
                }
            }

            var completedBatches = 0
            while let result = try await group.next() {
                outcomes[result.index] = result.outcome
                completedBatches += 1
                progress(
                    Double(completedBatches) / Double(batches.count),
                    completedBatches,
                    batches.count,
                    "Cleaned and segmented subtitle batch \(result.index + 1) (\(completedBatches) of \(batches.count) complete)…"
                )

                if nextBatchIndex < batches.count {
                    let batchIndex = nextBatchIndex
                    nextBatchIndex += 1
                    group.addTask {
                        try await self.processBatch(
                            index: batchIndex,
                            batch: batches[batchIndex],
                            batchTexts: batchTexts,
                            sourceWords: sourceWords,
                            languageCode: languageCode,
                            isCJK: isCJK,
                            limits: limits,
                            options: options
                        )
                    }
                }
            }
        }

        var cues: [PendingCue] = []
        var warnings: [String] = []
        for outcome in outcomes.compactMap({ $0 }) {
            if let warning = outcome.warning { warnings.append(warning) }
            cues.append(contentsOf: outcome.cues)
        }

        guard !cues.isEmpty else {
            throw MediaFlowError.invalidLLMOutput("No usable subtitle output for any batch.")
        }

        let track = SubtitleTrack(
            sourceLanguage: languageCode,
            language: languageCode,
            cues: cues.enumerated().map { index, cue in
                SubtitleCue(
                    id: index,
                    sourceIDs: cue.sourceIndices,
                    text: cue.text,
                    start: cue.start,
                    end: cue.end,
                    speaker: cue.speaker,
                    overBudget: cue.overBudget
                )
            },
            usesWordTimestamps: true
        )
        let rebuilt = Self.rebuildSegments(from: cues, languageCode: languageCode)

        progress(1, batches.count, batches.count, "Subtitles cleaned and segmented")
        return SubtitlePostprocessResult(track: track, rebuiltSegments: rebuilt, warnings: warnings)
    }

    private func processBatch(
        index: Int,
        batch: Range<Int>,
        batchTexts: [String],
        sourceWords: [SourceWord],
        languageCode: String?,
        isCJK: Bool,
        limits: SubtitleReadabilityPolicy.Limits,
        options: SubtitleProcessingPayload
    ) async throws -> IndexedBatchOutcome {
        try Task.checkCancellation()
        let words = Array(sourceWords[batch])
        let batchText = batchTexts[index]
        guard !batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return IndexedBatchOutcome(index: index, outcome: BatchOutcome(cues: [], warning: nil))
        }

        let context = SubtitleCascadePrompt.neighboringContext(
            batchTexts: batchTexts,
            index: index
        )
        let outcome = try await cascade(
            words: words,
            batchText: batchText,
            contextBefore: context.before,
            contextAfter: context.after,
            languageCode: languageCode,
            speaker: SpeakerLabelResolver.dominant(in: words.map(\.speaker)),
            isCJK: isCJK,
            limits: limits,
            options: options
        )
        return IndexedBatchOutcome(index: index, outcome: outcome)
    }

    // MARK: - Source model

    private struct SourceWord: Sendable {
        var index: Int
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
        var speakerConfidence: Double?
        var speakerBoundary: SpeakerBoundary
    }

    private struct PendingCue: Sendable {
        var text: String
        var tokens: [SubtitleRemappedWord]
        var start: Double
        var end: Double
        var sourceIndices: [Int]
        var speaker: String?
        var overBudget: Bool
    }

    private struct BatchOutcome: Sendable {
        var cues: [PendingCue]
        var warning: String?
    }

    private struct IndexedBatchOutcome: Sendable {
        let index: Int
        let outcome: BatchOutcome
    }

    private static func makeSourceWords(from transcript: TranscriptionResult) -> [SourceWord] {
        var words: [SourceWord] = []
        for word in transcript.words {
            guard let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, end > start,
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            words.append(
                SourceWord(
                    index: words.count,
                    text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: start,
                    end: end,
                    speaker: SpeakerLabelResolver.normalized(word.speaker),
                    speakerConfidence: word.speakerConfidence,
                    speakerBoundary: word.speakerBoundary
                )
            )
        }
        if !words.isEmpty { return words }

        for segment in transcript.segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            words.append(
                SourceWord(
                    index: words.count,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: segment.start,
                    end: segment.end,
                    speaker: SpeakerLabelResolver.normalized(segment.speaker),
                    speakerConfidence: nil,
                    speakerBoundary: segment.speakerBoundary
                )
            )
        }
        return words
    }

    // MARK: - Resplit and batching

    /// Mirrors `_resplit_raw_segments_by_word_speaker` followed by
    /// `_group_raw_segments_by_language_boundary`: ASR segment boundaries are
    /// preserved, split further at word-speaker runs and long spans, short
    /// same-speaker neighbours merge, and batches never cross a speaker change.
    private static func makeBatches(
        sourceWords: [SourceWord],
        transcript: TranscriptionResult,
        options: SubtitleProcessingPayload
    ) -> [Range<Int>] {
        var segments = splitBySpeakerRuns(
            transcriptSegmentRanges(sourceWords: sourceWords, transcript: transcript),
            sourceWords: sourceWords
        )
        segments = splitLongSegments(segments, sourceWords: sourceWords)
        segments = mergeShortSegments(segments, sourceWords: sourceWords)

        let segmentLimit = max(1, options.maximumSegmentsPerBatch)
        let wordLimit = max(1, options.maximumTokensPerBatch)

        var batches: [Range<Int>] = []
        var current: Range<Int>?
        var currentCount = 0
        var currentSpeaker: String?

        for segment in segments {
            let speaker = SpeakerLabelResolver.dominant(in: sourceWords[segment].map(\.speaker))
            let crossesSpeaker = current != nil
                && currentSpeaker != nil
                && speaker != nil
                && speaker != currentSpeaker
            let startsHardBoundary = sourceWords[segment.lowerBound].speakerBoundary == .hard
            if let open = current,
               currentCount >= segmentLimit
                || open.count + segment.count > wordLimit
                || crossesSpeaker
                || startsHardBoundary {
                batches.append(open)
                current = nil
                currentCount = 0
                currentSpeaker = nil
            }
            if let open = current {
                current = open.lowerBound..<segment.upperBound
            } else {
                current = segment
                currentSpeaker = speaker
            }
            currentCount += 1
        }
        if let open = current { batches.append(open) }
        return batches
    }

    private static func transcriptSegmentRanges(
        sourceWords: [SourceWord],
        transcript: TranscriptionResult
    ) -> [Range<Int>] {
        var cuts: [Int] = [0]
        for segment in transcript.segments.sorted(by: { $0.start < $1.start }) {
            guard let index = sourceWords.firstIndex(where: { $0.start >= segment.start - 1e-6 }),
                  index > (cuts.last ?? 0) else { continue }
            cuts.append(index)
        }
        return zip(cuts, cuts.dropFirst() + [sourceWords.count])
            .map { $0..<$1 }
            .filter { !$0.isEmpty }
    }

    private static func splitBySpeakerRuns(
        _ ranges: [Range<Int>],
        sourceWords: [SourceWord]
    ) -> [Range<Int>] {
        var output: [Range<Int>] = []
        for range in ranges {
            var start = range.lowerBound
            var speaker = sourceWords[start].speaker
            for index in (range.lowerBound + 1)..<range.upperBound {
                let word = sourceWords[index]
                if word.speaker != speaker || word.speakerBoundary == .hard {
                    output.append(start..<index)
                    start = index
                    speaker = word.speaker
                }
            }
            output.append(start..<range.upperBound)
        }
        return output
    }

    private static func splitLongSegments(
        _ ranges: [Range<Int>],
        sourceWords: [SourceWord]
    ) -> [Range<Int>] {
        var output: [Range<Int>] = []
        for range in ranges {
            var start = range.lowerBound
            while start < range.upperBound {
                let anchor = sourceWords[start].start
                var end = range.upperBound
                var index = start
                while index < range.upperBound {
                    if sourceWords[index].end - anchor > Policy.maximumSegmentDuration, index > start {
                        end = index
                        break
                    }
                    index += 1
                }
                if end < range.upperBound {
                    end = bestPauseCut(in: start..<end, sourceWords: sourceWords) ?? end
                }
                output.append(start..<end)
                start = end
            }
        }
        return output
    }

    private static func bestPauseCut(in range: Range<Int>, sourceWords: [SourceWord]) -> Int? {
        guard range.count > 1 else { return nil }
        var best: Int?
        var bestGap = Policy.pauseSplitMinimum
        for index in (range.lowerBound + 1)..<range.upperBound {
            let gap = sourceWords[index].start - sourceWords[index - 1].end
            if gap >= bestGap {
                bestGap = gap
                best = index
            }
        }
        return best
    }

    private static func mergeShortSegments(
        _ ranges: [Range<Int>],
        sourceWords: [SourceWord]
    ) -> [Range<Int>] {
        var output: [Range<Int>] = []
        for range in ranges {
            guard let previous = output.last,
                  previous.upperBound == range.lowerBound,
                  sourceWords[range.lowerBound].speakerBoundary != .hard,
                  SpeakerLabelResolver.dominant(in: sourceWords[previous].map(\.speaker))
                    == SpeakerLabelResolver.dominant(in: sourceWords[range].map(\.speaker)),
                  sourceWords[range.upperBound - 1].end - sourceWords[previous.lowerBound].start
                    <= Policy.maximumSegmentDuration else {
                output.append(range)
                continue
            }
            output[output.count - 1] = previous.lowerBound..<range.upperBound
        }
        return output
    }

    // MARK: - Two-pass text cascade

    private struct CorrectionResponse: Decodable {
        let text: String
    }

    private struct SegmentationResponse: Decodable {
        let lines: [String]
    }

    private func cascade(
        words: [SourceWord],
        batchText: String,
        contextBefore: String?,
        contextAfter: String?,
        languageCode: String?,
        speaker: String?,
        isCJK: Bool,
        limits: SubtitleReadabilityPolicy.Limits,
        options: SubtitleProcessingPayload
    ) async throws -> BatchOutcome {
        let correctionSystem = SubtitleCascadePrompt.correctionSystem(
            languageCode: languageCode,
            isCJK: isCJK
        )
        let correctionBaseUser = SubtitleCascadePrompt.correctionUser(
            batchText: batchText,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            languageCode: languageCode,
            speaker: speaker,
            limits: limits,
            userInstruction: options.userInstruction
        )
        let segmentationSystem = SubtitleCascadePrompt.segmentationSystem(
            languageCode: languageCode,
            isCJK: isCJK,
            limits: limits
        )
        let attempts = max(1, options.maximumAttempts)
        var failureReason: String?
        var failureStage: SubtitleCascadePrompt.Stage?

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var correctionUser = correctionBaseUser
            if let failureReason, failureStage == .correction, attempt > 0 {
                correctionUser += "\n\n" + SubtitleCascadePrompt.retry(
                    stage: .correction,
                    reason: failureReason
                )
            }

            let correctionRaw: String
            do {
                correctionRaw = try await client.complete(
                    system: correctionSystem,
                    user: correctionUser
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failureReason = "correction_request_failed"
                failureStage = .correction
                continue
            }

            let correction: CorrectionResponse
            do {
                correction = try SubtitleLLMProcessor.decodeJSON(
                    CorrectionResponse.self,
                    from: correctionRaw
                )
            } catch {
                failureReason = "invalid_correction_json"
                failureStage = .correction
                continue
            }

            let correctedText = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !correctedText.isEmpty else {
                failureReason = "empty_correction"
                failureStage = .correction
                continue
            }
            if let reason = Self.correctionFailureReason(
                correctedText: correctedText,
                sourceText: batchText,
                sourceWordCount: words.count,
                isCJK: isCJK,
                limits: limits
            ) {
                failureReason = reason
                failureStage = .correction
                continue
            }

            var segmentationUser = SubtitleCascadePrompt.segmentationUser(
                correctedText: correctedText,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                languageCode: languageCode,
                speaker: speaker,
                limits: limits,
                userInstruction: options.userInstruction
            )
            if let failureReason, failureStage == .segmentation, attempt > 0 {
                segmentationUser += "\n\n" + SubtitleCascadePrompt.retry(
                    stage: .segmentation,
                    reason: failureReason
                )
            }

            let segmentationRaw: String
            do {
                segmentationRaw = try await client.complete(
                    system: segmentationSystem,
                    user: segmentationUser
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failureReason = "segmentation_request_failed"
                failureStage = .segmentation
                continue
            }

            let segmentation: SegmentationResponse
            do {
                segmentation = try SubtitleLLMProcessor.decodeJSON(
                    SegmentationResponse.self,
                    from: segmentationRaw
                )
            } catch {
                failureReason = "invalid_segmentation_json"
                failureStage = .segmentation
                continue
            }

            let subtitles = segmentation.lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let reason = Self.segmentationFailureReason(
                subtitles: subtitles,
                correctedText: correctedText,
                sourceWordCount: words.count,
                languageCode: languageCode,
                isCJK: isCJK,
                limits: limits
            ) {
                failureReason = reason
                failureStage = .segmentation
                continue
            }

            let tokens = SubtitleTokenRemapper.buildDestinationTokens(
                fromSubtitles: subtitles,
                languageCode: languageCode
            )
            let remap = SubtitleTokenRemapper.remap(
                sourceWords: words.map {
                    SubtitleRemapSourceWord(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker)
                },
                destinationTokens: tokens,
                batchStart: words[0].start,
                batchEnd: words[words.count - 1].end,
                languageCode: languageCode
            )

            let cues = Self.makeCues(
                subtitles: subtitles,
                remap: remap,
                words: words,
                isCJK: isCJK
            )
            guard cues.count == subtitles.count,
                  Self.cuesCoverSourceWords(cues, words: words) else {
                throw MediaFlowError.invalidLLMOutput(
                    "Subtitle batch at \(String(format: "%.1f", words[0].start))s "
                        + "could not assign source-word timings."
                )
            }
            let warning = remap.usesAnchorTiming
                ? nil
                : "Used source-word timing for LLM subtitles."
            return BatchOutcome(cues: cues, warning: warning)
        }

        Log.llm.warning(
            "subtitle batch failed after \(attempts) two-pass attempts at "
                + "\(String(format: "%.1f", words[0].start))s reason=\(failureReason ?? "unknown")"
        )
        throw MediaFlowError.invalidLLMOutput(
            "Subtitle batch at \(String(format: "%.1f", words[0].start))s "
                + "failed after \(attempts) attempts (\(failureReason ?? "unknown"))."
        )
    }

    private static func correctionFailureReason(
        correctedText: String,
        sourceText: String,
        sourceWordCount: Int,
        isCJK: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> String? {
        if correctedText.isEmpty { return "empty_correction" }
        if SubtitleReadabilityPolicy.containsForeignPunctuation(
            correctedText,
            denseScript: isCJK
        ) {
            return "wrong_script_punctuation"
        }
        if isCJK, SubtitleReadabilityPolicy.containsStrandedBoundParticle(correctedText) {
            return "stranded_bound_particle"
        }
        if let reason = punctuationFailureReason(
            subtitles: [correctedText],
            isCJK: isCJK,
            limits: limits
        ) {
            return reason
        }
        let sourceLength = max(1, displayLength(sourceText, isCJK: isCJK))
        let outputLength = displayLength(correctedText, isCJK: isCJK)
        guard sourceWordCount >= 3 else { return nil }
        if outputLength <= max(1, Int(Double(sourceLength) * 0.12)) { return "near_empty_output" }
        if outputLength >= sourceLength * 6 { return "extreme_output_expansion" }
        return nil
    }

    private static func segmentationFailureReason(
        subtitles: [String],
        correctedText: String,
        sourceWordCount: Int,
        languageCode: String?,
        isCJK: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> String? {
        guard !subtitles.isEmpty else { return "empty_lines" }
        guard subtitles.count <= sourceWordCount else {
            return "excessive_subtitle_count"
        }
        let joined = subtitles.joined(separator: isCJK ? "" : " ")
        guard canonicalText(joined, languageCode: languageCode)
                == canonicalText(correctedText, languageCode: languageCode) else {
            return "segmentation_changed_text"
        }
        if subtitles.contains(where: {
            displayLength($0, isCJK: isCJK) > limits.maximum
        }) {
            return "overlong_subtitle_line"
        }
        if subtitles.contains(where: {
            SubtitleReadabilityPolicy.containsForeignPunctuation($0, denseScript: isCJK)
        }) {
            return "wrong_script_punctuation"
        }
        return nil
    }

    private static func punctuationFailureReason(
        subtitles: [String],
        isCJK: Bool,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> String? {
        if subtitles.contains(where: {
            SubtitleReadabilityPolicy.containsForeignPunctuation($0, denseScript: isCJK)
        }) {
            return "wrong_script_punctuation"
        }
        let total = subtitles.reduce(0) { $0 + displayLength($1, isCJK: isCJK) }
        guard total > 0 else { return nil }
        if subtitles.contains(where: { line in
            displayLength(line, isCJK: isCJK) > 0
                && !SubtitleReadabilityPolicy.containsAllowedPunctuation(line, denseScript: isCJK)
        }) {
            return "missing_punctuation"
        }
        if let last = subtitles.last,
           !SubtitleReadabilityPolicy.endsWithAllowedPunctuation(last, denseScript: isCJK) {
            return "missing_punctuation"
        }
        let joined = subtitles.joined()
        if SubtitleReadabilityPolicy.containsUnderpunctuatedRun(
            joined,
            denseScript: isCJK,
            maximumRun: limits.maximum
        ) {
            return "missing_punctuation"
        }
        return nil
    }

    private static func makeCues(
        subtitles: [String],
        remap: SubtitleRemapResult,
        words: [SourceWord],
        isCJK: Bool
    ) -> [PendingCue] {
        let partitions = SubtitleTimingPartitioner.partition(
            cueCount: subtitles.count,
            sourceWordCount: words.count,
            anchorRanges: remap.sourceAnchorRangesBySubtitle,
            weights: subtitles.map { displayLength($0, isCJK: isCJK) }
        )
        guard partitions.count == subtitles.count else { return [] }
        var cues: [PendingCue] = []
        cues.reserveCapacity(subtitles.count)
        for (index, text) in subtitles.enumerated() {
            let tokens = index < remap.wordsBySubtitle.count ? remap.wordsBySubtitle[index] : []
            let sourceRange = partitions[index]
            guard let first = words[sourceRange].first, let last = words[sourceRange].last else { continue }
            cues.append(
                PendingCue(
                    text: text,
                    tokens: tokens,
                    start: first.start,
                    end: max(first.start, last.end),
                    sourceIndices: words[sourceRange].map(\.index),
                    speaker: SpeakerLabelResolver.dominant(in: tokens.map(\.speaker)),
                    overBudget: false
                )
            )
        }

        let wordByIndex = Dictionary(uniqueKeysWithValues: words.map { ($0.index, $0) })
        for index in cues.indices {
            if let first = cues[index].sourceIndices.first.flatMap({ wordByIndex[$0] }),
               let last = cues[index].sourceIndices.last.flatMap({ wordByIndex[$0] }) {
                cues[index].start = first.start
                cues[index].end = max(first.start, last.end)
            }
            if cues[index].speaker == nil {
                cues[index].speaker = SpeakerLabelResolver.dominant(
                    in: cues[index].sourceIndices.map { wordByIndex[$0]?.speaker }
                )
            }
        }
        // A cue the source timeline cannot anchor at all is model output with no
        // place on the timeline; keeping it would emit a zero-duration subtitle.
        let anchored = cues.filter { !$0.sourceIndices.isEmpty }
        return anchored.isEmpty ? cues : anchored
    }

    private static func cuesCoverSourceWords(
        _ cues: [PendingCue],
        words: [SourceWord]
    ) -> Bool {
        guard !cues.isEmpty, !words.isEmpty else { return false }
        let actual = cues.flatMap(\.sourceIndices)
        let expected = words.map(\.index)
        guard actual == expected else { return false }
        guard cues.allSatisfy({ !$0.sourceIndices.isEmpty }) else { return false }
        for pair in zip(cues, cues.dropFirst()) {
            guard let left = pair.0.sourceIndices.last,
                  let right = pair.1.sourceIndices.first,
                  right == left + 1 else {
                return false
            }
        }
        return true
    }

    private static func canonicalText(_ text: String, languageCode: String?) -> String {
        let normalized = TranscriptSegmenter.normalizeDisplayText(text, language: languageCode)
        let dense = SubtitleReadabilityPolicy.usesDenseScript(
            languageCode: languageCode,
            sampleText: normalized
        )
        if dense {
            return normalized.filter { !$0.isWhitespace }
        }
        return normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Rebuild

    /// Port of `rebuild_transcript_segments_from_subtitles`: merge cues into long
    /// transcript segments, cutting only on cue boundaries and never across a
    /// known speaker change.
    private static func rebuildSegments(
        from cues: [PendingCue],
        languageCode: String?
    ) -> [TranscriptionSegment] {
        let ordered = cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard !ordered.isEmpty else { return [] }

        let target = Policy.rebuildTargetDuration
        let maximum = Policy.rebuildMaximumDuration
        let minimum = Policy.rebuildMinimumDuration

        var output: [TranscriptionSegment] = []
        var buffer: [PendingCue] = []

        func emit(_ upTo: Int) {
            let chunk = Array(buffer.prefix(upTo))
            buffer.removeFirst(min(upTo, buffer.count))
            guard let first = chunk.first, let last = chunk.last else { return }
            output.append(
                TranscriptionSegment(
                    text: TranscriptSegmenter.joinedText(chunk.map(\.text), language: languageCode),
                    start: first.start,
                    end: max(first.start, last.end),
                    speaker: SpeakerLabelResolver.dominant(in: chunk.map(\.speaker)),
                    speakerBoundary: .none
                )
            )
        }

        var index = 0
        while index < ordered.count {
            let cue = ordered[index]
            if buffer.isEmpty {
                buffer = [cue]
                index += 1
                continue
            }
            let previousSpeaker = buffer[buffer.count - 1].speaker
            if let previousSpeaker, let speaker = cue.speaker, previousSpeaker != speaker {
                emit(buffer.count)
                continue
            }

            buffer.append(cue)
            index += 1

            let start = buffer[0].start
            let duration = max(0, buffer[buffer.count - 1].end - start)
            let exceeded = duration > maximum + 1e-9
            guard duration + 1e-9 >= minimum || exceeded else { continue }

            var bestCut: Int?
            var bestScore: Double?
            var cut = buffer.count
            while cut > 1 {
                defer { cut -= 1 }
                let cutDuration = buffer[cut - 1].end - start
                if !exceeded, cutDuration > maximum + 1e-9 { continue }
                if !exceeded, cutDuration + 1e-9 < minimum { break }

                let leftSpeaker = buffer[cut - 1].speaker
                let rightSpeaker = cut < buffer.count ? buffer[cut].speaker : nil
                let speakerBoundary = leftSpeaker != nil && rightSpeaker != nil && leftSpeaker != rightSpeaker
                if speakerBoundary, !exceeded {
                    bestCut = cut
                    break
                }

                let boundary = lastToken(of: buffer[cut - 1])
                var punctuationRank = 0
                if strongEndPunctuation.contains(boundary) {
                    punctuationRank = 3
                } else if weakEndPunctuation.contains(boundary) {
                    punctuationRank = 2
                }
                let score = Double(punctuationRank * 1000 + (speakerBoundary ? 50 : 0))
                    - abs(cutDuration - target)
                if score > (bestScore ?? -.infinity) {
                    bestScore = score
                    bestCut = cut
                }
            }
            emit(bestCut ?? max(1, buffer.count - 1))
        }
        if !buffer.isEmpty { emit(buffer.count) }

        return markSpeakerBoundaries(mergingShortTail(output, languageCode: languageCode))
    }

    private static func mergingShortTail(
        _ segments: [TranscriptionSegment],
        languageCode: String?
    ) -> [TranscriptionSegment] {
        guard segments.count >= 2 else { return segments }
        let last = segments[segments.count - 1]
        let previous = segments[segments.count - 2]
        let lastDuration = last.end - last.start
        guard lastDuration + 1e-9 < Policy.rebuildMinimumDuration else { return segments }
        let grace = max(5.0, 0.10 * Policy.rebuildMaximumDuration)
        guard previous.end - previous.start + lastDuration
                <= Policy.rebuildMaximumDuration + grace + 1e-9,
              previous.speaker == nil || last.speaker == nil || previous.speaker == last.speaker else {
            return segments
        }
        var merged = Array(segments.dropLast(2))
        merged.append(
            TranscriptionSegment(
                text: TranscriptSegmenter.joinedText([previous.text, last.text], language: languageCode),
                start: previous.start,
                end: last.end,
                speaker: previous.speaker ?? last.speaker,
                speakerBoundary: previous.speakerBoundary
            )
        )
        return merged
    }

    private static func markSpeakerBoundaries(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var previousSpeaker: String?
        return segments.map { segment in
            defer { previousSpeaker = segment.speaker ?? previousSpeaker }
            let boundary: SpeakerBoundary = previousSpeaker != nil
                && segment.speaker != nil
                && previousSpeaker != segment.speaker ? .hard : .none
            return TranscriptionSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker,
                speakerBoundary: boundary
            )
        }
    }

    private static func lastToken(of cue: PendingCue) -> String {
        for token in cue.tokens.reversed() {
            let value = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : String(text.suffix(1))
    }

    private static func usesDenseScript(languageCode: String?, sampleText: String) -> Bool {
        SubtitleReadabilityPolicy.usesDenseScript(languageCode: languageCode, sampleText: sampleText)
    }

    private static func limits(
        isCJK: Bool,
        overridingMaximum: Int?
    ) -> SubtitleReadabilityPolicy.Limits {
        SubtitleReadabilityPolicy.limits(denseScript: isCJK, overridingMaximum: overridingMaximum)
    }

    private static func displayLength(_ text: String, isCJK: Bool) -> Int {
        SubtitleReadabilityPolicy.displayLength(text, denseScript: isCJK)
    }
}
