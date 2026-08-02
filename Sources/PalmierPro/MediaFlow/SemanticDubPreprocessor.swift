import Foundation

enum SemanticDubPreprocessor {
    struct Configuration: Sendable {
        var minimumSequenceCharacters = 40
        var maximumSequenceCharacters = 220
        var maximumTimelineDuration: Double = 12
        var maximumGap: Double = 1.2
    }

    private struct Context: Equatable {
        var speaker: String?
        var reference: DubVoiceReference?
        var options: [String: String]
        var hasSegmentReference: Bool
    }

    private struct Group {
        var segments: [DubSegmentPayload]
        var text: String
    }

    static func preprocess(
        _ payload: DubFlowPayload,
        configuration: Configuration = Configuration()
    ) throws -> [DubSegmentPayload] {
        let normalized = payload.segments
            .sorted { $0.index < $1.index }
            .compactMap { segment -> DubSegmentPayload? in
                let text = normalizeTTSText(
                    TranscriptSegmenter.normalizeDisplayText(
                        segment.text,
                        language: payload.language == "auto" ? nil : payload.language
                    )
                )
                guard !text.isEmpty else { return nil }
                var normalized = segment
                normalized.text = text
                return normalized
            }
        guard !normalized.isEmpty else { throw MediaFlowError.emptyDubScript }

        var groups: [Group] = []
        var pending: [DubSegmentPayload] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let text = joinedText(pending.map(\.text), language: payload.language)
            if !text.isEmpty {
                groups.append(Group(segments: pending, text: text))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for segment in normalized {
            if pending.isEmpty {
                pending = [segment]
                continue
            }

            let previous = pending[pending.count - 1]
            let currentText = joinedText(pending.map(\.text), language: payload.language)
            let contextChanged = context(for: previous, payload: payload)
                != context(for: segment, payload: payload)
                || payload.segmentReferences[previous.index] != nil
                || payload.segmentReferences[segment.index] != nil
            let gapTooLarge = timelineGap(from: previous, to: segment) > configuration.maximumGap
            let durationTooLarge = timelineDuration(
                from: pending.first,
                to: pending.last,
                mode: payload.resolvedTimelineMode
            ) > configuration.maximumTimelineDuration
            let textTooLarge = currentText.count + segment.text.count
                > configuration.maximumSequenceCharacters
            let sentenceComplete = hasSentenceEnd(currentText)

            if contextChanged
                || gapTooLarge
                || durationTooLarge
                || textTooLarge
                || (sentenceComplete
                    && currentText.count >= configuration.minimumSequenceCharacters) {
                flush()
            }
            pending.append(segment)
        }
        flush()

        var output: [DubSegmentPayload] = []
        var usedIndexes = Set<Int>()
        for group in groups {
            let chunks = splitOverlongText(
                group.text,
                maximumCharacters: configuration.maximumSequenceCharacters,
                language: payload.language
            )
            guard !chunks.isEmpty else { continue }

            let start = validTime(group.segments.first?.start)
            let end = validTime(group.segments.last?.end)
            let duration = start.flatMap { start in
                end.map { max(0.001, $0 - start) }
            }

            for (chunkIndex, chunk) in chunks.enumerated() {
                let chunkStart: Double?
                let chunkEnd: Double?
                if payload.resolvedTimelineMode == .audioFlow {
                    chunkStart = nil
                    chunkEnd = nil
                } else if let start, let duration {
                    let fractionStart = Double(chunkIndex) / Double(chunks.count)
                    let fractionEnd = Double(chunkIndex + 1) / Double(chunks.count)
                    chunkStart = start + duration * fractionStart
                    chunkEnd = start + duration * fractionEnd
                } else {
                    chunkStart = start
                    chunkEnd = end
                }

                let isSingleExplicitReference = group.segments.count == 1
                    && payload.segmentReferences[group.segments[0].index] != nil
                    && chunks.count == 1
                let preferredIndex = isSingleExplicitReference
                    ? group.segments[0].index
                    : output.count
                let index = nextAvailableIndex(preferredIndex, used: &usedIndexes)
                output.append(
                    DubSegmentPayload(
                        index: index,
                        text: chunk,
                        start: chunkStart,
                        end: chunkEnd,
                        speaker: group.segments.first?.speaker,
                        sourceSubtitleID: group.segments.first?.sourceSubtitleID,
                        options: group.segments.first?.options ?? [:]
                    )
                )
            }
        }

        guard !output.isEmpty else { throw MediaFlowError.emptyDubScript }
        return output
    }

    private static func context(
        for segment: DubSegmentPayload,
        payload: DubFlowPayload
    ) -> Context {
        let reference = payload.segmentReferences[segment.index]
            ?? segment.speaker.flatMap { payload.speakerReferences[$0] }
            ?? payload.reference
        return Context(
            speaker: segment.speaker?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            reference: reference,
            options: segment.options,
            hasSegmentReference: payload.segmentReferences[segment.index] != nil
        )
    }

    private static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func timelineGap(
        from previous: DubSegmentPayload,
        to current: DubSegmentPayload
    ) -> Double {
        guard let previousEnd = validTime(previous.end),
              let currentStart = validTime(current.start) else { return 0 }
        return max(0, currentStart - previousEnd)
    }

    private static func timelineDuration(
        from first: DubSegmentPayload?,
        to last: DubSegmentPayload?,
        mode: DubTimelineMode
    ) -> Double {
        guard mode == .videoTimeline,
              let start = validTime(first?.start),
              let end = validTime(last?.end) else { return 0 }
        return max(0, end - start)
    }

    private static func nextAvailableIndex(
        _ preferred: Int,
        used: inout Set<Int>
    ) -> Int {
        var candidate = max(0, preferred)
        while used.contains(candidate) {
            candidate += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func joinedText(_ parts: [String], language: String) -> String {
        TranscriptSegmenter.joinedText(
            parts,
            language: language == "auto" ? nil : language
        )
    }

    private static func normalizeTTSText(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "…", with: "……")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for pair in [(" ，", "，"), (" 。", "。"), (" ？", "？"), (" ！", "！"),
                     (" ,", ","), (" .", "."), (" ?", "?"), (" !", "!")] {
            value = value.replacingOccurrences(of: pair.0, with: pair.1)
        }
        return value
    }

    private static func hasSentenceEnd(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".!?。！？…".contains(last)
    }

    private static func splitOverlongText(
        _ text: String,
        maximumCharacters: Int,
        language: String
    ) -> [String] {
        let maximum = max(1, maximumCharacters)
        if text.count <= maximum {
            let sentences = sentenceParts(text, language: language)
            return sentences.count > 1 && text.count >= 40 ? sentences : [text]
        }

        let characters = Array(text)
        var result: [String] = []
        var start = 0
        while start < characters.count {
            let end = min(start + maximum, characters.count)
            if end == characters.count {
                result.append(String(characters[start..<end]))
                break
            }

            let searchStart = max(start + 1, end - maximum / 3)
            let split = (searchStart..<end).last(where: {
                "，,；;：:、。.!?！？ ".contains(characters[$0])
            }) ?? end
            let actualEnd = max(start + 1, split + 1)
            let piece = normalizeTTSText(
                joinedText([String(characters[start..<actualEnd])], language: language)
            )
            if !piece.isEmpty { result.append(piece) }
            start = actualEnd
        }
        return result
    }

    private static func sentenceParts(_ text: String, language: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?。！？…".contains(character) {
                let normalized = normalizeTTSText(
                    joinedText([current], language: language)
                )
                if !normalized.isEmpty {
                    parts.append(normalized)
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        let trailing = normalizeTTSText(joinedText([current], language: language))
        if !trailing.isEmpty {
            parts.append(trailing)
        }
        return parts
    }
}
