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
        #expect(cantoneseTraditional.asrLanguageCode == "zh")
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

    @Test func removesOnlyAdjacentDuplicateBoundaryPrefix() {
        let processed = TranscriptionQualityProcessor.preprocess(
            spans: [
                .init(text: "Welcome to Voxella", startTime: 0, endTime: 2),
                .init(text: "to Voxella Studio", startTime: 2.05, endTime: 4),
                .init(text: "to Voxella again", startTime: 5, endTime: 7),
            ],
            languageCode: "en"
        )

        #expect(processed.spans.map(\.text) == ["Welcome to Voxella", "Studio", "to Voxella again"])
        #expect(processed.statistics.removedCrossSpanPrefixes == 1)
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
