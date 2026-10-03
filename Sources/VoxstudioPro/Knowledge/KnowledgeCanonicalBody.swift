import Foundation

/// The selected body is independent of display paragraphs and media clip windows.
struct KnowledgeBodySpan: Codable, Equatable, Sendable {
    var parentIndex: Int
    var cueID: Int?
    var lower: Int
    var upper: Int
    var start: Double?
    var end: Double?
    var speaker: String?
    var timingPrecision: String
}

struct KnowledgeTranscriptMaterial: Sendable {
    let text: String
    let segments: [TranscriptionSegment]
    let spans: [KnowledgeBodySpan]
    let language: String?
    let provenance: String
    let role: String
    let revision: String?
    let citationChunkBase: Int

    var generation: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return KnowledgeScopeSnapshot.digest(Data((provenance + "|" + role + "|" + (revision ?? "") + "|" + text).utf8)
            + ((try? encoder.encode(spans)) ?? Data()))
    }

    static func displayTranscript(for session: WorkbenchSession) -> TranscriptionResult? {
        guard let body = from(session) else { return nil }
        return .init(text: body.text, language: body.language, words: [], segments: body.segments)
    }

    static func from(_ session: WorkbenchSession) -> Self? {
        let dub = session.source == .standaloneDub || session.sessionType == .dub
        let role = dub ? "voiceover" : "original"
        // Cloud voiceovers may expose their own transcript/subtitles in the original fields.
        let transcripts = dub ? [session.transcript, session.dubTranscript] : [session.transcript]
        for transcript in transcripts {
            if let body = from(transcript: transcript, role: role, revision: session.knowledgeRevisionID?.uuidString) { return body }
        }
        let tracks = dub ? [session.subtitleTrack, session.dubSubtitleTrack] : [session.subtitleTrack]
        for track in tracks {
            if let body = from(subtitles: track, role: role, revision: session.knowledgeRevisionID?.uuidString) { return body }
        }
        return nil
    }

    static func from(transcript: TranscriptionResult?, role: String = "original", revision: String? = nil) -> Self? {
        guard let transcript else { return nil }
        let segments = transcript.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? segments.map(\.text).joined(separator: " ") : transcript.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var spans: [KnowledgeBodySpan] = []
        let original = text as NSString
        var offset = 0
        for (index, segment) in segments.enumerated() {
            let range = original.range(of: segment.text, options: [], range: NSRange(location: offset, length: original.length - offset))
            guard range.location != NSNotFound,
                  original.substring(with: NSRange(location: offset, length: range.location - offset)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                spans = []; break
            }
            let timed = segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.end > segment.start
            spans.append(.init(parentIndex: index, cueID: nil, lower: range.location, upper: NSMaxRange(range),
                start: timed ? segment.start : nil, end: timed ? segment.end : nil, speaker: segment.speaker,
                timingPrecision: timed ? "segment" : "unknown"))
            offset = NSMaxRange(range)
        }
        if !original.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans = [] }
        // An edited body must never be replaced by stale segments or words.
        if spans.isEmpty {
            spans = [.init(parentIndex: 0, cueID: nil, lower: 0, upper: original.length, start: nil, end: nil, speaker: nil, timingPrecision: "unknown")]
        }
        let parentSpans = spans
        // Only aligned words that cover the current text in order can refine timing.
        // Editing text while retaining old alignment therefore keeps coarse/unknown timing.
        var wordSpans: [KnowledgeBodySpan] = [], wordOffset = 0, lastTime = -Double.infinity
        for word in transcript.words {
            let wordText = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wordText.isEmpty, word.timingQuality == .aligned,
                  let start = word.start, let end = word.end, start.isFinite, end.isFinite, start >= 0, end > start, start >= lastTime else {
                wordSpans = []; break
            }
            let range = original.range(of: wordText, options: [], range: NSRange(location: wordOffset, length: original.length - wordOffset))
            guard range.location != NSNotFound,
                  original.substring(with: NSRange(location: wordOffset, length: range.location - wordOffset)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { wordSpans = []; break }
            let parent = spans.first { $0.lower <= range.location && $0.upper >= NSMaxRange(range) }
            wordSpans.append(.init(parentIndex: parent?.parentIndex ?? 0, cueID: nil, lower: range.location, upper: NSMaxRange(range),
                                   start: start, end: end, speaker: word.speaker ?? parent?.speaker, timingPrecision: "word"))
            wordOffset = NSMaxRange(range); lastTime = start
        }
        if !wordSpans.isEmpty, original.substring(from: wordOffset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans = wordSpans }
        let readable = parentSpans.map { span in
            TranscriptionSegment(text: original.substring(with: NSRange(location: span.lower, length: span.upper - span.lower)),
                                 start: span.start ?? 0, end: span.end ?? 0, speaker: span.speaker)
        }
        return .init(text: text, segments: readable, spans: spans, language: transcript.language,
                     provenance: role == "voiceover" ? "dub_segments" : "original_segments", role: role, revision: revision,
                     citationChunkBase: role == "voiceover" ? 3_000_000 : 1_000_000)
    }

    static func from(subtitles track: SubtitleTrack?, role: String = "original", revision: String? = nil) -> Self? {
        guard let track else { return nil }
        let cues = track.cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cues.isEmpty else { return nil }
        let text = cues.map(\.text).joined(separator: " ")
        var offset = 0
        let spans = cues.enumerated().map { index, cue -> KnowledgeBodySpan in
            let length = (cue.text as NSString).length
            defer { offset += length + 1 }
            let timed = cue.start.isFinite && cue.end.isFinite && cue.start >= 0 && cue.end > cue.start
            return .init(parentIndex: index, cueID: cue.id, lower: offset, upper: offset + length,
                         start: timed ? cue.start : nil, end: timed ? cue.end : nil, speaker: cue.speaker,
                         timingPrecision: timed ? "cue" : "unknown")
        }
        return .init(text: text, segments: cues.map { .init(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker) },
                     spans: spans, language: track.language ?? track.sourceLanguage, provenance: "subtitle_fallback",
                     role: role, revision: revision, citationChunkBase: role == "voiceover" ? 4_000_000 : 2_000_000)
    }
}

enum KnowledgeBodyChunker {
    static let version = "canonical-spans-v2"
    static let targetTokens = 512
    static let maximumTokens = 768
    static let maximumContextTokens = 64
    static let maximumInputTokens = 1_024

    struct Chunk: Equatable, Sendable {
        var text: String
        var context: String
        var lower: Int
        var upper: Int
        var spans: [KnowledgeBodySpan]
        var start: Double? { spans.compactMap(\.start).min() }
        var end: Double? { spans.compactMap(\.end).max() }
        var speakers: [String] { Array(Set(spans.compactMap(\.speaker))).sorted() }
        var timingPrecision: String {
            guard spans.allSatisfy({ $0.start != nil && $0.end != nil }) else { return "unknown" }
            return spans.allSatisfy({ $0.timingPrecision == "word" }) ? "word" : "coarse"
        }
    }

    // NFC UTF-8 byte count is a conservative upper bound for the installed ByteLevel tokenizers.
    // Callers with a loaded tokenizer pass its actual counter without loading model weights.
    static func conservativeCount(_ text: String) -> Int { text.precomposedStringWithCanonicalMapping.utf8.count }

    static func pack(_ body: KnowledgeTranscriptMaterial, maximum: Int = maximumTokens, count: (String) -> Int = conservativeCount) -> [Chunk] {
        let characters = body.text.flatMap { character -> [String] in
            let value = String(character)
            // ByteLevel tokenizers cannot emit more tokens than input bytes.
            // Avoid running two full tokenizers once per ordinary character.
            return conservativeCount(value) <= maximum
                ? [value] : value.unicodeScalars.map { String($0) }
        }
        guard !characters.isEmpty else { return [] }
        var utf16Offsets = [0]
        for character in characters { utf16Offsets.append(utf16Offsets.last! + String(character).utf16.count) }
        let boundaries = Set(body.spans.map(\.upper))
        // Spans are ordered by source range. Locate them once per window and
        // advance through boundaries instead of rescanning every word for each character.
        func firstSpanEnding(after offset: Int) -> Int {
            var low = 0, high = body.spans.count
            while low < high {
                let middle = (low + high) / 2
                if body.spans[middle].upper <= offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        func firstSpanStarting(atOrAfter offset: Int) -> Int {
            var low = 0, high = body.spans.count
            while low < high {
                let middle = (low + high) / 2
                if body.spans[middle].lower < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        var result: [Chunk] = [], begin = 0
        while begin < characters.count {
            guard !Task.isCancelled else { return [] }
            // Bracket the safe prefix before binary search. Tokenizing 4,096
            // characters for every small CJK window wastes most of the work.
            // The starting width is only a search bound; the actual tokenizer
            // decides every accepted budget, including the final window.
            let ceiling = min(characters.count, begin + 8_192)
            var high = min(ceiling, begin + max(1, maximum)), safe = begin
            while count(characters[begin..<high].joined()) <= maximum {
                safe = high
                if high == ceiling { break }
                high = min(ceiling, begin + (high - begin) * 2)
            }
            var low = safe + 1
            if safe < high { high -= 1 }
            while low <= high {
                let mid = (low + high) / 2
                if count(characters[begin..<mid].joined()) <= maximum { safe = mid; low = mid + 1 }
                else { high = mid - 1 }
            }
            var end = safe
            let initialIndex = firstSpanEnding(after: utf16Offsets[begin])
            let initial = initialIndex < body.spans.count ? body.spans[initialIndex] : nil
            var followingIndex = firstSpanStarting(atOrAfter: utf16Offsets[begin + 1])
            if safe > begin + 1 {
                for candidate in (begin + 1)...safe {
                    while followingIndex < body.spans.count && body.spans[followingIndex].lower < utf16Offsets[candidate] { followingIndex += 1 }
                    let last = followingIndex > 0 ? body.spans[followingIndex - 1] : nil
                    let duration = (last?.upper ?? Int.max) <= utf16Offsets[candidate]
                        ? (last?.end ?? 0) - (initial?.start ?? 0) : 0
                    let speakerChanged = candidate < characters.count && boundaries.contains(utf16Offsets[candidate]) &&
                        TranscriptSegmenter.isKnownSpeakerChange(from: last?.speaker,
                            to: followingIndex < body.spans.count ? body.spans[followingIndex].speaker : nil, boundary: .hard)
                    let sentence = TranscriptSegmenter.endPunctuationRank(characters[candidate - 1]) == 3 || characters[candidate - 1] == "\n"
                    if speakerChanged || (boundaries.contains(utf16Offsets[candidate]) && duration >= TranscriptSegmenter.targetDuration) {
                        end = candidate; break
                    }
                    if sentence && (duration >= TranscriptSegmenter.minimumDuration || count(characters[begin..<candidate].joined()) >= targetTokens) {
                        end = candidate; break
                    }
                }
            }
            // Prefix token counts can change at a BPE merge boundary. Verify
            // the chosen sentence boundary rather than assuming monotonicity.
            while end > begin + 1 && count(characters[begin..<end].joined()) > maximum { end -= 1 }
            let lower = utf16Offsets[begin], upper = utf16Offsets[end]
            let finalIndex = firstSpanStarting(atOrAfter: upper)
            let spans = Array(body.spans[initialIndex..<max(initialIndex, finalIndex)])
            let contextCharacters = result.last.map { Array($0.text) } ?? []
            var context = "", contextLow = 1, contextHigh = contextCharacters.count
            while contextLow <= contextHigh {
                let length = (contextLow + contextHigh) / 2
                let candidate = String(contextCharacters.suffix(length))
                if count(candidate) <= maximumContextTokens {
                    context = candidate; contextLow = length + 1
                } else { contextHigh = length - 1 }
            }
            result.append(.init(text: characters[begin..<end].joined(), context: context, lower: lower, upper: upper, spans: spans))
            begin = end
        }
        if result.count >= 2 {
            let tail = result.removeLast(), previous = result.removeLast()
            let combined = previous.text + tail.text
            if previous.speakers == tail.speakers, let start = previous.start, let end = tail.end,
               end - start <= TranscriptSegmenter.maximumDuration + TranscriptSegmenter.tailMergeGrace, count(tail.text) < targetTokens / 4, count(combined) <= maximum {
                result.append(.init(text: combined, context: previous.context, lower: previous.lower, upper: tail.upper,
                                    spans: body.spans.filter { $0.lower < tail.upper && $0.upper > previous.lower }))
            } else { result += [previous, tail] }
        }
        return result
    }
}
