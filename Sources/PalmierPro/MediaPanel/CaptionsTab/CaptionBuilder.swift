import Foundation

// Purpose: Decides how words from CaptionTranscriptMapper should be grouped into chunks
enum CaptionBuilder {
    struct Phrase: Equatable {
        var text: String
        var start: Double
        var end: Double
        /// Member words with their own timings (seconds); empty when word timing is unavailable.
        var words: [WordSpan] = []
    }

    struct WordSpan: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    /// General builder: split a transcript segment into caption-sized chunks
    static func phrases(
        for segment: TranscriptionSegment,
        words: [TranscriptionWord] = [],
        fits: @escaping (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        language: String? = nil,
        characterBudget: Int? = nil
    ) -> [Phrase] {
        let maximumCharacters = characterBudget
            ?? SubtitleReadabilityPolicy.maximumCharacters(for: segment.text)
        let accepts: (String) -> Bool = {
            fits($0) && visibleLength($0) <= maximumCharacters
        }
        // Only phrases that fit visually and within the word cap are accepted; else, keep splitting.
        let pieces: [String]
        if !words.isEmpty, isDenseScript(segment.text) {
            pieces = splitTimedWordUnits(
                words,
                fits: accepts,
                maxWords: maxWords,
                language: language
            )
        } else if let limit = maxWords {
            let cap = max(1, limit)
            pieces = split(segment.text, fits: { text in
                accepts(text) && (isDenseScript(text) || wordCount(text) <= cap)
            })
        } else {
            pieces = split(segment.text, fits: accepts)
        }
        let timed = time(pieces, segment: segment, words: words)
        return enforceMinDuration(timed, minDuration: minDuration)
    }

    static func phrases(
        fromTimedWords words: [TranscriptionWord],
        fits: @escaping (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        language: String? = nil,
        characterBudget: Int? = nil
    ) -> [Phrase] {
        let timed = words.filter { $0.start != nil && $0.end != nil }
        guard let first = timed.first, let last = timed.last, let start = first.start, let end = last.end, end > start else { return [] }
        let text = TranscriptSegmenter.joinedText(timed.map(\.text), language: language)
        guard !text.isEmpty else { return [] }
        return phrases(
            for: TranscriptionSegment(text: text, start: start, end: end, speaker: first.speaker),
            words: timed,
            fits: fits,
            maxWords: maxWords,
            minDuration: minDuration,
            language: language,
            characterBudget: characterBudget
        )
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func visibleLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private static func isDenseScript(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { return false }
        let denseCount = visible.filter(TranscriptSegmenter.isCJK).count
        return Double(denseCount) / Double(visible.count) >= 0.25
    }

    private static func splitTimedWordUnits(
        _ words: [TranscriptionWord],
        fits: (String) -> Bool,
        maxWords: Int?,
        language: String?
    ) -> [String] {
        let cap = maxWords.map { max(1, $0) }
        var chunks: [String] = []
        var current: [String] = []

        func emit() {
            let text = TranscriptSegmenter.joinedText(current, language: language)
            if !text.isEmpty { chunks.append(text) }
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            let candidate = TranscriptSegmenter.joinedText(
                current + [word.text],
                language: language
            )
            let exceedsWordCap = cap.map { !isDenseScript(candidate) && wordCount(candidate) > $0 } ?? false
            if !current.isEmpty, (!fits(candidate) || exceedsWordCap) {
                emit()
            }
            current.append(word.text)
            let completedSentence = word.text.trimmingCharacters(in: .whitespacesAndNewlines).last
                .map { ".!?。！？".contains($0) } == true
            if completedSentence {
                emit()
            }
        }
        emit()
        return chunks
    }

    private static func split(_ text: String, fits: (String) -> Bool) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        if fits(t) { return [t] }
        let parts = breakOnce(t)
        guard parts.count > 1 else { return [t] }   // a single over-long word: keep it
        return parts.flatMap { split($0, fits: fits) }
    }

    /// Break once at the best boundary present: sentence, then clause, then midpoint word.
    private static func breakOnce(_ text: String) -> [String] {
        breakOn(text, delimiters: ".!?。！？") ?? breakOn(text, delimiters: ",;:，；：、") ?? breakAtMidWord(text)
    }

    /// Split after delimiters followed by a space, so "U.S." and "3.14" stay intact.
    private static func breakOn(_ text: String, delimiters: String) -> [String]? {
        let set = Set(delimiters)
        let chars = Array(text)
        var pieces: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            current.append(c)
            let nextIsBreak = i + 1 >= chars.count
                || chars[i + 1].isWhitespace
                || isCJKPunctuation(c)
            if set.contains(c), nextIsBreak {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { pieces.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.count > 1 ? pieces : nil
    }

    private static func isCJKPunctuation(_ character: Character) -> Bool {
        "。！？；，、：".contains(character)
    }

    private static func breakAtMidWord(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [text] }
        let mid = words.count / 2
        return [words[..<mid].joined(separator: " "), words[mid...].joined(separator: " ")]
    }

    /// Time phrases from word runs by matching shared characters, so timing holds when
    /// runs don't split on spaces (contractions, split numbers, punctuation runs).
    private static func time(_ texts: [String], segment: TranscriptionSegment, words: [TranscriptionWord]) -> [Phrase] {
        let timed = words.compactMap { w -> (text: String, count: Int, start: Double, end: Double)? in
            guard let s = w.start, let e = w.end else { return nil }
            let count = alphanumericCount(w.text)
            return count > 0 ? (w.text, count, s, e) : nil
        }
        guard !timed.isEmpty else { return distribute(texts, start: segment.start, end: segment.end) }

        var phrases: [Phrase] = []
        var idx = 0
        for text in texts {
            let want = alphanumericCount(text)
            var got = 0
            var first: (start: Double, end: Double)?
            var last: (start: Double, end: Double)?
            var spans: [WordSpan] = []
            while idx < timed.count, got < want {
                let run = timed[idx]
                if first == nil { first = (run.start, run.end) }
                last = (run.start, run.end)
                spans.append(WordSpan(text: run.text.trimmingCharacters(in: .whitespaces), start: run.start, end: run.end))
                got += run.count
                idx += 1
            }
            guard let f = first, let l = last else { break }
            phrases.append(Phrase(text: text, start: f.start, end: l.end, words: spans))
        }
        return phrases.count == texts.count ? phrases : distribute(texts, start: segment.start, end: segment.end)
    }

    private static func alphanumericCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }

    /// Share the segment's time across pieces by character count, back to back.
    private static func distribute(_ texts: [String], start: Double, end: Double) -> [Phrase] {
        guard !texts.isEmpty else { return [] }
        let total = texts.reduce(0) { $0 + max($1.count, 1) }
        let span = max(end - start, 0)
        var phrases: [Phrase] = []
        var t = start
        for text in texts {
            let dur = span * Double(max(text.count, 1)) / Double(total)
            phrases.append(Phrase(text: text, start: t, end: t + dur))
            t += dur
        }
        return phrases
    }

    /// Give each phrase a floor duration without moving later phrases off their first word.
    private static func enforceMinDuration(_ phrases: [Phrase], minDuration: Double) -> [Phrase] {
        var out = phrases
        for i in out.indices {
            let targetEnd = max(out[i].end, out[i].start + minDuration)
            if i + 1 < out.count {
                out[i].end = min(targetEnd, out[i + 1].start)
                if out[i].end < out[i].start { out[i].end = out[i].start }
            } else {
                out[i].end = targetEnd
            }
        }
        return out
    }

    static func specs(
        for phrases: [Phrase],
        sourceClip: Clip,
        trackIndex: Int,
        fps: Int,
        style: TextStyle,
        captionGroupId: String?,
        animation: TextAnimation? = nil,
        transformFor: (String) -> Transform? = { _ in nil },
        minDurationFrames: Int = 1
    ) -> [EditorViewModel.TextClipSpec] {
        phrases.compactMap { p in
            let visibleStartSource = Double(sourceClip.trimStartFrame)
            let visibleEndSource = visibleStartSource + Double(sourceClip.durationFrames) * max(sourceClip.speed, 0.0001)
            let phraseStartSource = p.start * Double(fps)
            let phraseEndSource = p.end * Double(fps)
            guard phraseEndSource > visibleStartSource, phraseStartSource < visibleEndSource else { return nil }

            func clampedTimelineFrame(sourceSeconds: Double) -> Int {
                let sourceFrame = sourceSeconds * Double(fps)
                let offsetFromTrim = sourceFrame - visibleStartSource
                let frame = Int((Double(sourceClip.startFrame) + offsetFromTrim / max(sourceClip.speed, 0.0001)).rounded())
                return min(max(frame, sourceClip.startFrame), sourceClip.endFrame)
            }

            let mappedStart = sourceClip.timelineFrame(sourceSeconds: p.start, fps: fps)
            let mappedEnd = sourceClip.timelineFrame(sourceSeconds: p.end, fps: fps)
            let s = mappedStart ?? sourceClip.startFrame
            let e = mappedEnd ?? sourceClip.endFrame
            let duration = max(minDurationFrames, min(sourceClip.endFrame, e) - max(sourceClip.startFrame, s))

            // Map word spans to clip-relative frames, clamped to the clip's own span.
            let words: [WordTiming] = p.words.compactMap { w in
                let wordStartSource = w.start * Double(fps)
                let wordEndSource = w.end * Double(fps)
                guard wordEndSource > visibleStartSource, wordStartSource < visibleEndSource else { return nil }
                let ws = clampedTimelineFrame(sourceSeconds: w.start)
                let we = clampedTimelineFrame(sourceSeconds: w.end)
                var rs = min(max(0, ws - s), duration)
                var re = min(max(rs, we - s), duration)
                // Several aligned words can legitimately share the final decoded
                // frame (for example when a container is a few frames shorter than
                // the PCM transcript). Keep each word addressable for karaoke-style
                // captions instead of dropping it after integer frame rounding.
                if re <= rs, duration > 0 {
                    rs = min(rs, duration - 1)
                    re = rs + 1
                }
                guard re > rs else { return nil }
                return WordTiming(text: w.text, startFrame: rs, endFrame: re)
            }

            return EditorViewModel.TextClipSpec(
                trackIndex: trackIndex,
                startFrame: s,
                durationFrames: duration,
                content: p.text,
                style: style,
                transform: transformFor(TranscriptSegmenter.renderedSubtitleText(p.text)),
                captionGroupId: captionGroupId,
                words: words.isEmpty ? nil : words,
                animation: animation
            )
        }
    }
}
