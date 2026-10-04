import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Rule-based multilingual dub planning")
struct DubChunkPlannerTests {
    static let story = "On a rainy afternoon, Emma found a small red umbrella on a bench near the park. She looked around, but no one was there. Instead of taking it home, she waited under a tree, hoping the owner would return. Twenty minutes later, an old woman hurried toward the bench. She looked worried and searched everywhere. Emma walked over and asked, “Are you looking for this?” The woman smiled with relief. “Yes! My husband gave it to me many years ago.” She thanked Emma warmly. As Emma walked home in the rain, she felt happy. A small act of kindness had made someone’s day."

    private func plan(_ text: String, language: String = "en", budget: DubChunkPlanner.Budget = .init()) throws -> DubChunkPlanner.Plan {
        try DubChunkPlanner.plan(text, language: language, budget: budget, tokenCount: DubChunkPlanner.estimatedTokenCount)
    }

    private func checkCoverage(_ plan: DubChunkPlanner.Plan) {
        let source = plan.source as NSString
        #expect(plan.chunks.map { source.substring(with: $0.range) }.joined().utf8.elementsEqual(plan.source.utf8))
        #expect(plan.units.map { source.substring(with: $0.range) }.joined().utf8.elementsEqual(plan.source.utf8))
        #expect(plan.chunks.allSatisfy { !$0.text.isEmpty })
        #expect(plan.units.map(\.id).count == Set(plan.units.map(\.id)).count)
    }

    @Test func storyRulesKeepQuestionAnswerAndClosingAttributionTogether() throws {
        let result = try plan(Self.story)
        checkCoverage(result)
        #expect(result.units.count == 11)
        #expect(result.units[7].text == "“Yes! My husband gave it to me many years ago.”")
        #expect(result.chunks.map(\.text.count) == [203, 263, 96])
        #expect(result.chunks.map(\.endUnitID) == ["U003", "U009", "U011"])
        #expect(result.chunks[0].reasons.contains("time-transition"))
        #expect(result.chunks[1].reasons.contains("scene-transition"))
    }

    @Test func rulesAreIndependentOfStoryNamesAndDurations() throws {
        let renamed = Self.story.replacingOccurrences(of: "Emma", with: "Anna").replacingOccurrences(of: "Twenty", with: "Thirty")
        let result = try plan(renamed)
        #expect(result.chunks.map(\.endUnitID) == ["U003", "U009", "U011"])
        #expect(result.chunks[1].text.contains("“Yes! My husband"))
        checkCoverage(result)
    }

    @Test(arguments: [
        ("zh", "她问：“是你的吗？请看看。”他回答：“是的！谢谢。”随后，他们一起回家。"),
        ("ja", "彼女は「あなたのですか？見てください。」と尋ねた。彼は「はい！ありがとう。」と答えた。"),
        ("ko", "그녀는 “당신 것인가요? 확인해 주세요.”라고 물었다. 그는 “네! 고마워요.”라고 답했다."),
        ("fr", "Elle demanda : « C’est à vous ? Regardez. » Il répondit : « Oui ! Merci. »"),
        ("de", "Sie fragte: „Ist es deins? Schau nach.“ Er sagte: „Ja! Danke.“"),
        ("es", "Ella preguntó: “¿Es tuyo? Mira.” Él respondió: “¡Sí! Gracias.”"),
        ("pt", "Ela perguntou: “É seu? Olhe.” Ele respondeu: “Sim! Obrigado.”"),
        ("it", "Lei chiese: “È tuo? Guarda.” Lui rispose: “Sì! Grazie.”"),
        ("ru", "Она спросила: «Это ваше? Посмотрите.» Он ответил: «Да! Спасибо.»"),
        ("ar", "سألت: «هل هذا لك؟ انظر.» أجاب: «نعم! شكراً.»"),
        ("th", "เธอถามว่า “นี่เป็นของคุณไหม? ดูสิ.” เขาตอบว่า “ใช่! ขอบคุณ.”")
    ])
    func multilingualQuotesAndSourceOffsets(_ fixture: (String, String)) throws {
        let result = try plan(fixture.1, language: fixture.0)
        checkCoverage(result)
        let source = result.source as NSString
        for unit in result.units.dropLast() {
            let prefix = source.substring(to: NSMaxRange(unit.range))
            for (open, close) in [("“", "”"), ("«", "»"), ("「", "」"), ("„", "“")] where fixture.1.contains(open) && fixture.1.contains(close) {
                #expect(prefix.filter { String($0) == open }.count == prefix.filter { String($0) == close }.count)
            }
        }
    }

    @Test func abbreviationsDecimalsIdentifiersAndApostrophesAreProtected() throws {
        let text = "Mr. Lee paid 3.14 dollars. Visit https://example.org/a.b or email jane.doe@example.com. Don't lose someone’s book or the students' notes. It belongs to them."
        let result = try plan(text, budget: .init(maximumCharacters: 80))
        checkCoverage(result)
        #expect(result.units.first?.text == "Mr. Lee paid 3.14 dollars.")
        #expect(result.chunks.contains { $0.text.contains("https://example.org/a.b") })
        #expect(result.chunks.contains { $0.text.contains("jane.doe@example.com") })
        #expect(result.units.last?.text == "It belongs to them.")
        #expect(result.units.contains { $0.text.contains("students' notes.") })
    }

    @Test func paragraphIsBoundaryCandidateWithoutSentencePunctuation() throws {
        let result = try plan("An opening without punctuation\n\nA different topic without punctuation")
        checkCoverage(result)
        #expect(result.units.count == 2)
        #expect(result.units[1].paragraphBefore)
        #expect(result.chunks.count == 2)
    }

    @Test func whitespaceOnlyPrefixesAndUnicodeParagraphSeparatorsArePreserved() throws {
        let result = try plan("\n\n  A whole sentence.\n\n")
        checkCoverage(result)
        #expect(result.chunks.count == 1)
        #expect(result.chunks.first?.text == "A whole sentence.")
        let payload = DubFlowPayload(segments: [.init(index: 0, text: "开场没有标点\u{2029}新话题开始了\n \n另一个话题结束了")], language: "zh", model: .medium, reference: nil, speakerReferences: [:])
        let prepared = try SemanticDubPreprocessor.prepare(payload)
        #expect(prepared.map(\.segment.text) == ["开场没有标点", "新话题开始了", "另一个话题结束了"])
    }

    @Test func oversizedQuoteUsesMarkedWordBoundariesAndKeepsQuoteOwnership() throws {
        let text = "“" + String(repeating: "These words must all survive, ", count: 12) + "finished.”"
        let result = try plan(text, budget: .init(maximumCharacters: 70))
        checkCoverage(result)
        #expect(result.chunks.count > 2)
        #expect(result.chunks.allSatisfy { $0.text.count <= 70 })
        #expect(result.chunks.dropLast().allSatisfy { $0.forcedBoundary })
        #expect(result.chunks.first?.text.first == "“")
        #expect(result.chunks.last?.text.last == "”")
        #expect(!result.chunks.contains { $0.text == "”" })
        let words = result.chunks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
        #expect(words == text.split(whereSeparator: \.isWhitespace))
    }

    @Test func overBudgetIdentifierFailsInsteadOfSplittingOrTruncating() {
        #expect(throws: DubChunkPlanner.Failure.self) {
            try plan("Visit https://example.com/" + String(repeating: "a", count: 150), budget: .init(maximumCharacters: 30))
        }
        #expect(throws: DubChunkPlanner.Failure.self) {
            try plan(String(repeating: "x", count: 200), budget: .init(maximumCharacters: 30))
        }
    }

    @Test func injectedTokenCounterControlsTheActualBudget() throws {
        let text = "One two three four five six seven eight nine ten. Eleven twelve thirteen fourteen fifteen."
        let counter: (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count * 3 }
        let result = try DubChunkPlanner.plan(text, language: "en", budget: .init(maximumTextTokens: 15), tokenCount: counter)
        checkCoverage(result)
        #expect(result.chunks.count >= 3)
        #expect(result.chunks.allSatisfy { $0.textTokens == counter($0.text) && $0.textTokens <= 15 })
    }

    @Test func automaticChineseAndUTF16OffsetsHandleGraphemeClusters() throws {
        let text = "她带着红伞回家。随后，她说：“太好了！谢谢。”\n\n家人微笑了👨‍👩‍👧‍👦。Café e\u{301} 😀."
        let result = try plan(text, language: "auto")
        checkCoverage(result)
        #expect(result.language == "zh")
        #expect(result.chunks.contains { $0.text.contains("👨‍👩‍👧‍👦") })
        #expect(result.chunks.contains { $0.text.contains("e\u{301}") })
    }

    @Test func splitVideoWindowUsesRelativeSpeechLengthAndExactEndpoints() throws {
        let payload = DubFlowPayload(segments: [.init(index: 0, text: Self.story, start: 10, end: 50)], language: "en", model: .medium, reference: nil, speakerReferences: [:], timelineMode: .videoTimeline)
        let result = try SemanticDubPreprocessor.prepare(payload)
        #expect(result.count == 3)
        #expect(result.first?.segment.start == 10 && result.last?.segment.end == 50)
        #expect(result[0].segment.end == result[1].segment.start)
        #expect(result[1].segment.end == result[2].segment.start)
        #expect(result[1].segment.end! - result[1].segment.start! > result[2].segment.end! - result[2].segment.start!)
    }

    @Test func longInputUsesBoundedCandidateWindows() throws {
        let text = String(repeating: "这是一个完整的句子。随后，另一个场景开始了。", count: 200)
        var calls = 0
        let result = try DubChunkPlanner.plan(text, language: "zh") { calls += 1; return DubChunkPlanner.estimatedTokenCount($0) }
        checkCoverage(result)
        #expect(result.chunks.count > 10)
        #expect(calls < result.units.count * 25)
        #expect(result.chunks.allSatisfy { $0.textTokens <= 64 && $0.estimatedSeconds <= 28 })
    }

    @Test func cancellationStopsCPUPlanning() async {
        let work = Task {
            try Task.checkCancellation()
            return try plan(String(repeating: "A short sentence. ", count: 1_000))
        }
        work.cancel()
        do { _ = try await work.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func videoAnchorsAndVoiceAssignmentsRemainHardBoundaries() throws {
        let voice = DubVoiceReference(audioURL: URL(fileURLWithPath: "/tmp/selected.wav"), transcript: "Reference")
        var payload = DubFlowPayload(segments: [
            .init(index: 3, text: "A short first sentence.", start: 10, end: 12, speaker: "A", sourceSubtitleID: 31),
            .init(index: 7, text: "A short second sentence.", start: 15, end: 18, speaker: "A", sourceSubtitleID: 32)
        ], language: "en", model: .medium, reference: nil, speakerReferences: [:], timelineMode: .videoTimeline)
        let timed = try SemanticDubPreprocessor.prepare(payload)
        #expect(timed.count == 2)
        #expect(timed.map(\.segment.start) == [10, 15])
        #expect(timed.map(\.segment.end) == [12, 18])
        payload.timelineMode = .audioFlow
        #expect(try SemanticDubPreprocessor.prepare(payload).count == 1)
        payload.segmentReferences = [7: voice]
        let selected = try SemanticDubPreprocessor.prepare(payload)
        #expect(selected.count == 2)
        #expect(selected.last?.reference == voice && selected.last?.segment.index == 7)
        #expect(selected.map(\.segment.sourceSubtitleID) == [31, 32])
    }

    @Test func sourceMetadataTracksChunkStartAfterSubtitleMerge() throws {
        let payload = DubFlowPayload(segments: [
            .init(index: 0, text: "An opening without punctuation", sourceSubtitleID: 4),
            .init(index: 1, text: "\n\n", sourceSubtitleID: 5),
            .init(index: 2, text: "A different topic starts later. It ends here.", sourceSubtitleID: 6)
        ], language: "en", model: .medium, reference: nil, speakerReferences: [:])
        let prepared = try SemanticDubPreprocessor.prepare(payload, configuration: .init(maximumSequenceCharacters: 45))
        #expect(prepared.first?.segment.sourceSubtitleID == 4)
        #expect(prepared.last?.segment.sourceSubtitleID == 6)
    }

    @Test func rendererDoesNotResplitLongFinalInputs() throws {
        let payload = DubFlowPayload(segments: [.init(index: 0, text: Self.story)], language: "en", model: .medium, reference: nil, speakerReferences: [:])
        let prepared = try LocalDubFlowRenderer.prepare(payload)
        #expect(prepared.map(\.source.text.count) == [203, 263, 96])
        #expect(prepared.allSatisfy { $0.chunks == [$0.source.text] })
        #expect(prepared.last?.source.text.hasSuffix("someone’s day.") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"))
    func installedQwenTokenizerPlansAWithoutLoadingWeights() async throws {
        let payload = DubFlowPayload(segments: [.init(index: 0, text: Self.story)], language: "en", model: .medium, reference: nil, speakerReferences: [:])
        let prepared = try await DubPreprocessingRuntime.shared.prepare(payload)
        #expect(prepared.map(\.source.text.count) == [203, 263, 96])
        #expect(prepared.allSatisfy { $0.chunks == [$0.source.text] })
        #expect(prepared.map(\.planning.textTokens) == [46, 56, 23])
        #expect(prepared.map(\.planning.endUnitID) == ["U003", "U009", "U011"])
        print("[dub-planner] actual Qwen tokenizer: \(prepared.map(\.planning.textTokens)), source characters: \(prepared.map(\.source.text.count))")
        if let path = ProcessInfo.processInfo.environment["VOXSTUDIO_DUB_PLAN_REPORT"] {
            let report: [String: Any] = [
                "planner": DubChunkPlanner.version, "language": payload.language,
                "maximumTargetTextTokens": 64, "newTTSCalls": 0,
                "chunks": prepared.map { segment -> [String: Any] in
                    let c = segment.planning
                    return ["text": segment.source.text, "characters": segment.source.text.count,
                            "tokens": c.textTokens, "sourceUTF16Location": c.range.location,
                            "sourceUTF16Length": c.range.length, "endUnitID": c.endUnitID,
                            "estimatedSeconds": c.estimatedSeconds, "forcedBoundary": c.forcedBoundary,
                            "reasons": c.reasons, "ttsInputCount": segment.chunks.count]
                }
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
