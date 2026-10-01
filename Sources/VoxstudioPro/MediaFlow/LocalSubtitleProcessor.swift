import Foundation

enum LocalSubtitleProcessor {
    static func process(_ transcript: TranscriptionResult) throws -> SubtitleTrack {
        try Task.checkCancellation()
        let style = EditorViewModel.CaptionRequest.defaultLocalStyle
        let phrases = CaptionTranscriptMapper.phrases(
            for: transcript,
            minDuration: AppTheme.Caption.minDisplayDuration,
            fits: {
                CaptionSpecBuilder.lineFits($0, style: style, canvasWidth: 1920, canvasHeight: 1080)
            }
        )
        let timedWords = transcript.words.enumerated().compactMap { index, word -> (index: Int, word: TranscriptionWord, midpoint: Double)? in
            guard let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return (index, word, (start + end) / 2)
        }
        var wordIndex = 0
        var segmentIndex = 0
        var cues: [SubtitleCue] = []
        for (index, phrase) in phrases.enumerated() {
            try Task.checkCancellation()
            let end = min(phrase.end, index + 1 < phrases.count ? phrases[index + 1].start : phrase.end)
            guard phrase.start.isFinite, end.isFinite, end > phrase.start else { continue }
            while wordIndex < timedWords.count, timedWords[wordIndex].midpoint < phrase.start {
                wordIndex += 1
            }
            var sourceIDs: [Int] = []
            var speaker: String?
            while wordIndex < timedWords.count, timedWords[wordIndex].midpoint < end {
                sourceIDs.append(timedWords[wordIndex].index)
                speaker = speaker ?? timedWords[wordIndex].word.speaker
                wordIndex += 1
            }
            while segmentIndex < transcript.segments.count, transcript.segments[segmentIndex].end <= phrase.start {
                segmentIndex += 1
            }
            let sourceSegment = segmentIndex < transcript.segments.count
                && transcript.segments[segmentIndex].start <= phrase.start
                ? transcript.segments[segmentIndex] : nil
            cues.append(SubtitleCue(
                id: cues.count,
                sourceIDs: timedWords.isEmpty ? sourceSegment.map { _ in [segmentIndex] } ?? [] : sourceIDs,
                text: phrase.text,
                start: phrase.start,
                end: end,
                speaker: speaker ?? sourceSegment?.speaker
            ))
        }
        guard !cues.isEmpty else { throw MediaFlowError.missingTranscript }
        return SubtitleTrack(
            sourceLanguage: transcript.language,
            language: transcript.language,
            cues: cues,
            usesWordTimestamps: phrases.allSatisfy { !$0.words.isEmpty }
        )
    }
}
