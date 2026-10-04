import Foundation

// Purpose: Given this source clip fragment, which transcript words/segments should become caption phrases?
enum CaptionTranscriptMapper {
    static func sourceSpan(for clip: Clip) -> (start: Double, end: Double) {
        let start = Double(clip.trimStartFrame)
        return (start, start + Double(clip.durationFrames) * max(clip.speed, 0.0001))
    }

    static func sourceUnion(for mediaRef: String, clips: [Clip], fps: Int, paddingSeconds: Double = 1.0) -> ClosedRange<Double>? {
        let rate = Double(fps)
        let spans = clips.filter { $0.mediaRef == mediaRef }.map { sourceSpan(for: $0) }
        guard rate > 0, let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(), hi > lo else { return nil }
        return max(lo / rate - paddingSeconds, 0)...(hi / rate + paddingSeconds)
    }

    static func spokenWordCount(in clip: Clip, result: TranscriptionResult, fps: Int) -> Int {
        let visible = sourceSpan(for: clip)
        let rate = Double(fps)
        return result.words.reduce(0) { count, word in
            guard let start = word.start, let end = word.end else { return count }
            let midFrame = (start + end) / 2 * rate
            return visible.start <= midFrame && midFrame < visible.end ? count + 1 : count
        }
    }

    static func phrases(
        for clip: Clip,
        result: TranscriptionResult,
        fps: Int,
        maxWords: Int?,
        minDuration: Double,
        fits: @escaping (String) -> Bool
    ) -> [CaptionBuilder.Phrase] {
        let source = sourceSpan(for: clip)
        let rate = Double(fps)
        guard rate > 0 else { return [] }
        let visibleStart = source.start / rate
        let visibleEnd = source.end / rate
        return phrases(
            result: result,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            maxWords: maxWords,
            minDuration: minDuration,
            fits: fits
        )
    }

    /// The workbench uses the same phrase builder as Generate Local Captions,
    /// without needing to create a timeline clip or transcribe the media again.
    static func phrases(
        for result: TranscriptionResult,
        maxWords: Int? = nil,
        minDuration: Double,
        fits: @escaping (String) -> Bool
    ) -> [CaptionBuilder.Phrase] {
        let starts = result.segments.map(\.start) + result.words.compactMap(\.start)
        let ends = result.segments.map(\.end) + result.words.compactMap(\.end)
        return phrases(
            result: result,
            visibleStart: starts.filter(\.isFinite).min() ?? 0,
            visibleEnd: ends.filter(\.isFinite).max() ?? 0,
            maxWords: maxWords,
            minDuration: minDuration,
            fits: fits
        )
    }

    private static func phrases(
        result: TranscriptionResult,
        visibleStart: Double,
        visibleEnd: Double,
        maxWords: Int?,
        minDuration: Double,
        fits: @escaping (String) -> Bool
    ) -> [CaptionBuilder.Phrase] {
        guard visibleEnd > visibleStart else { return [] }
        let hasWordTimings = result.words.contains { $0.start != nil && $0.end != nil }

        if hasWordTimings {
            // Prefer word timings so phrase boundaries survive clipped/reordered source fragments.
            return phrasesWithWordTimings(
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                result: result,
                maxWords: maxWords,
                minDuration: minDuration,
                fits: fits
            )
        }

        return result.segments.flatMap { segment in
            guard let clipped = clippedSegment(segment, visibleStart: visibleStart, visibleEnd: visibleEnd) else { return [CaptionBuilder.Phrase]() }
            return CaptionBuilder.phrases(
                for: clipped,
                fits: fits,
                maxWords: maxWords,
                minDuration: minDuration,
                language: result.language
            )
        }
    }

    private static func phrasesWithWordTimings(
        visibleStart: Double,
        visibleEnd: Double,
        result: TranscriptionResult,
        maxWords: Int?,
        minDuration: Double,
        fits: @escaping (String) -> Bool
    ) -> [CaptionBuilder.Phrase] {
        let visible = result.words.compactMap { word -> TranscriptionWord? in
            guard let start = word.start, let end = word.end, start.isFinite, end.isFinite,
                  end >= start, (start + end) / 2 >= visibleStart, (start + end) / 2 < visibleEnd else { return nil }
            return TranscriptionWord(text: word.text, start: max(start, visibleStart), end: min(end, visibleEnd),
                speaker: word.speaker, speakerConfidence: word.speakerConfidence,
                speakerBoundary: word.speakerBoundary, timingQuality: word.timingQuality)
        }
        return CaptionBuilder.phrases(fromTimedWords: visible, fits: fits, maxWords: maxWords,
                                      minDuration: minDuration, language: result.language)
    }

    private static func fallbackSegment(for result: TranscriptionResult) -> TranscriptionSegment {
        let timed = result.words.compactMap { word -> (start: Double, end: Double)? in
            guard let start = word.start, let end = word.end else { return nil }
            return (start, end)
        }
        let start = timed.map(\.start).min() ?? 0
        let end = timed.map(\.end).max() ?? start
        return TranscriptionSegment(text: result.text, start: start, end: end)
    }

    private static func clippedSegment(_ segment: TranscriptionSegment, visibleStart: Double, visibleEnd: Double) -> TranscriptionSegment? {
        let start = max(segment.start, visibleStart)
        let end = min(segment.end, visibleEnd)
        guard end > start else { return nil }
        return TranscriptionSegment(text: segment.text, start: start, end: end, speaker: segment.speaker)
    }
}
