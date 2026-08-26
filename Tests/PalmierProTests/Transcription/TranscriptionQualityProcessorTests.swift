import Testing
@testable import PalmierPro

@Suite("Transcription quality processing")
struct TranscriptionQualityProcessorTests {
    @Test func normalizesChineseAndCantoneseHintsForASRAndOutput() {
        let simplified = TranscriptionLanguage(code: "zh-Hans")
        #expect(simplified.asrLanguageCode == "zh")
        #expect(simplified.outputLanguageCode == "zh-CN")
        #expect(simplified.chineseScript?.applying(to: "漢語龍馬") == "汉语龙马")

        let cantoneseTraditional = TranscriptionLanguage(code: "yue-TW")
        #expect(cantoneseTraditional.asrLanguageCode == "yue")
        #expect(cantoneseTraditional.outputLanguageCode == "yue-TW")
        #expect(cantoneseTraditional.chineseScript?.applying(to: "汉语龙马") == "漢語龍馬")

        #expect(WorkbenchTranscriptionLanguage.allCases.map(\.languageCode).contains("zh-CN"))
        #expect(WorkbenchTranscriptionLanguage.allCases.map(\.languageCode).contains("zh-TW"))
        #expect(WorkbenchTranscriptionLanguage.allCases.map(\.languageCode).contains("yue-CN"))
        #expect(WorkbenchTranscriptionLanguage.allCases.map(\.languageCode).contains("yue-TW"))
    }

    @Test func trimsRepeatedSuffixBeforeAlignment() {
        let processed = TranscriptionQualityProcessor.preprocess(
            spans: [.init(text: "系统正在测试 系统正在测试 系统正在测试", startTime: 0, endTime: 1)],
            languageCode: "zh"
        )

        #expect(processed.spans.map(\.text) == ["系统正在测试"])
        #expect(processed.statistics.trimmedRepeatedSpans == 1)
        #expect(processed.statistics.warning == "Transcript quality filter trimmed 1 repeated ASR span.")
    }

    @Test func trimsDegenerateInteriorCJKRunBeforeAlignment() {
        let processed = TranscriptionQualityProcessor.preprocess(
            spans: [.init(text: "平衡歪歪歪歪歪歪歪歪歪歪歪歪歪然后继续", startTime: 0, endTime: 2)],
            languageCode: "zh"
        )

        #expect(processed.spans.map(\.text) == ["平衡歪然后继续"])
        #expect(processed.statistics.trimmedRepeatedSpans == 1)
    }

    @Test func preservesShortNaturalCJKRepetition() {
        let processed = TranscriptionQualityProcessor.preprocess(
            spans: [.init(text: "对对对我明白", startTime: 0, endTime: 1)],
            languageCode: "zh"
        )

        #expect(processed.spans.map(\.text) == ["对对对我明白"])
        #expect(processed.statistics.trimmedRepeatedSpans == 0)
    }

    @Test func qualityLeavesCrossSpanPrefixesForOwnership() {
        let processed = TranscriptionQualityProcessor.preprocess(
            spans: [
                .init(text: "Welcome to Voxella", startTime: 0, endTime: 2),
                .init(text: "to Voxella Studio", startTime: 2.05, endTime: 4),
                .init(text: "to Voxella again", startTime: 5, endTime: 7),
            ],
            languageCode: "en"
        )

        #expect(processed.spans.map(\.text) == [
            "Welcome to Voxella",
            "to Voxella Studio",
            "to Voxella again",
        ])
        #expect(processed.statistics.removedCrossSpanPrefixes == 0)
    }

    @Test func ownershipStripsShortAdjacentDuplicatePrefixFromLaterSpan() {
        let resolved = ASROwnershipResolver.resolve(
            spans: [
                .init(text: "Welcome to Voxella", startTime: 0, endTime: 2),
                .init(text: "to Voxella Studio", startTime: 2.05, endTime: 4),
                .init(text: "to Voxella again", startTime: 5, endTime: 7),
            ],
            languageCode: "en"
        )

        #expect(resolved.spans.map(\.text) == ["Welcome to Voxella", "Studio", "to Voxella again"])
        #expect(resolved.removedDuplicatePrefixes == 1)
        #expect(resolved.removedDuplicateSuffixes == 0)
    }

    @Test func ownershipKeepsLaterSpanWhenCJKOverlapIsLong() {
        let prefix = "然后才知道我这位学弟当年考试的成绩非常优秀"
        let overlap = "他考进了台湾大学的土木工程系"
        let resolved = ASROwnershipResolver.resolve(
            spans: [
                .init(text: prefix + overlap, startTime: 80, endTime: 88.32),
                .init(text: overlap + "后来又念了土木工程的研究所", startTime: 88.40, endTime: 91.04),
            ],
            languageCode: "zh"
        )

        #expect(resolved.spans.map(\.text) == [
            prefix,
            overlap + "后来又念了土木工程的研究所",
        ])
        #expect(resolved.spans[0].startTime == 80)
        #expect(resolved.spans[0].endTime == 88.32)
        #expect(resolved.removedDuplicateSuffixes == 1)
        #expect(resolved.removedDuplicatePrefixes == 0)
    }

    @Test func ownershipIgnoresDuplicatePrefixAcrossWideGap() {
        let resolved = ASROwnershipResolver.resolve(
            spans: [
                .init(text: "Welcome to Voxella", startTime: 0, endTime: 2),
                .init(text: "to Voxella Studio", startTime: 2.5, endTime: 4),
            ],
            languageCode: "en"
        )

        #expect(resolved.spans.map(\.text) == ["Welcome to Voxella", "to Voxella Studio"])
        #expect(resolved.removedDuplicatePrefixes == 0)
    }

    @Test func ownershipKeepsNaturalRepetitionWhenRecognitionWindowsDoNotOverlap() {
        let resolved = ASROwnershipResolver.resolve(
            spans: [
                .init(text: "很好。", startTime: 1.0, endTime: 1.4, inputStart: 0, inputEnd: 5),
                .init(text: "很好。", startTime: 1.5, endTime: 1.9, inputStart: 10, inputEnd: 15),
            ],
            languageCode: "zh"
        )

        #expect(resolved.spans.map(\.text) == ["很好。", "很好。"])
        #expect(resolved.removedDuplicatePrefixes == 0)
        #expect(resolved.removedDuplicateSuffixes == 0)
    }

    @Test func ownershipStripsOnlyProvenOverlapFromSharedRecognitionContext() {
        let resolved = ASROwnershipResolver.resolve(
            spans: [
                .init(
                    text: "为什么今天会邀请吴国斌",
                    startTime: 0,
                    endTime: 28,
                    inputStart: 0,
                    inputEnd: 28.75
                ),
                .init(
                    text: "会邀请吴国斌吴奇医师",
                    startTime: 28,
                    endTime: 56,
                    inputStart: 27.25,
                    inputEnd: 56.75
                ),
            ],
            languageCode: "zh"
        )

        #expect(resolved.spans.map(\.text) == ["为什么今天会邀请吴国斌", "吴奇医师"])
        #expect(resolved.removedDuplicatePrefixes == 1)
        #expect(resolved.spans.map(\.text).joined() == "为什么今天会邀请吴国斌吴奇医师")
    }

    @Test func postprocessingConvertsTimedWordsWithoutChangingTimingOrSpeakers() {
        let original = [TranscriptionWord(text: "汉语", start: 1.2, end: 1.7, speaker: "Speaker 1")]
        let processed = TranscriptionQualityProcessor.postprocess(original, chineseScript: .traditional)

        #expect(processed.map(\.text) == ["漢語"])
        #expect(processed.map(\.start) == original.map(\.start))
        #expect(processed.map(\.end) == original.map(\.end))
        #expect(processed.map(\.speaker) == original.map(\.speaker))
    }
}
