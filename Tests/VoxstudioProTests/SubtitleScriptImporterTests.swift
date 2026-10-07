import Foundation
import Testing
@testable import VoxstudioPro

private struct PunctuationStub: LLMTextClient {
    let transform: @Sendable (String) -> String
    func complete(system: String, user: String) async throws -> String {
        let payload = try JSONDecoder().decode([String: String].self, from: Data(user.utf8))
        return transform(payload["text"] ?? "")
    }
}

@Suite struct SubtitleScriptImporterTests {
    @Test func parsesSRTWithoutTimingIntoCleanCues() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        <i>Hello</i> {\\an8}there

        2
        00:00:02,600 --> 00:00:04,000
        [MUSIC PLAYING]

        3
        00:00:04,100 --> 00:00:06,000
        - How are you?
        - Fine &amp; you?
        """
        let cues = SubtitleScriptImporter.parse(srt)
        #expect(cues.map(\.text) == ["Hello there", "How are you?", "Fine & you?"])
        #expect(cues[1].endsTurn)
        #expect(cues[0].start == 1 && cues[0].end == 2.5)
    }

    @Test func parsesVTTSkippingHeaderNotesAndInlineTimestamps() {
        let vtt = """
        WEBVTT
        Kind: captions

        NOTE produced by a tool

        00:01.000 --> 00:03.000 align:start position:0%
        <v Anna>so we<00:00:01.500><c> started</c> early

        00:03.000 --> 00:03.010
        so we started early

        00:03.010 --> 00:05.000
        so we started early
        and finished late
        """
        let cues = SubtitleScriptImporter.parse(vtt)
        #expect(cues.map(\.text) == ["so we started early", "and finished late"])
    }

    @Test func keepsShortRealRepetition() {
        let cues = SubtitleScriptImporter.removingRollingDuplicates([.init(text: "No."), .init(text: "No.")])
        #expect(cues.count == 2)
    }

    @Test func decodesLegacyChineseEncoding() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try #require("1\n00:00:01,000 --> 00:00:02,000\n你好世界\n".data(using: encoding))
        #expect(SubtitleScriptImporter.parse(try SubtitleScriptImporter.decode(data)).first?.text == "你好世界")
    }

    @Test func restoresChinesePunctuationFromCueBreaksAndSpaces() {
        let cues: [SubtitleScriptImporter.Cue] = [
            .init(text: "今天天气很好 我们出去走走", start: 0, end: 2),
            .init(text: "你想去公园吗", start: 2.1, end: 3),
            .init(text: "好啊", start: 4.5, end: 5),
        ]
        let result = DubPunctuationRestorer.restore(cues, language: "zh")
        #expect(result.coverage == .missing)
        #expect(result.text == "今天天气很好，我们出去走走，你想去公园吗？好啊。")
        #expect(result.originalText == "今天天气很好我们出去走走你想去公园吗好啊")
        #expect(result.insertedCount == 4)
    }

    @Test func restoresEnglishSentenceEndsFromCapitalsAndGaps() {
        let cues: [SubtitleScriptImporter.Cue] = [
            .init(text: "we went to the market", start: 0, end: 2),
            .init(text: "and bought some apples", start: 2.05, end: 4),
            .init(text: "It was raining", start: 4.1, end: 5),
            .init(text: "so I stayed home", start: 6.5, end: 8),
        ]
        let result = DubPunctuationRestorer.restore(cues, language: "en")
        #expect(result.text == "we went to the market, and bought some apples. It was raining. so I stayed home.")
    }

    @Test func leavesWellPunctuatedSubtitlesWrappedAcrossCues() {
        let cues: [SubtitleScriptImporter.Cue] = [
            .init(text: "I went to the", start: 0, end: 1),
            .init(text: "store yesterday.", start: 1, end: 2),
            .init(text: "It was closed.", start: 2.1, end: 3),
        ]
        let result = DubPunctuationRestorer.restore(cues, language: "en")
        #expect(result.coverage == .complete)
        #expect(result.insertedCount == 0)
        #expect(result.text == "I went to the store yesterday. It was closed.")
    }

    @Test func restoredPunctuationAvoidsForcedMidPhraseChunks() throws {
        let phrases = (0..<24).map { "第\($0)段我们继续讨论这个产品的设计细节" }
        let cues = phrases.enumerated().map { index, text in
            SubtitleScriptImporter.Cue(text: text, start: Double(index) * 3, end: Double(index) * 3 + 2.9)
        }
        let raw = DubPunctuationRestorer.restore(cues, language: "zh")
        let unpunctuated = try DubChunkPlanner.plan(raw.originalText, language: "zh", tokenCount: DubChunkPlanner.estimatedTokenCount)
        let punctuated = try DubChunkPlanner.plan(raw.text, language: "zh", tokenCount: DubChunkPlanner.estimatedTokenCount)
        #expect(unpunctuated.chunks.dropLast().contains { $0.forcedBoundary && $0.reasons.contains("continuation") })
        #expect(punctuated.chunks.dropLast().allSatisfy { chunk in
            chunk.text.last.map { "。，".contains($0) } ?? false
        })
    }

    @Test func aiPunctuationRejectsChangedWords() async throws {
        let accepted = try await DubPunctuationRequest(script: "hello there how are you", language: "en")
            .complete(using: PunctuationStub { _ in "Hello there, how are you?" })
        #expect(accepted.text == "Hello there, how are you?")
        #expect(accepted.acceptedBatches == 1)

        let rejected = try await DubPunctuationRequest(script: "hello there how are you", language: "en")
            .complete(using: PunctuationStub { _ in "Hi there, how are you doing?" })
        #expect(rejected.text == "hello there how are you")
        #expect(rejected.acceptedBatches == 0)
    }
}
