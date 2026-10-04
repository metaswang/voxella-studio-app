import Foundation
import Testing
@testable import VoxstudioPro

private actor ElasticTranslationStub: LLMTextClient {
    let text: String
    init(_ text: String) { self.text = text }
    func complete(system: String, user: String) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["translations": [["id": 0, "text": text]]])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite struct ElasticSubtitleTests {
    @Test func badLengthCompliantHintsCannotSplitProtectedChinesePhrase() throws {
        let text = "打开之后你的骨头慢慢就可以归位。但是这个做这个有个有个问题就是你要特别注意。"
        let result = try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: "zh",
            proposedLines: ["打开之后你的骨头慢慢就可以", "归位。但是这个做这个有个", "有个问题就是你要特别注意。"],
            protectedSpans: ["打开之后你的骨头慢慢就可以归位", "有个问题就是你要特别注意"], start: 273.65, end: 280.68))
        #expect(result.cues.contains { $0.text == "打开之后你的骨头慢慢就可以归位。" })
        #expect(result.cues.allSatisfy { !$0.text.hasPrefix("归位。") })
        #expect(ElasticSubtitleSegmenter.preservesText(result.cues.map(\.range), source: text))
    }

    @Test func shortCompletePhrasesAreNotMergedToFillLayout() throws {
        let result = try ElasticSubtitleSegmenter.optimize(.init(text: "Yes. Thank you.", start: 0, end: 3))
        #expect(result.lines == ["Yes.", "Thank you."])
    }

    @Test func ambiguousProtectionIsIgnored() {
        #expect(ElasticSubtitleSegmenter.uniqueProtectedRanges(["可以", "可以归位"], text: "可以打开，也可以归位").count == 1)
    }

    @Test func graphemesAndTextArePreservedAcrossScripts() throws {
        for text in ["中文 English mixed-script。 다음 문장입니다.", "ภาษาไทยไม่มีช่องว่างระหว่างคำ", "مرحبا بالعالم. هذه جملة أخرى.", "Cafe\u{301} 👨‍👩‍👧‍👦 — don't change  internal  spaces."] {
            let result = try ElasticSubtitleSegmenter.optimize(.init(text: text, start: 0, end: 8))
            #expect(ElasticSubtitleSegmenter.preservesText(result.cues.map(\.range), source: text))
            #expect(result.cues.allSatisfy { Range($0.range, in: text) != nil })
        }
    }

    @Test func inaccurateSpeakerLabelsAndEstimatedPausesAreSoft() throws {
        let words = [
            TranscriptionWord(text: "可以", start: 0, end: 0.8, speaker: "A", speakerConfidence: 0.99, timingQuality: .estimated),
            TranscriptionWord(text: "归位", start: 1.5, end: 2.3, speaker: "B", speakerConfidence: 0.99, speakerBoundary: .soft, timingQuality: .estimated)
        ]
        let text = "可以归位"
        let result = try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: "zh", protectedSpans: [text],
            anchors: ElasticSubtitleSegmenter.anchors(text: text, words: words)))
        #expect(result.lines == [text])
        let hard = words[1].withTimingQuality(.aligned)
        let hardWord = TranscriptionWord(text: hard.text, start: hard.start, end: hard.end, speaker: hard.speaker,
            speakerConfidence: 0.99, speakerBoundary: .hard, timingQuality: .aligned)
        let divided = try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: "zh", protectedSpans: [text],
            anchors: ElasticSubtitleSegmenter.anchors(text: text, words: [words[0], hardWord])))
        #expect(divided.lines == ["可以", "归位"])
    }

    @Test func oldCodableDataDoesNotClaimAlignedTiming() throws {
        let word = try JSONDecoder().decode(TranscriptionWord.self, from: Data(#"{"text":"word","start":1,"end":2}"#.utf8))
        #expect(word.timingQuality == .unknown)
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: Data(#"{"cues":[{"id":0,"sourceIDs":[0],"text":"word","start":1,"end":2,"overBudget":false}],"usesWordTimestamps":true}"#.utf8))
        #expect(track.cues[0].timingQuality == .unknown)
        #expect(track.processingVersion == nil)
        #expect(word.withTimingQuality(.estimated).timingQuality == .estimated)
    }

    @Test func compoundsAndInternalWhitespaceSurviveSpotting() throws {
        let examples = [
            "With an S-curve, just do this and your body will adjust naturally.",
            "...feels different from pressing them down—the stretch and muscle tension change.",
            "After 10 side-to-side sways, move your hands up about two finger-widths and sway again.",
            "After the cross-pattern movement, move your hands up two finger-widths. Sway side to side there, then lower your hands and sway, then move them up again and sway.",
            "After opening it up, your bones can gradually return to place. But be careful: if this movement makes your lower-back pain or numbness worse,",
            "You may also need to avoid certain sports, such as long-distance running, ballet, gymnastics, and even swimming.",
            "Try long-distance walking if it feels comfortable. Keep  internal  spaces unchanged, even with don't and ellipses…"
        ]
        for text in examples {
            let result = try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: "en", start: 0, end: 12))
            #expect(ElasticSubtitleSegmenter.preservesText(result.cues.map(\.range), source: text))
            #expect(result.cues.allSatisfy { !$0.layoutOverflow })
            #expect(result.lines.joined(separator: " ").contains(" - ") == false)
        }
    }

    @Test func translatedLongCueUsesNaturalCutsAndEstimatedTiming() async throws {
        let text = "After the cross-pattern movement, move your hands up two finger-widths. Sway side to side there, then lower your hands and sway, then move them up again and sway."
        let track = SubtitleTrack(sourceLanguage: "zh", language: "zh", cues: [
            .init(id: 68, sourceIDs: [1, 2], text: "上移两个指宽后继续左右摇摆。", start: 241.830, end: 252.763, speaker: "A")
        ])
        let result = try await TranslationTrackBuilder(client: ElasticTranslationStub(text)).build(sourceTrack: track,
            options: .init(targetLanguage: "en"), progress: { _, _, _, _ in })
        #expect(result.cues.count > 1)
        #expect(result.cues.allSatisfy { $0.timingQuality == .estimated && $0.sourceIDs == [68] && $0.end > $0.start })
        #expect(abs(result.cues.first!.start - 241.830) < 0.001)
        #expect(abs(result.cues.last!.end - 252.763) < 0.001)
        #expect(result.text == text)
        #expect(result.processingVersion == "elastic-v1")
    }

    @Test func punctuationCannotMoveNaIntoPreviousCue() {
        let ranges = SubtitleTimingPartitioner.losslessLexicalRanges(cueTexts: ["简单。", "那谢谢吴医生"], sourceTexts: ["简", "单。", "那", "谢", "谢", "吴", "医", "生"])
        #expect(ranges == [0..<2, 2..<8])
        #expect(SubtitleTimingPartitioner.losslessLexicalRanges(cueTexts: ["Corrected text"], sourceTexts: ["Different", "text"]) == nil)
    }

    @Test func missingWordTimesUseEstimatedLocalTiming() throws {
        let text = "This complete first sentence fits. This second sentence is independently complete."
        let track = try LocalSubtitleProcessor.process(.init(text: text, language: "en", words: [], segments: [.init(text: text, start: 0, end: 9)]))
        #expect(!track.usesWordTimestamps)
        #expect(track.cues.count >= 2)
        #expect(track.cues.allSatisfy { $0.timingQuality == .estimated && $0.end > $0.start })
        #expect(track.text == text)
    }

    @Test func replayMultilingualBenchmarkAndExportTwoLines() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Experiments/subtitle_segmentation_20260907/dataset.json"))
        let samples = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var metrics: [[String: Any]] = []
        for sample in samples {
            let text = sample["text"] as! String
            let protection = sample["protected_phrases"] as! [String]
            let language = sample["language"] as! String
            let result = try ElasticSubtitleSegmenter.optimize(.init(text: text, languageCode: language, protectedSpans: protection))
            let protected = ElasticSubtitleSegmenter.uniqueProtectedRanges(protection, text: text)
            let broken = result.cues.dropLast().filter { cue in protected.contains { $0.location < NSMaxRange(cue.range) && NSMaxRange(cue.range) < NSMaxRange($0) } }.count
            #expect(ElasticSubtitleSegmenter.preservesText(result.cues.map(\.range), source: text))
            #expect(broken == 0)
            #expect(result.cues.allSatisfy { !$0.layoutOverflow })
            metrics.append(["id": sample["id"]!, "language": language, "cueCount": result.cues.count, "protectedPhraseBreaks": broken, "lossless": true, "layoutOverflow": result.cues.filter(\.layoutOverflow).count])
        }
        #expect(samples.count == 65)
        if let output = ProcessInfo.processInfo.environment["VOXSTUDIO_SUBTITLE_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["samples": metrics, "provenance": "Synthetic multilingual benchmark; reference cuts are not human gold"], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("benchmark.json"))
        }
        for format in [SessionExportFormat.srt, .vtt] {
            let rendered = SessionExportFormatter.render(segments: [.init(start: 1, end: 4, text: "cross-pattern movement\nwith two finger-widths", speaker: "A")], format: format, variant: .original, translationOrder: .originalFirst, includeSpeakers: false, includeTimestamps: true, stripEdgePunctuation: false)
            #expect(rendered.contains("cross-pattern movement\nwith two finger-widths"))
        }
    }

    @Test func presentationBreaksNeverChangeCanonicalText() {
        let cue = SubtitleCue(id: 0, sourceIDs: [], text: "Hello world", start: 0, end: 1, speaker: nil, displayLineBreaks: [6])
        #expect(cue.displayText == "Hello\nworld")
        #expect(cue.text == "Hello world")
        let malformed = SubtitleCue(id: 0, sourceIDs: [], text: "👨‍👩‍👧‍👦", start: 0, end: 1, speaker: nil, displayLineBreaks: [1])
        #expect(malformed.displayText == malformed.text)
    }
}
