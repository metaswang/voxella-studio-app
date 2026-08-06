import Testing
@testable import PalmierPro

@Suite("Transcript segment aggregation")
struct TranscriptSegmenterTests {
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
                "Welcome to Voxella Studio. This sentence stays readable.",
                language: "en"
            ) == "Welcome to Voxella Studio. This sentence stays readable."
        )
        #expect(
            TranscriptSegmenter.normalizeDisplayText("你好。 下一句", language: "zh-CN")
                == "你好。下一句"
        )
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

    private static func word(
        _ text: String,
        _ start: Double,
        _ end: Double,
        _ speaker: String?
    ) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end, speaker: speaker)
    }
}
