import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Transcript canvas")
struct SessionTranscriptCanvasTests {
    private func cue(_ id: Int, _ speaker: String?, _ text: String = "Hello") -> SubtitleCue {
        SubtitleCue(id: id, sourceIDs: [id + 100], text: text,
                    start: Double(id), end: Double(id + 1), speaker: speaker)
    }

    @Test func groupsOnlyConsecutiveMatchingSpeakersAndPreservesOriginalCues() {
        let cues = [cue(1, " Alice "), cue(2, "Alice"), cue(3, "Bob"), cue(4, "Alice")]
        let paragraphs = SessionTranscriptParagraph.group(cues)
        #expect(paragraphs.map { $0.cues.map(\.id) } == [[1, 2], [3], [4]])
        #expect(paragraphs.flatMap(\.cues) == cues)
        #expect(paragraphs[0].start == 1)
        #expect(paragraphs[0].end == 3)
        #expect(SessionTranscriptParagraph.scrollID(for: 2, in: cues) == 1)
        #expect(SessionTranscriptParagraph.scrollID(for: 4, in: cues) == 4)
    }

    @Test func unknownSpeakersDoNotImplyASingleIdentity() {
        let cues = [cue(1, nil), cue(2, " "), cue(3, "Bob")]
        #expect(SessionTranscriptParagraph.group(cues).count == 3)
        #expect(SessionTranscriptParagraph.scrollID(for: 2, in: cues) == 2)
        #expect(SessionTranscriptParagraph.scrollID(for: 999, in: cues) == nil)
    }

    @Test func joinsEnglishAndChineseWithoutChangingStoredText() {
        #expect(SessionTranscriptParagraph.text([cue(1, "A", "Hello."), cue(2, "A", "Welcome!")]) == "Hello. Welcome!")
        #expect(SessionTranscriptParagraph.text([cue(1, "A", "你好。"), cue(2, "A", "欢迎！")]) == "你好。欢迎！")
    }

    @Test func highlightsOnlyTheSubtitleInsideALongTranscriptSegment() throws {
        let transcript = [SubtitleCue(id: 40, sourceIDs: [], text: "First sentence. Second sentence. Last sentence.",
                                      start: 0, end: 12, speaker: "A")]
        let subtitles = [
            SubtitleCue(id: 1, sourceIDs: [40], text: "First sentence.", start: 0, end: 3, speaker: "A"),
            SubtitleCue(id: 2, sourceIDs: [40], text: "Second\nsentence.", start: 3, end: 7, speaker: "A"),
            SubtitleCue(id: 3, sourceIDs: [40], text: "Last sentence.", start: 8, end: 12, speaker: "A")
        ]
        let ranges = SessionTranscriptSubtitleHighlights.ranges(in: transcript, subtitles: subtitles)
        let range = try #require(ranges[2]?[40])
        #expect((transcript[0].text as NSString).substring(with: range) == "Second sentence.")
        #expect(ranges.count == 3)
        #expect(transcript[0].text == "First sentence. Second sentence. Last sentence.")
    }

    @Test func repeatedSubtitlesUseTheirOwnOccurrenceAndIgnoreCueIDs() throws {
        let transcript = [SubtitleCue(id: 1, sourceIDs: [], text: "Yes. Yes. Yes.", start: 0, end: 6, speaker: "A")]
        let subtitles = (0..<3).map {
            SubtitleCue(id: $0 + 90, sourceIDs: [], text: "Yes.", start: Double($0 * 2), end: Double($0 * 2 + 2), speaker: "A")
        }
        let ranges = SessionTranscriptSubtitleHighlights.ranges(in: transcript, subtitles: subtitles)
        #expect(ranges[90]?[1] == NSRange(location: 0, length: 4))
        #expect(ranges[91]?[1] == NSRange(location: 5, length: 4))
        #expect(ranges[92]?[1] == NSRange(location: 10, length: 4))
    }

    @Test func subtitleCanHighlightAcrossTranscriptSegmentsWithUnicodeAndDifferentSpacing() throws {
        let transcript = [
            SubtitleCue(id: 10, sourceIDs: [], text: "  你好👋，", start: 0, end: 2, speaker: "A"),
            SubtitleCue(id: 20, sourceIDs: [], text: "欢迎！再见。", start: 2, end: 4, speaker: "B")
        ]
        let subtitle = SubtitleCue(id: 1, sourceIDs: [], text: "你好👋， 欢迎！", start: 0, end: 3, speaker: "A")
        let ranges = try #require(SessionTranscriptSubtitleHighlights.ranges(in: transcript, subtitles: [subtitle])[1])
        #expect(ranges[10] == NSRange(location: 0, length: 5))
        #expect(ranges[20] == NSRange(location: 0, length: 3))
    }

    @Test func mismatchedSubtitleDoesNotHighlightUnrelatedText() {
        let transcript = [SubtitleCue(id: 10, sourceIDs: [], text: "Hello.", start: 0, end: 2, speaker: "A")]
        let subtitles = [
            SubtitleCue(id: 1, sourceIDs: [], text: "Edited text.", start: 0, end: 1, speaker: "A"),
            SubtitleCue(id: 2, sourceIDs: [], text: "Hello.", start: 3, end: 4, speaker: "A")
        ]
        #expect(SessionTranscriptSubtitleHighlights.ranges(in: transcript, subtitles: subtitles).isEmpty)
        #expect(SessionTranscriptSubtitleHighlights.ranges(in: transcript, subtitles: []).isEmpty)
    }

    @Test func wholeSegmentHighlightIsUsedOnlyWhenSubtitleCutsAreAbsent() {
        let segment = cue(1, "A", "First. Second.")
        #expect(SessionTranscriptSubtitleHighlights.range(for: segment, activeCueID: 1, subtitleRanges: nil)
                == NSRange(location: 0, length: 14))
        #expect(SessionTranscriptSubtitleHighlights.range(for: segment, activeCueID: nil, subtitleRanges: nil) == nil)
        #expect(SessionTranscriptSubtitleHighlights.range(for: segment, activeCueID: 1, subtitleRanges: [:]) == nil)
        #expect(SessionTranscriptSubtitleHighlights.range(for: segment, activeCueID: 1,
                                                         subtitleRanges: [1: NSRange(location: 7, length: 7)])
                == NSRange(location: 7, length: 7))
    }

    @Test(arguments: [
        ("fr-FR", "Bonjour tout le monde.", "Bienvenue ici !", "Bonjour tout le monde. Bienvenue ici !"),
        ("de-DE", "Guten Tag.", "Schön, Sie zu sehen.", "Guten Tag. Schön, Sie zu sehen."),
        ("es-ES", "¡Hola a todos!", "Bienvenidos.", "¡Hola a todos! Bienvenidos."),
        ("ar", "مرحباً بالجميع.", "أهلاً وسهلاً.", "مرحباً بالجميع. أهلاً وسهلاً."),
        ("hi", "नमस्ते दोस्तों।", "आपका स्वागत है।", "नमस्ते दोस्तों। आपका स्वागत है।"),
        ("ko-KR", "안녕하세요.", "만나서 반갑습니다.", "안녕하세요. 만나서 반갑습니다."),
        ("th-TH", "สวัสดีครับ", "ยินดีที่ได้รู้จัก", "สวัสดีครับ ยินดีที่ได้รู้จัก"),
        ("ja-JP", "こんにちは。", "よろしくお願いします。", "こんにちは。よろしくお願いします。"),
        ("und", "Mixed 原文.", "مرحبا again!", "Mixed 原文. مرحبا again!")
    ])
    func preservesMultilingualSourceSpacingAndAuthoredText(_ fixture: (String, String, String, String)) {
        let (language, first, second, source) = fixture
        let cues = [cue(1, "A", first), cue(2, "A", second)]
        let pieces = SessionTranscriptParagraph.pieces(cues, language: language, sourceText: source)
        #expect(pieces.map(\.text) == [first, second])
        #expect(SessionTranscriptParagraph.text(cues, language: language, sourceText: source) == source)
        #expect(pieces.map(\.cue) == cues)
    }

    @Test func automaticColorsAreDistinctAndStableWhenLabelsReorder() {
        var colors = SessionSpeakerColors()
        colors.ensure(["A", "B", "C", "D"])
        let original = colors
        let selected = Array(colors.values.values)
        for i in selected.indices {
            for j in selected.indices where j > i {
                #expect(selected[i].distance(to: selected[j]) >= 0.10)
            }
        }
        colors.ensure(["D", "C", "B", "A"])
        #expect(colors == original)
    }

    @Test func renamedSpeakerKeepsCustomColorAcrossPersistence() throws {
        var colors = SessionSpeakerColors()
        colors.ensure(["Speaker 1", "Speaker 2"])
        let custom = SessionSpeakerColor(0.14, 0.38, 0.58)
        colors.set(custom, for: "Speaker 1")
        colors.rename("Speaker 1", to: "Narrator")
        colors.ensure(["Narrator", "Speaker 2", "New speaker"])
        let snapshot = WorkbenchSnapshot(transcriptions: [], dubs: [], speakerColors: ["session": colors])
        let restored = try JSONDecoder().decode(WorkbenchSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.speakerColors?["session"]?.values["Narrator"] == custom)
        #expect(restored.speakerColors?["session"]?.values["Speaker 1"] == nil)
        #expect(try #require(colors.values["New speaker"]).distance(to: custom) >= 0.10)
    }

    @Test func renameIntoExistingSpeakerUsesDestinationIdentity() {
        var colors = SessionSpeakerColors()
        colors.ensure(["A", "B"])
        let destination = colors.values["B"]
        colors.rename("A", to: "B")
        #expect(colors.values["B"] == destination)
        #expect(colors.values.count == 1)
    }

    @Test func oldSnapshotsLoadWithoutSpeakerColors() throws {
        let json = Data(#"{"schemaVersion":7,"transcriptions":[],"dubs":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: json)
        #expect(snapshot.speakerColors == nil)
    }
}
