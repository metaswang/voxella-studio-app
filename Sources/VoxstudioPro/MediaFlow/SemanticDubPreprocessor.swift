import Foundation

/// Preserve voice/timeline constraints before planning one final set of TTS inputs.
enum SemanticDubPreprocessor {
    struct PreparedSegment: Sendable {
        var segment: DubSegmentPayload
        var reference: DubVoiceReference?
        var chunk: DubChunkPlanner.Chunk
    }

    struct Configuration: Sendable {
        var maximumSequenceCharacters: Int? = nil
        var budget = DubChunkPlanner.Budget()
    }

    private struct Context: Equatable {
        var speaker: String?
        var reference: DubVoiceReference?
        var options: [String: String]
    }

    private struct SourceSpan {
        var segment: DubSegmentPayload
        var range: NSRange
    }

    private struct Group {
        var sources: [SourceSpan] = []
        var text = ""
        var utf16Length = 0

        mutating func append(_ segment: DubSegmentPayload, language: String) {
            if !text.isEmpty {
                // Derive script-sensitive spacing without normalizing the full source again.
                let tail = String(text.suffix(32))
                let head = String(segment.text.prefix(32))
                let joined = TranscriptSegmenter.joinedText([tail, head], language: language == "auto" ? nil : language)
                if joined != tail + head { text += " "; utf16Length += 1 }
            }
            let range = NSRange(location: utf16Length, length: segment.text.utf16.count)
            text += segment.text
            utf16Length += range.length
            sources.append(SourceSpan(segment: segment, range: range))
        }
    }

    static func preprocess(_ payload: DubFlowPayload, configuration: Configuration = Configuration()) throws -> [DubSegmentPayload] {
        try prepare(payload, configuration: configuration).map(\.segment)
    }

    /// The estimate is for offline previews/tests. Live rendering injects Qwen's tokenizer.
    static func prepare(_ payload: DubFlowPayload, configuration: Configuration = Configuration(),
                        tokenCount: (String) -> Int = DubChunkPlanner.estimatedTokenCount) throws -> [PreparedSegment] {
        let normalized = payload.segments.sorted { $0.index < $1.index }.compactMap { segment -> DubSegmentPayload? in
            let text = normalize(segment.text, language: payload.language)
            guard !text.isEmpty else { return nil }
            var value = segment
            value.text = text
            return value
        }
        guard !normalized.isEmpty else { throw MediaFlowError.emptyDubScript }
        let timelineMode = payload.resolvedTimelineMode
        var groups: [Group] = []
        var pending = Group()
        for segment in normalized {
            try Task.checkCancellation()
            if let previous = pending.sources.last?.segment {
                let hardBoundary = context(for: previous, payload: payload) != context(for: segment, payload: payload)
                    || payload.segmentReferences[previous.index] != nil || payload.segmentReferences[segment.index] != nil
                    // Explicit video anchors are independent fitting windows. Audio-only
                    // requests deliberately ignore imported subtitle timestamps.
                    || (timelineMode == .videoTimeline
                        && (validTime(previous.start) != nil || validTime(segment.start) != nil))
                if hardBoundary { groups.append(pending); pending = Group() }
            }
            pending.append(segment, language: payload.language)
        }
        if !pending.sources.isEmpty { groups.append(pending) }

        var budget = configuration.budget
        let limits = [budget.maximumCharacters, configuration.maximumSequenceCharacters, payload.maximumChunkCharacters].compactMap { $0 }
        budget.maximumCharacters = limits.min()
        var output: [PreparedSegment] = []
        // Reserve original explicit-voice keys so a split chunk never accidentally
        // masquerades as another original segment when it is reindexed.
        var usedIndexes = Set(payload.segmentReferences.keys)
        for group in groups {
            try Task.checkCancellation()
            let plan = try DubChunkPlanner.plan(group.text, language: payload.language, budget: budget, tokenCount: tokenCount)
            let first = group.sources[0].segment
            let start = validTime(first.start)
            let end = validTime(group.sources.last?.segment.end)
            let duration = start.flatMap { a in end.flatMap { $0 > a ? $0 - a : nil } }
            let weight = max(0.001, plan.chunks.reduce(0) { $0 + max(0.001, $1.estimatedSeconds) })
            var elapsedWeight: Double = 0
            var sourceCursor = 0
            for (position, chunk) in plan.chunks.enumerated() {
                while sourceCursor + 1 < group.sources.count,
                      NSMaxRange(group.sources[sourceCursor].range) <= chunk.range.location { sourceCursor += 1 }
                let source = group.sources[sourceCursor].segment
                let chunkWeight = max(0.001, chunk.estimatedSeconds)
                let chunkStart: Double?
                let chunkEnd: Double?
                if timelineMode == .audioFlow {
                    chunkStart = nil; chunkEnd = nil
                } else if let start, let duration {
                    chunkStart = start + duration * elapsedWeight / weight
                    chunkEnd = position == plan.chunks.count - 1 ? end : start + duration * (elapsedWeight + chunkWeight) / weight
                } else {
                    chunkStart = start; chunkEnd = end
                }
                elapsedWeight += chunkWeight
                let retainIndex = group.sources.count == 1 && plan.chunks.count == 1 && payload.segmentReferences[first.index] != nil
                if retainIndex { usedIndexes.remove(first.index) }
                let index = nextAvailableIndex(retainIndex ? first.index : output.count, used: &usedIndexes)
                output.append(PreparedSegment(segment: DubSegmentPayload(
                    index: index, text: chunk.text, start: chunkStart, end: chunkEnd,
                    speaker: first.speaker, sourceSubtitleID: source.sourceSubtitleID, options: source.options
                ), reference: payload.reference(for: first), chunk: chunk))
            }
        }
        guard !output.isEmpty else { throw MediaFlowError.emptyDubScript }
        return output
    }

    private static func normalize(_ text: String, language: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n").replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: #"\n[\t\p{Zs}]*\n(?:[\t\p{Zs}]*\n)*"#, with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .map { TranscriptSegmenter.normalizeDisplayText($0, language: language == "auto" ? nil : language)
                .replacingOccurrences(of: "…", with: "……").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func context(for segment: DubSegmentPayload, payload: DubFlowPayload) -> Context {
        Context(speaker: segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                reference: payload.reference(for: segment), options: segment.options)
    }

    private static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func nextAvailableIndex(_ preferred: Int, used: inout Set<Int>) -> Int {
        var candidate = max(0, preferred)
        while used.contains(candidate) { candidate += 1 }
        used.insert(candidate)
        return candidate
    }
}
