import Testing
@testable import PalmierPro

@Suite("ASR recognition spans")
struct ASRRecognitionSpansTests {
    @Test func joinsWhisperSegmentsOntoTheOwnershipWindow() throws {
        let spans = ASRRecognitionSpans.ownedChunkSpan(
            segmentTexts: ["吴奇医师", "拜他的门下"],
            fallbackText: "ignored",
            recognitionStart: 98.75,
            recognitionEnd: 125.25,
            ownershipStart: 98.75,
            ownershipEnd: 125.25,
            audioDuration: 180
        )

        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.text == "吴奇医师 拜他的门下")
        #expect(span.startTime == 98.75)
        #expect(span.endTime == 125.25)
    }

    @Test func ignoresCompressedWhisperTimestampsWhenBuildingTheAlignmentSpan() throws {
        let result = ASRRecognitionSpans.ownedChunk(
            segments: [
                .init(text: "这也是一个因缘", start: 0, end: 0.04),
            ],
            fallbackText: "这也是一个因缘",
            recognitionStart: 100,
            recognitionEnd: 128,
            ownershipStart: 100.5,
            ownershipEnd: 127.5,
            audioDuration: 600
        )

        let span = try #require(result.spans.first)
        #expect(result.timestampFallbackCount == 1)
        #expect(span.text == "这也是一个因缘")
        #expect(span.endTime - span.startTime == 27)
        #expect(span.startTime == 100.5)
        #expect(span.endTime == 127.5)
    }

    @Test func usesFallbackTextWhenSegmentsAreEmpty() throws {
        let spans = ASRRecognitionSpans.ownedChunkSpan(
            segmentTexts: ["", "  "],
            fallbackText: "欢迎国斌",
            recognitionStart: 0,
            recognitionEnd: 28,
            ownershipStart: 0,
            ownershipEnd: 28,
            audioDuration: 28
        )

        let span = try #require(spans.first)
        #expect(span.text == "欢迎国斌")
        #expect(span.startTime == 0)
        #expect(span.endTime == 28)
    }

    @Test func keepsLongCJKWindowWithContextInsteadOfClippingBoundaryCharacters() throws {
        let text = "为什么今天会邀请吴国斌吴奇医师拜在他的门下学习中医这也是一个因缘后来又念了然后才知道我这位学弟当年考试的成绩非常优秀他考进了台湾大学的人生转折事土木工程的研究所"
        #expect(text.filter { !$0.isWhitespace }.count == 80)

        let result = ASRRecognitionSpans.ownedChunk(
            segments: [.init(text: text, start: nil, end: nil)],
            fallbackText: text,
            recognitionStart: 27.25,
            recognitionEnd: 56.75,
            ownershipStart: 28,
            ownershipEnd: 56,
            audioDuration: 600
        )

        let span = try #require(result.spans.first)
        #expect(span.text.contains("为什么今天"))
        #expect(span.text.contains("土木工程的研究所"))
        #expect(span.text == text)
        #expect(span.startTime == 28)
        #expect(span.endTime == 56)
        #expect(span.inputStart == 27.25)
        #expect(span.inputEnd == 56.75)
    }

    @Test func assignsABoundarySegmentWhollyToOneOwnershipWindow() throws {
        let segment = ASRRecognitionSpans.Segment(text: "研究所", start: 27.6, end: 28.8)

        let leading = ASRRecognitionSpans.ownedChunk(
            segments: [segment],
            fallbackText: "研究所",
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 0,
            ownershipEnd: 28,
            audioDuration: 600
        )
        let trailing = ASRRecognitionSpans.ownedChunk(
            segments: [segment],
            fallbackText: "研究所",
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 28,
            ownershipEnd: 56,
            audioDuration: 600
        )

        #expect(leading.spans.isEmpty)
        let owned = try #require(trailing.spans.first)
        #expect(owned.text == "研究所")
        #expect(owned.startTime == 28)
        #expect(owned.endTime == 56)
    }

    @Test func prefersCompleteFallbackOverIncompleteSegmentTexts() throws {
        let result = ASRRecognitionSpans.ownedChunk(
            segments: [.init(text: "为什么今", start: 0.2, end: 1.1)],
            fallbackText: "为什么今天会邀请吴国斌",
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 0,
            ownershipEnd: 28,
            audioDuration: 600
        )

        let span = try #require(result.spans.first)
        #expect(span.text == "为什么今天会邀请吴国斌")
        #expect(result.timestampFallbackCount == 1)
    }

    @Test func doesNotSplitEnglishWordsWhenContextIsPresent() throws {
        let text = "Why today we invited the civil engineering research institute guest speaker"
        let result = ASRRecognitionSpans.ownedChunk(
            segments: [.init(text: text, start: nil, end: nil)],
            fallbackText: text,
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 0.75,
            ownershipEnd: 28,
            audioDuration: 600
        )

        let span = try #require(result.spans.first)
        #expect(span.text == text)
        #expect(!span.text.hasPrefix("hy"))
        #expect(span.text.split(separator: " ").allSatisfy { $0.count > 1 || $0 == "a" })
    }

    @Test func missingAndInvertedTimestampsFallBackWithoutClipping() throws {
        let text = "为什么今天会邀请吴国斌后来又念了土木工程的研究所"
        let missing = ASRRecognitionSpans.ownedChunk(
            segments: [.init(text: text, start: .nan, end: 4)],
            fallbackText: text,
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 0,
            ownershipEnd: 28,
            audioDuration: 80
        )
        let inverted = ASRRecognitionSpans.ownedChunk(
            segments: [.init(text: text, start: 4, end: 1)],
            fallbackText: text,
            recognitionStart: 0,
            recognitionEnd: 28.75,
            ownershipStart: 0,
            ownershipEnd: 28,
            audioDuration: 80
        )

        #expect(missing.spans.first?.text == text)
        #expect(inverted.spans.first?.text == text)
        #expect(missing.timestampFallbackCount == 1)
        #expect(inverted.timestampFallbackCount == 1)
    }
}
