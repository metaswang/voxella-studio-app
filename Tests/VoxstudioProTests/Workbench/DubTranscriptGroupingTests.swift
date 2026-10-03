import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Generated voiceover transcript grouping")
struct DubTranscriptGroupingTests {
    @Test func referenceVoiceSubtitleCutsReadAsOneTranscriptParagraph() throws {
        let voiceName = "中文旁白参考音"
        let segments = [
            DubRenderedSegment(index: 0, text: "说来也奇妙，你们已经成为我们历史的一部分，",
                               start: 21.1, end: 24.2, speaker: voiceName, sourceSubtitleID: 10),
            DubRenderedSegment(index: 1, text: "也和我们一起走过这段旅程。",
                               start: 24.2, end: 26.2, speaker: voiceName, sourceSubtitleID: 10),
            DubRenderedSegment(index: 2, text: "对此我很感激。",
                               start: 26.2, end: 27.9, speaker: voiceName, sourceSubtitleID: 11),
            DubRenderedSegment(index: 3, text: "所以，真的谢谢大家。",
                               start: 28.8, end: 30.5, speaker: voiceName, sourceSubtitleID: 11)
        ]
        let subtitles = try #require(SubtitleTrack.fromDubSegments(segments, language: "zh-Hans"))
        let paragraphs = SessionTranscriptParagraph.group(subtitles.cues)
        let paragraph = try #require(paragraphs.first)

        #expect(subtitles.cues.count == 4)
        #expect(paragraphs.count == 1)
        #expect(paragraph.cues.first?.speaker == voiceName)
        #expect(paragraph.cues.first?.start == 21.1)
        #expect(paragraph.end == 30.5)
        #expect(TranscriptSegmenter.joinedText(paragraph.cues.map(\.text), language: "zh-Hans")
                == "说来也奇妙，你们已经成为我们历史的一部分，也和我们一起走过这段旅程。对此我很感激。所以，真的谢谢大家。")
        #expect(paragraphs.flatMap(\.cues) == subtitles.cues)
        #expect(subtitles.cues.map(\.id) == [0, 1, 2, 3])
        #expect(subtitles.cues.map(\.sourceIDs) == [[10], [10], [11], [11]])
        #expect(paragraph.id == 0)
    }

    @Test func referenceVoiceChangesCreateSeparateTranscriptTurns() throws {
        let segments = [
            DubRenderedSegment(index: 0, text: "Hello.", start: 0, end: 1,
                               speaker: "Narrator reference", sourceSubtitleID: 30),
            DubRenderedSegment(index: 1, text: "Welcome!", start: 1, end: 2,
                               speaker: "Narrator reference", sourceSubtitleID: 31),
            DubRenderedSegment(index: 2, text: "Thank you.", start: 2, end: 3,
                               speaker: "Guest reference", sourceSubtitleID: 32),
            DubRenderedSegment(index: 3, text: "Let's begin.", start: 3, end: 4,
                               speaker: "Narrator reference", sourceSubtitleID: 33)
        ]
        let subtitles = try #require(SubtitleTrack.fromDubSegments(segments, language: "en"))
        let paragraphs = SessionTranscriptParagraph.group(subtitles.cues)

        #expect(paragraphs.map { $0.cues.first?.speaker } == ["Narrator reference", "Guest reference", "Narrator reference"])
        #expect(paragraphs.map { $0.cues.map(\.id) } == [[0, 1], [2], [3]])
        #expect(paragraphs.flatMap(\.cues) == subtitles.cues)
        #expect(paragraphs.map(\.id) == [0, 2, 3])
    }

}
