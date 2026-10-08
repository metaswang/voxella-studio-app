import Testing
@testable import VoxstudioPro

@Suite("Transcript segment aggregation")
struct TranscriptSegmenterTests {
    @Test func subtitleDisplayPreservesClosingQuotes() {
        let cases: [(String, String)] = [
            ("“Are you looking for this?”", "“Are you looking for this?”"),
            ("“Yes!", "“Yes!"),
            ("My husband gave it to me many years ago.”", "My husband gave it to me many years ago”"),
            ("\"Hello.\"", "\"Hello\""),
            ("'Hello.'", "'Hello'"),
            ("`Hello.`", "`Hello`"),
            ("「你好。」", "「你好」"),
            ("『你好！』", "『你好！』"),
            ("«Hello.»", "«Hello»"),
            ("＂你好？＂", "＂你好？＂"),
            ("‘Hello.’", "‘Hello’"),
            ("He said “'Hello.'”", "He said “'Hello'”"),
            (" Hello.,;:… ", "Hello"),
            ("Really?!？！", "Really?!？！"),
        ]
        for (source, expected) in cases {
            #expect(TranscriptSegmenter.renderedSubtitleText(source) == expected)
        }
    }

    @Test func aggregatesSpeakerRunsUsingThePostprocessWindow() {
        var words = (0..<14).map { index in
            Self.word("word\(index)", Double(index * 5), Double((index + 1) * 5), "Speaker 1")
        }
        words.append(Self.word("reply", 70, 71, "Speaker 2"))

        let segments = TranscriptSegmenter.aggregate(words: words)

        #expect(segments.count == 3)
        #expect(segments.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2"])
        #expect(segments[0].start == 0)
        #expect(segments[0].end == TranscriptSegmenter.minimumDuration)
        #expect(segments[1].start == TranscriptSegmenter.minimumDuration)
        #expect(segments[1].end == 70)
    }

    @Test func aggregatesUnlabeledSpeechWithAFlexibleLanguageNeutralTarget() {
        let segments = TranscriptSegmenter.aggregate(words: [
            Self.word("你", 0, 8, nil),
            Self.word("好", 8, 16, nil),
            Self.word("world", 16, 24, nil),
            Self.word("again", 24, 32, nil),
            Self.word("later", 32, 40, nil),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].text == "你好 world again later")
        #expect(segments[0].end == 40)
        #expect(segments.allSatisfy { $0.speaker == nil })
    }

    @Test func normalizesWhitespaceBetweenCJKCharactersWithoutCollapsingLatinWords() {
        #expect(TranscriptSegmenter.normalizeDisplayText("你 的 天目  world  again") == "你的天目 world again")
        #expect(TranscriptSegmenter.joinedText(["你 的", "天目", "。", "下一句"]) == "你的天目。下一句")
        #expect(
            TranscriptSegmenter.normalizeDisplayText(
                "你 是 1996 年 得法 OK 世界  world",
                language: "zh-CN"
            ) == "你是1996年得法OK世界world"
        )
        #expect(
            TranscriptSegmenter.normalizeDisplayText(
                "Welcome to VoxStudio. This sentence stays readable.",
                language: "en"
            ) == "Welcome to VoxStudio. This sentence stays readable."
        )
        #expect(
            TranscriptSegmenter.normalizeDisplayText("你好。 下一句", language: "zh-CN")
                == "你好。下一句"
        )
    }

    @Test func closesSpacesAroundEnglishContractionApostrophes() {
        #expect(TranscriptSegmenter.normalizeDisplayText("it ' s not") == "it's not")
        #expect(TranscriptSegmenter.joinedText(["I", "’", "m", "ready"]) == "I’m ready")
        #expect(TranscriptSegmenter.normalizeDisplayText("James ' s book") == "James's book")
        #expect(TranscriptSegmenter.normalizeDisplayText("he said ' hello'") == "he said ' hello'")

        let segments = TranscriptSegmenter.aggregate(words: [
            Self.word("it", 0, 0.2, nil),
            Self.word("'", 0.2, 0.3, nil),
            Self.word("s", 0.3, 0.4, nil),
            Self.word("not", 0.4, 0.6, nil),
        ])
        #expect(segments.first?.text == "it's not")
    }

    @Test func keepsCanonicalPunctuationSeparateFromSubtitleDisplayText() {
        let track = SubtitleTrack(
            sourceLanguage: "zh-CN",
            language: "zh-CN",
            cues: [
                SubtitleCue(
                    id: 0,
                    sourceIDs: [0],
                    text: "真的吗？！",
                    start: 0,
                    end: 2,
                    speaker: nil
                ),
                SubtitleCue(
                    id: 1,
                    sourceIDs: [1],
                    text: "请立即预定。",
                    start: 2,
                    end: 4,
                    speaker: nil
                ),
            ]
        )

        #expect(track.cues.map(\.text) == ["真的吗？！", "请立即预定。"])
        #expect(
            track.cues.map { TranscriptSegmenter.renderedSubtitleText($0.text) }
                == ["真的吗？！", "请立即预定"]
        )
    }

    @Test func keepsLanguageAwareSpacingWhenRebuildingPublicSegments() {
        let result = TranscriptionResult(
            text: "你 是 1996 年",
            language: "zh-CN",
            words: [],
            segments: [
                TranscriptionSegment(text: "你 是", start: 0, end: 2, speaker: "Speaker 1"),
                TranscriptionSegment(text: "1996 年", start: 2, end: 4, speaker: "Speaker 1"),
            ]
        )

        let rebuilt = result.aggregatingSegments()

        #expect(rebuilt.segments.count == 1)
        #expect(rebuilt.segments[0].text == "你是1996年")
        #expect(rebuilt.text == "你是1996年")
    }

    @Test func mergesATinyTailWithinTheSoftCapWithoutSplittingSubtitleCues() {
        let sourceCues = (0..<62).map { index in
            TranscriptionSegment(
                text: "word\(index)",
                start: Double(index),
                end: Double(index + 1),
                speaker: "Speaker 1"
            )
        }

        let segments = TranscriptSegmenter.aggregate(segments: sourceCues)

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 62)
        #expect(segments[0].speaker == "Speaker 1")
    }

    @Test func keepsAnOversizedSourceCueIntact() {
        let source = TranscriptionSegment(
            text: "A single corrected subtitle cue that must not be split.",
            start: 10,
            end: 77,
            speaker: "Speaker 1"
        )

        let segments = TranscriptSegmenter.aggregate(segments: [source])

        #expect(segments.count == 1)
        #expect(segments[0].text == source.text)
        #expect(segments[0].start == source.start)
        #expect(segments[0].end == source.end)
    }

    @Test func cutsBeforeTheCueThatCrossesTheMaximumDuration() {
        let sourceCues = (0..<3).map { index in
            TranscriptionSegment(
                text: "cue\(index)",
                start: Double(index * 45),
                end: Double((index + 1) * 45),
                speaker: "Speaker 1"
            )
        }

        let segments = TranscriptSegmenter.aggregate(segments: sourceCues)

        #expect(segments.map(\.text) == ["cue0", "cue1", "cue2"])
        #expect(segments.map(\.start) == [0, 45, 90])
        #expect(segments.map(\.end) == [45, 90, 135])
        #expect(segments.allSatisfy { $0.end - $0.start <= TranscriptSegmenter.maximumDuration })
    }

    @Test func assigningSpeakerUpdatesWordsAndRebuildsSpeakerBoundaries() {
        let transcript = TranscriptionResult(
            text: "one two three",
            language: "en",
            words: [
                Self.word("one", 0, 0.5, "Speaker 1"),
                Self.word("two", 0.5, 1, "Speaker 2"),
                Self.word("three", 1, 1.5, "Speaker 2"),
            ],
            segments: []
        )

        let updated = transcript.assigningSpeaker("Speaker 1", from: 0.5, to: 1)

        #expect(updated.words.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2"])
        #expect(updated.segments.count == 2)
        #expect(updated.segments[0].text == "one two")
        #expect(updated.segments[0].end == 1)
    }

    @Test func renamingSpeakerPreservesStableTimingAcrossTranscriptAndSubtitleTrack() {
        let transcript = TranscriptionResult(
            text: "hello",
            language: "en",
            words: [Self.word("hello", 2, 3, "Speaker 1")],
            segments: [
                TranscriptionSegment(text: "hello", start: 2, end: 3, speaker: "Speaker 1"),
            ]
        )
        let track = SubtitleTrack(
            sourceLanguage: "en",
            language: "en",
            cues: [
                SubtitleCue(
                    id: 4,
                    sourceIDs: [7],
                    text: "hello",
                    start: 2,
                    end: 3,
                    speaker: "Speaker 1"
                ),
            ]
        )

        let renamedTranscript = transcript.renamingSpeaker("Speaker 1", to: "Alice")
        let renamedTrack = track.renamingSpeaker("Speaker 1", to: "Alice")

        #expect(renamedTranscript.words.first?.speaker == "Alice")
        #expect(renamedTranscript.segments.first?.speaker == "Alice")
        #expect(renamedTranscript.segments.first?.start == 2)
        #expect(renamedTranscript.segments.first?.end == 3)
        #expect(renamedTrack.cues.first?.speaker == "Alice")
        #expect(renamedTrack.cues.first?.id == 4)
        #expect(renamedTrack.cues.first?.sourceIDs == [7])
    }

    // zh_L_R004S01C01 06:52–06:54: the aligner put 高 on its 80 ms grid with
    // start == end; the segment rendered "档烟的话".
    @Test func keepsZeroWidthAlignerUnitsInSegments() {
        let words = [
            Self.word("得。", 412.016, 412.096, "Speaker 1"),
            Self.word("对", 412.496, 412.496, nil),
            Self.word("高", 413.296, 413.296, "Speaker 5"),
            Self.word("档", 413.296, 413.456, "Speaker 5"),
            Self.word("烟", 413.456, 413.616, "Speaker 5"),
            Self.word("开", 506.176, 506.244, "Speaker 5"),
            Self.word("除", 506.244, 506.244, "Speaker 5"),
            Self.word("处", 506.244, 506.244, nil),
            Self.word("理。", 506.244, 506.244, nil),
        ]

        let segments = TranscriptSegmenter.aggregate(words: words, language: "zh")

        #expect(segments.map(\.text).joined() == "得。对高档烟开除处理。")
    }

    @Test func zeroWidthUnitClampedOntoPreviousStartKeepsSourceOrder() {
        let words = [
            Self.word("一", 5.0, 5.3, "Speaker 1"),
            Self.word("二", 5.0, 5.0, "Speaker 1"),
            Self.word("三", 5.3, 5.4, "Speaker 1"),
        ]

        #expect(TranscriptSegmenter.aggregate(words: words, language: "zh").map(\.text) == ["一二三"])
    }

    // zh_L_R004S01C01 05:09–05:16: a 6.4 s host question followed by a long
    // reply. The switch was soft (outgoing confidence 0.839 < 0.84), so the
    // question was merged into the reply and relabeled Speaker 5.
    @Test func sustainedTurnsSplitAtASoftBoundary() {
        var words = [Self.word("了。", 308.864, 309.104, "Speaker 5")]
        words.append(TranscriptionWord(text: "我", start: 309.264, end: 310.304,
                                       speaker: "Speaker 1", speakerBoundary: .hard))
        words += [
            Self.word("说，", 310.304, 310.384, "Speaker 1"),
            Self.word("我", 310.464, 310.464, nil),
            Self.word("那", 310.544, 310.704, "Speaker 1"),
            Self.word("人群", 312.544, 312.864, "Speaker 1"),
            Self.word("购买的？", 314.464, 315.664, "Speaker 1"),
        ]
        words.append(TranscriptionWord(text: "这", start: 315.904, end: 316.144,
                                       speaker: "Speaker 5", speakerBoundary: .soft))
        words += [
            Self.word("咱们", 316.144, 317.024, "Speaker 5"),
            Self.word("中档烟，", 317.424, 318.064, "Speaker 5"),
        ]

        let segments = TranscriptSegmenter.aggregate(words: words, language: "zh")

        #expect(segments.map(\.speaker) == ["Speaker 5", "Speaker 1", "Speaker 5"])
        #expect(segments[1].text == "我说，我那人群购买的？")
    }

    @Test func briefSoftFlickerStaysInTheSurroundingSegment() {
        var words = [Self.word("one", 0, 2, "Speaker 1")]
        words.append(TranscriptionWord(text: "uh", start: 2, end: 2.3,
                                       speaker: "Speaker 2", speakerBoundary: .soft))
        words.append(TranscriptionWord(text: "two", start: 2.3, end: 4,
                                       speaker: "Speaker 1", speakerBoundary: .soft))

        let segments = TranscriptSegmenter.aggregate(words: words)

        #expect(segments.count == 1)
        #expect(segments[0].speaker == "Speaker 1")
    }

    private static func word(
        _ text: String,
        _ start: Double,
        _ end: Double,
        _ speaker: String?
    ) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end, speaker: speaker)
    }
}
