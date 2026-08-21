import Foundation
import Testing
@testable import PalmierPro

private actor StubLLMClient: LLMTextClient {
    private var responses: [String]
    private(set) var requests: [(system: String, user: String)] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func complete(system: String, user: String) async throws -> String {
        requests.append((system, user))
        guard !responses.isEmpty else { throw LLMClientError.emptyResponse }
        return responses.removeFirst()
    }

    var requestCount: Int { requests.count }
}

private actor ConcurrencyProbeLLMClient: LLMTextClient {
    private var activeRequests = 0
    private(set) var maximumActiveRequests = 0

    func complete(system: String, user: String) async throws -> String {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        await Task.yield()

        let startTag = "<asr_input>"
        let endTag = "</asr_input>"
        let input: String
        if let start = user.range(of: startTag, options: .backwards),
           let end = user.range(of: endTag, range: start.upperBound..<user.endIndex) {
            input = String(user[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            input = "fallback"
        }
        activeRequests -= 1
        return #"{"subtitles":[""# + input + #""]}"#
    }
}

private actor InputMappedLLMClient: LLMTextClient {
    private let responsesByInput: [String: String]
    private(set) var requests: [(system: String, user: String)] = []

    init(responsesByInput: [String: String]) {
        self.responsesByInput = responsesByInput
    }

    func complete(system: String, user: String) async throws -> String {
        requests.append((system, user))
        let startTag = "<asr_input>"
        let endTag = "</asr_input>"
        guard let start = user.range(of: startTag, options: .backwards),
              let end = user.range(of: endTag, range: start.upperBound..<user.endIndex) else {
            throw LLMClientError.emptyResponse
        }
        let input = String(user[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let response = responsesByInput[input] else { throw LLMClientError.emptyResponse }
        return response
    }

    var requestCount: Int { requests.count }
}

private func assertContinuousCueCoverage(
    _ track: SubtitleTrack,
    sourceWords: [TranscriptionWord]
) throws {
    #expect(track.cues.flatMap(\.sourceIDs) == Array(sourceWords.indices))
    for cue in track.cues {
        let first = try #require(cue.sourceIDs.first)
        let last = try #require(cue.sourceIDs.last)
        let start = try #require(sourceWords[first].start)
        let end = try #require(sourceWords[last].end)
        #expect(cue.start == start)
        #expect(cue.end == end)
    }
}

@Suite("Flexible media flows")
struct MediaFlowTests {
    @Test func subtitleTimingPartitionerPreservesSourceCoverageWithAnchors() {
        let ranges = SubtitleTimingPartitioner.partition(
            cueCount: 3,
            sourceWordCount: 8,
            anchorRanges: [1..<3, 4..<5, 6..<8],
            weights: [2, 1, 2]
        )

        #expect(ranges == [0..<3, 3..<5, 5..<8])
        #expect(ranges.flatMap { Array($0) } == Array(0..<8))
    }

    @Test func subtitleTimingPartitionerInterpolatesWhenAnyAnchorIsMissing() {
        let ranges = SubtitleTimingPartitioner.partition(
            cueCount: 2,
            sourceWordCount: 5,
            anchorRanges: [0..<2, nil],
            weights: [1, 2]
        )

        #expect(ranges == [0..<2, 2..<5])
    }

    @Test func subtitleTimingPartitionerAnchoredRangesRejectMissingAnchors() {
        #expect(
            SubtitleTimingPartitioner.anchoredRanges(
                cueCount: 2,
                sourceWordCount: 5,
                anchorRanges: [0..<2, nil]
            ) == nil
        )
        #expect(
            SubtitleTimingPartitioner.anchoredRanges(
                cueCount: 3,
                sourceWordCount: 8,
                anchorRanges: [1..<3, 4..<5, 6..<8]
            ) == [0..<3, 3..<5, 5..<8]
        )
    }

    @Test func subtitleProcessorKeepsLLMTextWhenRemapIsUnanchored() async throws {
        let client = StubLLMClient(responses: [
            #"{"text":"A concise rewritten opening. A rewritten closing thought."}"#,
            #"{"lines":["A concise rewritten opening.","A rewritten closing thought."]}"#,
        ])
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"].enumerated().map { index, text in
            TranscriptionWord(text: text, start: Double(index), end: Double(index) + 0.5, speaker: "Speaker 1")
        }
        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: words.map(\.text).joined(separator: " "),
                language: "en",
                words: words,
                segments: []
            ),
            options: .init(maximumTokensPerBatch: 8, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(output.track.cues.map(\.text) == [
            "A concise rewritten opening.",
            "A rewritten closing thought.",
        ])
        #expect(output.track.cues.flatMap(\.sourceIDs) == Array(words.indices))
        #expect(output.track.cues.first?.start == 0)
        #expect(output.track.cues.last?.end == 5.5)
        #expect(output.warnings.contains { $0.contains("source-word timing for LLM subtitles") })
        #expect(!output.warnings.contains { $0.contains("source-timed fallback") })
        #expect(await client.requestCount == 2)
    }

    @Test func subtitleTimingAlwaysCoversItsContinuousSourceWordsAfterSplitting() async throws {
        let client = StubLLMClient(responses: [
            #"{"subtitles":["这是一个很长的字幕句子，需要在自然停顿处拆分，并且保持同步。"]}"#,
        ])
        let sourceWords = Array("这是一个很长的字幕句子需要在自然停顿处拆分并且保持同步").enumerated().map { index, character in
            TranscriptionWord(text: String(character), start: Double(index) * 0.1, end: Double(index) * 0.1 + 0.08, speaker: "Speaker 1")
        }
        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: .init(text: sourceWords.map(\.text).joined(), language: "zh", words: sourceWords, segments: []),
            options: .init(maximumTokensPerBatch: 64, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.flatMap(\.sourceIDs) == Array(sourceWords.indices))
        for cue in track.cues {
            let first = try #require(cue.sourceIDs.first)
            let last = try #require(cue.sourceIDs.last)
            let start = try #require(sourceWords[first].start)
            let end = try #require(sourceWords[last].end)
            #expect(cue.start == start)
            #expect(cue.end == end)
        }
    }

    @Test func subtitleProcessorBoundsConcurrentBatchesAndRestoresSourceOrder() async throws {
        let client = ConcurrencyProbeLLMClient()
        let words = ["one", "two", "three", "four", "five", "six"].enumerated().map { index, text in
            TranscriptionWord(
                text: text,
                start: Double(index),
                end: Double(index) + 0.5,
                speaker: "Speaker \(index)"
            )
        }
        let transcript = TranscriptionResult(
            text: words.map(\.text).joined(separator: " "),
            language: "en",
            words: words,
            segments: words.enumerated().map { _, word in
                TranscriptionSegment(
                    text: word.text,
                    start: word.start ?? 0,
                    end: word.end ?? 0,
                    speaker: word.speaker
                )
            }
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(
                maximumTokensPerBatch: 8,
                maximumSegmentsPerBatch: 1,
                maximumConcurrentBatches: 2,
                maximumAttempts: 1
            ),
            progress: { _, _, _, _ in }
        )

        #expect(await client.maximumActiveRequests == 2)
        #expect(track.cues.map(\.text) == words.map { $0.text })
    }

    @Test func providerProfilesAreEndpointScopedAndRequireTransportSecurity() throws {
        let openAI = LLMProviderProfile.defaultOpenAI
        #expect(try openAI.completionEndpoint().absoluteString == "https://api.openai.com/v1/chat/completions")

        var compatible = LLMProviderProfile(
            provider: .openAICompatible,
            baseURL: "https://llm.example.test/openai/v1/",
            model: "multilingual-model"
        )
        #expect(try compatible.completionEndpoint().absoluteString == "https://llm.example.test/openai/v1/chat/completions")
        #expect(compatible.credentialAccount != openAI.credentialAccount)

        compatible.baseURL = "http://127.0.0.1:11434/v1"
        #expect(try compatible.completionEndpoint().absoluteString == "http://127.0.0.1:11434/v1/chat/completions")

        compatible.baseURL = "http://llm.example.test/v1"
        #expect(throws: LLMConfigurationError.self) {
            try compatible.completionEndpoint()
        }
    }

    @Test func subtitleProcessorUsesStableTimingAnchorsAndRetriesInvalidStructure() async throws {
        let client = StubLLMClient(responses: [
            #"{"subtitles":[]}"#,
            #"{"cues":[{"token_ids":[0,1],"text":"Hello, world."}]}"#,
            #"{"cues":[{"token_ids":[0],"text":"Again."}]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "hello world again",
            language: "en",
            words: [
                .init(text: "hello", start: 0.1, end: 0.4, speaker: "Speaker 1"),
                .init(text: "world", start: 0.5, end: 0.9, speaker: "Speaker 1"),
                .init(text: "again", start: 1.1, end: 1.5, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        try assertContinuousCueCoverage(track, sourceWords: transcript.words)
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        let requestCount = await client.requestCount
        #expect(requestCount == 3)
        let requests = await client.requests
        let firstRequest = try #require(requests.first)
        #expect(firstRequest.system.contains("Correct ASR, restore punctuation, and split the result into subtitle lines."))
        #expect(firstRequest.system.contains("bound particle"))
        #expect(firstRequest.system.contains("Never cross a speaker boundary."))
        #expect(!firstRequest.system.contains("Highest priority"))
        #expect(!firstRequest.system.contains("Phonetic plausibility first"))
        #expect(!firstRequest.system.contains("batch_summary"))
        #expect(firstRequest.user.contains("language: en"))
        #expect(firstRequest.user.contains("speaker: Speaker 1"))
        #expect(firstRequest.user.contains(#""minimumCharactersPerCue":24"#))
        #expect(firstRequest.user.contains(#""preferredCharactersPerCue":42"#))
        #expect(firstRequest.user.contains(#""maximumCharactersPerCue":56"#))
    }

    @Test func subtitleProcessorShrinksMalformedTokenBatchWhileKeepingWordAnchors() async throws {
        let client = StubLLMClient(responses: [
            #"{"cues":[{"token_ids":[0,2],"text":"Malformed."}]}"#,
            #"{"cues":[{"token_ids":[0,1],"text":"Again now."}]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "hello world again now",
            language: "en",
            words: [
                .init(text: "hello", start: 0, end: 0.4, speaker: "Speaker 1"),
                .init(text: "world", start: 0.4, end: 0.8, speaker: "Speaker 1"),
                .init(text: "again", start: 1, end: 1.4, speaker: "Speaker 2"),
                .init(text: "now", start: 1.4, end: 1.8, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(
                maximumTokensPerBatch: 4,
                maximumAttempts: 1
            ),
            progress: { _, _, _, _ in }
        )

        #expect(track.usesWordTimestamps)
        try assertContinuousCueCoverage(track, sourceWords: transcript.words)
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(await client.requestCount == 2)
    }

    @Test func subtitleProcessorRemapsBrokenTokenIDsWithoutFailing() async throws {
        let client = InputMappedLLMClient(responsesByInput: [
            "hello world": #"{"cues":[{"token_ids":[0,3],"text":"Hello, world."}]}"#,
            "again now": #"{"cues":[{"token_ids":[9],"text":"Again now."}]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "hello world again now",
            language: "en",
            words: [
                .init(text: "hello", start: 0, end: 0.4, speaker: "Speaker 1"),
                .init(text: "world", start: 0.4, end: 0.8, speaker: "Speaker 1"),
                .init(text: "again", start: 1, end: 1.4, speaker: "Speaker 2"),
                .init(text: "now", start: 1.4, end: 1.8, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumTokensPerBatch: 4, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.usesWordTimestamps)
        try assertContinuousCueCoverage(track, sourceWords: transcript.words)
        #expect(track.cues.map(\.text) == ["Hello, world.", "Again now."])
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(await client.requestCount == 2)
    }

    @Test func subtitleProcessorMergesOverSegmentedProviderOutput() async throws {
        let client = StubLLMClient(responses: [
            #"{"subtitles":["He","llo,","wor","ld.","A","gain","no","w."]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "hello world again now",
            language: "en",
            words: [
                .init(text: "hello", start: 0, end: 0.4, speaker: "Speaker 1"),
                .init(text: "world", start: 0.4, end: 0.8, speaker: "Speaker 1"),
                .init(text: "again", start: 1, end: 1.4, speaker: "Speaker 2"),
                .init(text: "now", start: 1.4, end: 1.8, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumTokensPerBatch: 4, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.flatMap(\.sourceIDs) == [0, 1, 2, 3])
        #expect(!track.cues.isEmpty)
        #expect(Set(track.cues.compactMap(\.speaker)) == ["Speaker 1", "Speaker 2"])
        #expect(await client.requestCount >= 1)
    }

    @Test func subtitleProcessorAcceptsWorkerStyleSubtitleArrayAndRemapsWords() async throws {
        let client = InputMappedLLMClient(responsesByInput: [
            "hello world": #"{"subtitles":["Hello, world."]}"#,
            "again now": #"{"subtitles":["Again now."]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "hello world again now",
            language: "en",
            words: [
                .init(text: "hello", start: 1, end: 1.4, speaker: "Speaker 1"),
                .init(text: "world", start: 1.4, end: 1.8, speaker: "Speaker 1"),
                .init(text: "again", start: 2, end: 2.4, speaker: "Speaker 2"),
                .init(text: "now", start: 2.4, end: 2.8, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumTokensPerBatch: 4, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.usesWordTimestamps)
        #expect(track.cues.map(\.text) == ["Hello, world.", "Again now."])
        try assertContinuousCueCoverage(track, sourceWords: transcript.words)
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func subtitleProcessorSplitsOverlongWorkerTextBeforeWordRemap() async throws {
        let client = StubLLMClient(responses: [
            #"{"subtitles":["这是一个很长的字幕句子，需要在自然停顿处拆分。"]}"#,
        ])
        let sourceWords = Array("这是一个很长的字幕句子需要在自然停顿处拆分").map {
            TranscriptionWord(text: String($0), start: 0, end: 0.1, speaker: "Speaker 1")
        }
        let transcript = TranscriptionResult(
            text: sourceWords.map(\.text).joined(),
            language: "zh",
            words: sourceWords,
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumTokensPerBatch: 64, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.count > 1)
        #expect(track.cues.allSatisfy { $0.text.filter { !$0.isWhitespace }.count <= 18 })
        #expect(track.cues.flatMap(\.sourceIDs) == Array(sourceWords.indices))
        #expect(track.cues.allSatisfy { $0.speaker == "Speaker 1" })
    }

    @Test func subtitleReadabilityLimitsMatchPostprocessDefaults() {
        #expect(
            SubtitleReadabilityPolicy.limits(for: "请修正这段字幕。")
                == .init(minimum: 8, preferred: 14, maximum: 18)
        )
        #expect(
            SubtitleReadabilityPolicy.limits(for: "Correct and punctuate this subtitle.")
                == .init(minimum: 24, preferred: 42, maximum: 56)
        )
        #expect(
            SubtitleReadabilityPolicy.limits(
                for: "Correct this subtitle.",
                overridingMaximum: 20
            ) == .init(minimum: 20, preferred: 20, maximum: 20)
        )
    }

    @Test func underpunctuatedRunDetectorFlagsCaptionWithoutClauseMarks() {
        #expect(
            SubtitleReadabilityPolicy.containsUnderpunctuatedRun(
                "上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转真的收获很大。",
                denseScript: true,
                maximumRun: 18
            )
        )
        #expect(
            !SubtitleReadabilityPolicy.containsUnderpunctuatedRun(
                "上一次我看那个医师，就叫我们转这个耳朵，拉这个耳朵就转转转，真的收获很大。",
                denseScript: true,
                maximumRun: 18
            )
        )
    }

    @Test func strandedBoundParticleDetectorFlagsPunctuationBeforeClitic() {
        #expect(SubtitleReadabilityPolicy.containsStrandedBoundParticle("我的颈椎痛。的我时常"))
        #expect(SubtitleReadabilityPolicy.containsStrandedBoundParticle("眼前一亮，的那种感觉"))
        #expect(SubtitleReadabilityPolicy.containsStrandedBoundParticle("痛。 的我"))
        #expect(!SubtitleReadabilityPolicy.containsStrandedBoundParticle("还有我的颈椎也是痛的。我时常都去治疗。"))
        #expect(!SubtitleReadabilityPolicy.containsStrandedBoundParticle("给我孩子啊给我先生"))
        #expect(!SubtitleReadabilityPolicy.containsStrandedBoundParticle("Hello. The world."))
    }

    @Test func cascadePromptStaysSimpleAndPassesNeighboringBatches() {
        let limits = SubtitleReadabilityPolicy.Limits(minimum: 8, preferred: 14, maximum: 18)
        let correction = SubtitleCascadePrompt.correctionSystem(
            languageCode: "zh",
            isCJK: true
        )
        #expect(correction.contains("Correct this spoken ASR transcript"))
        #expect(correction.contains("bound particle"))
        #expect(!correction.contains("Every subtitle line needs punctuation"))
        #expect(!correction.contains("Highest priority"))
        #expect(!correction.contains("Core principle"))
        #expect(!correction.contains("batch_summary"))
        #expect(!correction.contains("Phonetic plausibility"))

        let segmentation = SubtitleCascadePrompt.segmentationSystem(
            languageCode: "zh",
            isCJK: true,
            limits: limits
        )
        #expect(segmentation.contains("Do not correct, normalize, translate, add, remove, or reorder"))

        let prior = String(repeating: "前文", count: 80)
        let later = "后文批次"
        let (before, after) = SubtitleCascadePrompt.neighboringContext(
            batchTexts: [prior, "当前批次", later],
            index: 1
        )
        #expect(before == prior)
        #expect(after == later)

        let user = SubtitleCascadePrompt.correctionUser(
            batchText: "当前批次",
            contextBefore: before,
            contextAfter: after,
            languageCode: "zh",
            speaker: "Speaker 1",
            limits: limits,
            userInstruction: nil
        )
        #expect(user.contains("<context_before>\n\(prior)\n</context_before>"))
        #expect(user.contains("<asr_input>\n当前批次\n</asr_input>"))
        #expect(user.contains("<context_after>\n\(later)\n</context_after>"))
        #expect(user.contains("language: zh"))
        #expect(user.contains("speaker: Speaker 1"))
        #expect(!user.contains("highest priority"))
    }

    @Test func cascadeNeighboringContextKeepsTheNearestWindow() {
        let older = String(repeating: "A", count: 900)
        let nearer = String(repeating: "B", count: 900)
        let current = "C"
        let upcoming = String(repeating: "D", count: 900)
        let farther = String(repeating: "E", count: 900)
        let (before, after) = SubtitleCascadePrompt.neighboringContext(
            batchTexts: [older, nearer, current, upcoming, farther],
            index: 2
        )
        let beforeText = before ?? ""
        let afterText = after ?? ""
        #expect(beforeText.count == SubtitleCascadePrompt.contextCharacters)
        #expect(beforeText.hasSuffix(nearer))
        #expect(!beforeText.hasPrefix(older))
        #expect(afterText.count == SubtitleCascadePrompt.contextCharacters)
        #expect(afterText.hasPrefix(upcoming))
        #expect(!afterText.hasSuffix(farther))
    }

    @Test func subtitleProcessorIncludesNeighboringBatchesAsContext() async throws {
        let client = StubLLMClient(responses: [
            #"{"text":"alpha beta."}"#,
            #"{"lines":["alpha beta."]}"#,
            #"{"text":"gamma delta."}"#,
            #"{"lines":["gamma delta."]}"#,
        ])
        let transcript = TranscriptionResult(
            text: "alpha beta gamma delta",
            language: "en",
            words: [
                .init(text: "alpha", start: 0, end: 0.4, speaker: "Speaker 1"),
                .init(text: "beta", start: 0.4, end: 0.8, speaker: "Speaker 1"),
                .init(text: "gamma", start: 1.0, end: 1.4, speaker: "Speaker 2"),
                .init(text: "delta", start: 1.4, end: 1.8, speaker: "Speaker 2"),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumConcurrentBatches: 1, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        try assertContinuousCueCoverage(track, sourceWords: transcript.words)
        let requests = await client.requests
        #expect(requests.count == 4)
        #expect(requests[0].user.contains("<asr_input>\nalpha beta\n</asr_input>"))
        #expect(requests[0].user.contains("<context_after>\ngamma delta\n</context_after>"))
        #expect(requests[2].user.contains("<context_before>\nalpha beta\n</context_before>"))
        #expect(requests[2].user.contains("<asr_input>\ngamma delta\n</asr_input>"))
        #expect(requests[2].user.contains("speaker: Speaker 2"))
    }

    @Test func subtitleProcessorAllowsContinuationLinesWithoutPunctuation() async throws {
        let source = "这是一个没有标点的行然后结束。"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: "Speaker 1"
            )
        }
        let client = StubLLMClient(responses: [
            #"{"text":"这是一个没有标点的行然后结束。"}"#,
            #"{"lines":["这是一个没有标点的行","然后结束。"]}"#,
        ])

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: source,
                language: "zh",
                words: sourceWords,
                segments: []
            ),
            options: .init(maximumConcurrentBatches: 1, maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(await client.requestCount == 2)
        #expect(output.track.cues.map(\.text) == [
            "这是一个没有标点的行",
            "然后结束。",
        ])
        try assertContinuousCueCoverage(output.track, sourceWords: sourceWords)
    }

    @Test func subtitleProcessorRetriesWhenPunctuationStrandsABoundParticle() async throws {
        let source = "我的颈椎痛的我时常都去治疗那些手法呢"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: "Speaker 1"
            )
        }
        let client = StubLLMClient(responses: [
            #"{"text":"我的颈椎痛。的我时常都去治疗那些手法呢，"}"#,
            #"{"text":"我的颈椎痛的。我时常都去治疗那些手法呢，"}"#,
            #"{"lines":["我的颈椎痛的。","我时常都去治疗那些手法呢，"]}"#,
        ])

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: source,
                language: "zh",
                words: sourceWords,
                segments: []
            ),
            options: .init(maximumTokensPerBatch: 64, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(await client.requestCount == 3)
        let requests = await client.requests
        #expect(requests[0].system.contains("bound particle"))
        #expect(!requests[0].system.contains("痛的。我"))
        #expect(requests[0].user.contains("language: zh"))
        #expect(requests[0].user.contains("speaker: Speaker 1"))
        #expect(requests[1].user.contains("stranded_bound_particle"))
        #expect(output.track.cues.map(\.text) == ["我的颈椎痛的。", "我时常都去治疗那些手法呢，"])
        #expect(!SubtitleReadabilityPolicy.containsStrandedBoundParticle(output.track.cues.map(\.text).joined()))
        #expect(output.warnings.isEmpty)
        try assertContinuousCueCoverage(output.track, sourceWords: sourceWords)
    }

    @Test func subtitleProcessorRetriesWhenCJKCorrectionLacksPunctuation() async throws {
        let source = "上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转真的收获很大"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: "Speaker 3"
            )
        }
        let client = StubLLMClient(responses: [
            #"{"text":"上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转真的收获很大"}"#,
            #"{"text":"上一次我看那个医师，就叫我们转这个耳朵，拉这个耳朵就转转转，真的收获很大。"}"#,
            #"{"lines":["上一次我看那个医师，","就叫我们转这个耳朵，","拉这个耳朵就转转转，","真的收获很大。"]}"#,
        ])

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: source,
                language: "zh",
                words: sourceWords,
                segments: []
            ),
            options: .init(maximumTokensPerBatch: 64, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(await client.requestCount == 3)
        let requests = await client.requests
        #expect(requests[1].user.contains("missing_punctuation"))
        #expect(output.track.cues.map(\.text) == [
            "上一次我看那个医师，",
            "就叫我们转这个耳朵，",
            "拉这个耳朵就转转转，",
            "真的收获很大。",
        ])
        #expect(output.warnings.isEmpty)
        try assertContinuousCueCoverage(output.track, sourceWords: sourceWords)
    }

    @Test func subtitleProcessorRetriesWhenCJKUsesLatinPeriod() async throws {
        let source = "眼前一亮的那种感觉好像很亮"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: "Speaker 1"
            )
        }
        let client = StubLLMClient(responses: [
            #"{"text":"眼前一亮的.那种感觉好像很亮"}"#,
            #"{"text":"眼前一亮的那种感觉，好像很亮。"}"#,
            #"{"lines":["眼前一亮的那种感觉，好像很亮。"]}"#,
        ])

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: source,
                language: "zh",
                words: sourceWords,
                segments: []
            ),
            options: .init(maximumTokensPerBatch: 64, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(await client.requestCount == 3)
        let requests = await client.requests
        #expect(requests[1].user.contains("wrong_script_punctuation"))
        #expect(output.track.cues.map(\.text) == ["眼前一亮的那种感觉，好像很亮。"])
        #expect(output.warnings.isEmpty)
    }

    @Test func subtitleProcessorRetriesWhenCJKHasOnlyATerminalPeriod() async throws {
        let source = "上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转真的收获很大"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: "Speaker 3"
            )
        }
        let client = StubLLMClient(responses: [
            #"{"text":"上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转真的收获很大。"}"#,
            #"{"text":"上一次我看那个医师，就叫我们转这个耳朵，拉这个耳朵就转转转，真的收获很大。"}"#,
            #"{"lines":["上一次我看那个医师，","就叫我们转这个耳朵，","拉这个耳朵就转转转，","真的收获很大。"]}"#,
        ])

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: source,
                language: "zh",
                words: sourceWords,
                segments: []
            ),
            options: .init(maximumTokensPerBatch: 64, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(await client.requestCount == 3)
        let requests = await client.requests
        #expect(requests[1].user.contains("missing_punctuation"))
        #expect(output.rebuiltSegments.map(\.text).joined().contains("医师，"))
        #expect(output.rebuiltSegments.map(\.text).joined().contains("耳朵，"))
        #expect(output.warnings.isEmpty)
        try assertContinuousCueCoverage(output.track, sourceWords: sourceWords)
    }

    @Test func subtitlePipelineKeepsLunaPunctuationThroughRemapAndRebuild() async throws {
        let speakers: [(speaker: String, asr: String, subtitles: [String])] = [
            (
                "Speaker 1",
                "我的颈椎痛的我时常都去治疗那些手法呢按了之后我觉得我的颈像是松了还有一个感觉就是我感觉到那个眼前一亮的那种感觉好像很亮啊我会看得很远很亮的那种感觉我觉得",
                [
                    "我的颈椎痛得我时常都去治疗。",
                    "那些手法按了之后，",
                    "我觉得我的颈像是松了。",
                    "还有一个感觉，就是我感觉到眼前一亮，",
                    "那种感觉好像很亮啊。",
                    "我会看得很远很亮的那种感觉，我觉得。",
                ]
            ),
            (
                "Speaker 2",
                "确实受益良多真的学了很多东西完全能学到自己在家里边用到我自己身上给我孩子啊给我先生啊给老人全都能用得到所以今天来的很值得值得值得非常值得",
                [
                    "确实是受益良多，",
                    "真的学了很多东西。",
                    "完全都能学到，",
                    "自己在家里边用到我自己身上，",
                    "给我孩子啊，给我先生啊，",
                    "给老人全都能用得到，",
                    "所以今天来得很值得。",
                    "值得，值得，非常值得。",
                ]
            ),
            (
                "Speaker 3",
                "上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转转真的收获很大",
                [
                    "上一次我看那个医师，",
                    "就叫我们转这个耳朵，",
                    "拉这个耳朵就转转转转，真的收获很大。",
                ]
            ),
        ]
        var words: [TranscriptionWord] = []
        var cursor = 0.0
        var responses: [String: String] = [:]
        for item in speakers {
            responses[item.asr] = #"{"subtitles":\#(String(data: try JSONEncoder().encode(item.subtitles), encoding: .utf8)!)}"#
            for character in item.asr {
                words.append(
                    TranscriptionWord(
                        text: String(character),
                        start: cursor,
                        end: cursor + 0.16,
                        speaker: item.speaker
                    )
                )
                cursor += 0.2
            }
            cursor += 2
        }
        let client = InputMappedLLMClient(responsesByInput: responses)
        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: speakers.map(\.asr).joined(),
                language: "zh",
                words: words,
                segments: speakers.map { item in
                    let slice = words.filter { $0.speaker == item.speaker }
                    return TranscriptionSegment(
                        text: item.asr,
                        start: slice.first?.start ?? 0,
                        end: slice.last?.end ?? 0,
                        speaker: item.speaker
                    )
                }
            ),
            options: .init(maximumTokensPerBatch: 180, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        let rebuilt = output.rebuiltSegments.map(\.text)
        #expect(rebuilt.count == 3)
        #expect(rebuilt[0].contains("治疗。"))
        #expect(rebuilt[1].contains("受益良多，"))
        #expect(rebuilt[1].contains("非常值得。"))
        #expect(!rebuilt[1].contains("完全能学到自己在家里边"))
        #expect(rebuilt[2].contains("医师，"))
        #expect(rebuilt[2].contains("收获很大。"))
        #expect(!output.warnings.contains { $0.contains("source-timed fallback") })
        try assertContinuousCueCoverage(output.track, sourceWords: words)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["VOXELLA_LIVE_SUBTITLE_EXPERIMENT"] == "1")
    )
    func subtitlePipelineLiveLunaFlow() async throws {
        var profile = LLMProviderProfile.defaultOpenAI
        profile.model = "gpt-5.6-luna"
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = try #require(
            (envKey?.isEmpty == false ? envKey : nil)
                ?? (try KeychainStore.loadProtected(account: profile.credentialAccount))
        )
        let configuration = LLMRuntimeConfiguration(
            profile: profile,
            modelIdentifier: "openai/gpt-5.6-luna",
            modelName: "gpt-5.6-luna",
            endpoint: try profile.completionEndpoint(),
            apiKey: apiKey
        )
        let client = OpenAICompatibleClient(
            configuration: configuration,
            policy: .default(for: .subtitleProcessing)
        )
        let speakers: [(speaker: String, asr: String)] = [
            (
                "Speaker 1",
                "我的颈椎痛的我时常都去治疗那些手法呢按了之后我觉得我的颈像是松了还有一个感觉就是我感觉到那个眼前一亮的那种感觉好像很亮啊我会看得很远很亮的那种感觉我觉得"
            ),
            (
                "Speaker 2",
                "确实受益良多真的学了很多东西完全能学到自己在家里边用到我自己身上给我孩子啊给我先生啊给老人全都能用得到所以今天来的很值得值得值得非常值得"
            ),
            (
                "Speaker 3",
                "上一次我看那个医师就叫我们转这个耳朵拉这个耳朵就转转转转真的收获很大"
            ),
        ]
        var words: [TranscriptionWord] = []
        var cursor = 0.0
        for item in speakers {
            for character in item.asr {
                words.append(
                    TranscriptionWord(
                        text: String(character),
                        start: cursor,
                        end: cursor + 0.16,
                        speaker: item.speaker
                    )
                )
                cursor += 0.2
            }
            cursor += 2
        }

        let output = try await SubtitlePostprocessPipeline(client: client).process(
            transcript: .init(
                text: speakers.map(\.asr).joined(),
                language: "zh",
                words: words,
                segments: speakers.map { item in
                    let slice = words.filter { $0.speaker == item.speaker }
                    return TranscriptionSegment(
                        text: item.asr,
                        start: slice.first?.start ?? 0,
                        end: slice.last?.end ?? 0,
                        speaker: item.speaker
                    )
                }
            ),
            options: .init(maximumTokensPerBatch: 180, maximumConcurrentBatches: 1, maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        let rebuilt = Dictionary(
            uniqueKeysWithValues: output.rebuiltSegments.compactMap { segment in
                segment.speaker.map { ($0, segment.text) }
            }
        )
        let speaker2 = try #require(rebuilt["Speaker 2"])
        let speaker3 = try #require(rebuilt["Speaker 3"])
        #expect(speaker2.contains("，") || speaker2.contains("。"))
        #expect(speaker2.contains("。"))
        #expect(!speaker2.contains("完全能学到自己在家里边用到我自己身上给我孩子"))
        #expect(speaker3.contains("，"))
        #expect(speaker3.hasSuffix("。") || speaker3.contains("。"))
        #expect(!output.warnings.contains { $0.contains("kept source wording") })
        try assertContinuousCueCoverage(output.track, sourceWords: words)
    }

    @Test func structuredOutputDecoderUsesFinalJSONAfterReasoning() async throws {
        let source = "请测试声音"
        let sourceWords = Array(source).enumerated().map { index, character in
            TranscriptionWord(
                text: String(character),
                start: Double(index) * 0.2,
                end: Double(index) * 0.2 + 0.16,
                speaker: nil
            )
        }
        let client = StubLLMClient(responses: [
            """
            <think>
            I should return {"text": "a string"}, then verify every token.
            </think>
            ```json
            {"text":"请测试声音。"}
            ```
            """,
            #"{"lines":["请测试声音。"]}"#,
        ])
        let transcript = TranscriptionResult(
            text: source,
            language: "zh",
            words: sourceWords,
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.map(\.text) == ["请测试声音。"])
        #expect(await client.requestCount == 2)
        try assertContinuousCueCoverage(track, sourceWords: sourceWords)
    }

    @Test func invalidSubtitleJSONFailsTheFlow() async throws {
        let client = StubLLMClient(responses: ["<think>{not final}</think> not-json"])
        let executor = MediaFlowExecutor(llmClientFactory: { client })
        let transcript = TranscriptionResult(
            text: "请测试一下声音。",
            language: "zh",
            words: [.init(text: "请测试一下声音。", start: 0, end: 2, speaker: nil)],
            segments: [.init(text: "请测试一下声音。", start: 0, end: 2, speaker: nil)]
        )
        let request = MediaFlowRequest(
            input: .transcript(transcript: transcript, subtitles: nil, translation: nil),
            steps: [
                .prepareSubtitles(SubtitleProcessingPayload(maximumAttempts: 1)),
            ]
        )
        var resultingTrack: SubtitleTrack?
        var terminalProgress: MediaJobProgressEvent?

        for await event in executor.events(for: request) {
            switch event {
            case .artifact(.subtitles(let track, _)):
                resultingTrack = track
            case .progress(let progress) where progress.status == .failed:
                terminalProgress = progress
            default:
                break
            }
        }

        #expect(resultingTrack == nil)
        #expect(terminalProgress?.status == .failed)
        #expect(terminalProgress?.message.contains("invalid structured output") == true)
    }

    @Test func translationPreservesCueIdentityTimingAndDurationBudgets() async throws {
        let client = StubLLMClient(responses: [
            #"{"translations":[{"id":7,"text":"This translation is intentionally much too long for the cue."},{"id":8,"text":"Next."}]}"#,
            #"{"translations":[{"id":7,"text":"A concise translation."},{"id":8,"text":"Next."}]}"#,
        ])
        let source = SubtitleTrack(
            sourceLanguage: "fr",
            language: "fr",
            cues: [
                SubtitleCue(
                    id: 7,
                    sourceIDs: [10, 11],
                    text: "Une phrase.",
                    start: 1,
                    end: 3,
                    speaker: "Speaker 1"
                ),
                SubtitleCue(
                    id: 8,
                    sourceIDs: [12],
                    text: "Ensuite.",
                    start: 3.5,
                    end: 4.5,
                    speaker: "Speaker 2"
                ),
            ]
        )

        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: source,
            options: TranslationFlowPayload(targetLanguage: "en-US"),
            progress: { _, _, _, _ in }
        )

        #expect(translated.language == "en-US")
        #expect(translated.cues.map(\.id) == [7, 8])
        #expect(translated.cues.map(\.start) == [1, 3.5])
        #expect(translated.cues.map(\.end) == [3, 4.5])
        #expect(translated.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(translated.cues.map(\.characterBudget) == [29, 14])
        #expect(translated.cues.allSatisfy { !$0.overBudget })
        let requestCount = await client.requestCount
        #expect(requestCount == 2)
    }

    @Test func translationReordersValidCueIDsWithoutChangingSourceTimeline() async throws {
        let client = StubLLMClient(responses: [
            #"{"translations":[{"id":8,"text":"Next."},{"id":7,"text":"First."}]}"#,
        ])
        let source = SubtitleTrack(
            sourceLanguage: "fr",
            language: "fr",
            cues: [
                SubtitleCue(id: 7, sourceIDs: [10], text: "Premier.", start: 1, end: 2, speaker: "A"),
                SubtitleCue(id: 8, sourceIDs: [11], text: "Ensuite.", start: 2, end: 3, speaker: "B"),
            ]
        )

        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: source,
            options: TranslationFlowPayload(targetLanguage: "en-US", maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(translated.cues.map(\.id) == [7, 8])
        #expect(translated.cues.map(\.text) == ["First.", "Next."])
        #expect(translated.cues.map(\.speaker) == ["A", "B"])
        #expect(translated.cues.map(\.start) == [1, 2])
        #expect(await client.requestCount == 1)
    }

    @Test func translationRepairsOnlyMissingCuesAndKeepsFullContext() async throws {
        let client = StubLLMClient(responses: [
            #"{"translations":[{"id":7,"text":"First."},{"id":8,"text":""}]}"#,
            #"{"translations":[{"id":8,"text":"Next."}]}"#,
        ])
        let source = SubtitleTrack(
            sourceLanguage: "fr",
            language: "fr",
            cues: [
                SubtitleCue(id: 7, sourceIDs: [10], text: "Premier.", start: 1, end: 2, speaker: "A"),
                SubtitleCue(id: 8, sourceIDs: [11], text: "Ensuite.", start: 2, end: 3, speaker: "B"),
            ]
        )

        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: source,
            options: TranslationFlowPayload(targetLanguage: "en-US", maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(translated.cues.map(\.text) == ["First.", "Next."])
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[1].user.contains(#""context_cues""#))
        #expect(requests[1].user.contains(#""id":7"#))
        #expect(requests[1].user.contains(#""id":8"#))
        let recoveryCueMarker = #""cues":[{"character_budget":14,"id":8"#
        #expect(requests[1].user.contains(recoveryCueMarker))
    }

    @Test func translationShrinksACompletelyInvalidBatchUntilRecoverable() async throws {
        let client = StubLLMClient(responses: [
            #"{"translations":[]}"#,
            #"{"translations":[{"id":7,"text":"First."}]}"#,
            #"{"translations":[{"id":8,"text":"Next."}]}"#,
        ])
        let source = SubtitleTrack(
            sourceLanguage: "fr",
            language: "fr",
            cues: [
                SubtitleCue(id: 7, sourceIDs: [10], text: "Premier.", start: 1, end: 2, speaker: "A"),
                SubtitleCue(id: 8, sourceIDs: [11], text: "Ensuite.", start: 2, end: 3, speaker: "B"),
            ]
        )

        let translated = try await TranslationLLMProcessor(client: client).lineAlignedTranslate(
            track: source,
            options: TranslationFlowPayload(targetLanguage: "en-US", maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(translated.cues.map(\.text) == ["First.", "Next."])
        #expect(await client.requestCount == 3)
    }

    @Test func progressEventsRoundTripWithSSEStyleFields() throws {
        let event = MediaJobProgressEvent(
            jobID: UUID(),
            stage: .translation,
            status: .processing,
            step: "translation",
            progress: 0.72,
            stageProgress: 0.4,
            current: 4,
            total: 10,
            message: "Translating subtitle batch 5 of 10"
        )
        let decoded = try JSONDecoder().decode(
            MediaJobProgressEvent.self,
            from: JSONEncoder().encode(event)
        )
        #expect(decoded == event)
    }

    @Test func dubChunkingIsLanguageNeutralAndBounded() {
        let mixed = "Hello, 世界。This is a longer sentence that needs another chunk."
        let chunks = DubTextChunker.chunks(mixed, maximumCharacters: 18)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.count <= 18 })
        #expect(chunks.joined().replacingOccurrences(of: " ", with: "")
            == mixed.replacingOccurrences(of: " ", with: ""))
    }

    @Test func dubVoiceAssignmentsPreferSegmentThenSpeakerThenSession() {
        let session = DubVoiceReference(audioURL: URL(fileURLWithPath: "/tmp/session.wav"), transcript: "session")
        let speaker = DubVoiceReference(audioURL: URL(fileURLWithPath: "/tmp/speaker.wav"), transcript: "speaker")
        let segment = DubVoiceReference(audioURL: URL(fileURLWithPath: "/tmp/segment.wav"), transcript: "segment")
        let payload = DubFlowPayload(
            segments: [],
            language: "en",
            model: .medium,
            reference: session,
            speakerReferences: ["SPEAKER_01": speaker],
            segmentReferences: [7: segment]
        )

        #expect(LocalDubFlowRenderer.reference(
            for: DubSegmentPayload(index: 7, text: "A", speaker: "SPEAKER_01"),
            payload: payload
        ) == segment)
        #expect(LocalDubFlowRenderer.reference(
            for: DubSegmentPayload(index: 8, text: "B", speaker: "SPEAKER_01"),
            payload: payload
        ) == speaker)
        #expect(LocalDubFlowRenderer.reference(
            for: DubSegmentPayload(index: 9, text: "C", speaker: "SPEAKER_02"),
            payload: payload
        ) == session)
    }

    @Test func dubFlowsAlwaysAlignRenderedSpeechBeforeSubtitleSegmentation() {
        let payload = DubFlowPayload(
            segments: [DubSegmentPayload(index: 0, text: "A timed dub.")],
            language: "en",
            model: .medium,
            reference: nil,
            speakerReferences: [:]
        )

        #expect(
            WorkbenchMediaFlowPlanner.dubSteps(payload: payload, hasAPIKey: false)
                .map { $0.stage.rawValue }
                == ["dubSynthesis", "alignment"]
        )
        #expect(
            WorkbenchMediaFlowPlanner.dubSteps(payload: payload, hasAPIKey: true)
                .map { $0.stage.rawValue }
                == ["dubSynthesis", "alignment", "subtitlePreparation"]
        )
    }

    @Test func knownTextAlignmentPreservesProvidedSpeakerBoundaries() {
        let words = [
            TranscriptionWord(text: "one", start: 0.1, end: 0.4),
            TranscriptionWord(text: "two", start: 0.8, end: 1.1),
            TranscriptionWord(text: "three", start: 1.6, end: 1.9),
        ]
        let spans = [
            KnownTextAlignmentSpan(text: "one two", start: 0, end: 1.2, speaker: "Host"),
            KnownTextAlignmentSpan(text: "three", start: 1.4, end: 2, speaker: "Guest"),
        ]

        let assigned = KnownTextSpeakerMapper.assign(words: words, spans: spans)

        #expect(assigned.map(\.speaker) == ["Host", "Host", "Guest"])
        #expect(assigned.map(\.start) == words.map(\.start))
        #expect(assigned.map(\.end) == words.map(\.end))
    }

    @Test func workbenchTrackSelectionFallsBackSafely() {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/media.wav")
        job.result = TranscriptionResult(
            text: "Source",
            language: "en",
            words: [],
            segments: [.init(text: "Source", start: 0, end: 1, speaker: nil)]
        )
        job.selectedTrack = .translation
        #expect(job.currentTrack == .source)
        #expect(job.displayedText.isEmpty)

        job.editedText = "Source"
        job.translationTrack = SubtitleTrack(
            sourceLanguage: "en",
            language: "es",
            cues: [
                SubtitleCue(
                    id: 0,
                    sourceIDs: [0],
                    text: "Fuente",
                    start: 0,
                    end: 1,
                    speaker: nil
                )
            ]
        )
        #expect(job.currentTrack == .translation)
        #expect(job.displayedText == "Fuente")
    }

    @Test func correctedSubtitleOutputMapsWordTimingBeforeTranscriptAggregation() async throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.wav")
        job.result = TranscriptionResult(
            text: "helo world this raw sentence reply",
            language: "en",
            words: [
                .init(text: "helo", start: 0, end: 4, speaker: "Speaker 1"),
                .init(text: "world", start: 4, end: 10, speaker: "Speaker 1"),
                .init(text: "this raw sentence", start: 10, end: 31, speaker: "Speaker 1"),
                .init(text: "reply", start: 31, end: 34, speaker: "Speaker 1"),
            ],
            segments: [
                .init(text: "helo world", start: 0, end: 10, speaker: "Speaker 1"),
                .init(text: "this raw sentence", start: 10, end: 31, speaker: "Speaker 1"),
                .init(text: "reply", start: 31, end: 34, speaker: "Speaker 1"),
            ]
        )
        let client = StubLLMClient(responses: [
            #"{"cues":[{"token_ids":[0,1],"text":"Hello, world."},{"token_ids":[2],"text":"This raw sentence."},{"token_ids":[3],"text":"Reply."}]}"#,
        ])
        job.subtitleTrack = try await SubtitleLLMProcessor(client: client).process(
            transcript: try #require(job.result),
            options: SubtitleProcessingPayload(maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        let displayed = job.displayedSegments

        try assertContinuousCueCoverage(try #require(job.subtitleTrack), sourceWords: try #require(job.result).words)
        #expect(displayed.count == 1)
        #expect(displayed[0].text == "Hello, world. This raw sentence. Reply.")
        #expect(displayed[0].start == 0)
        #expect(displayed[0].end == 34)
        #expect(displayed[0].speaker == "Speaker 1")
    }

    @Test func transcriptionFlowAutomaticallyPreparesSubtitlesWhenAKeyIsAvailable() {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.mov")

        #expect(
            WorkbenchMediaFlowPlanner.transcriptionSteps(for: job, hasAPIKey: false)
                .map { $0.stage.rawValue }
                == ["transcription"]
        )
        #expect(
            WorkbenchMediaFlowPlanner.transcriptionSteps(for: job, hasAPIKey: true)
                .map { $0.stage.rawValue }
                == ["transcription", "subtitlePreparation"]
        )

        job.useLLMSubtitleProcessing = false
        #expect(
            WorkbenchMediaFlowPlanner.transcriptionSteps(for: job, hasAPIKey: true)
                .map { $0.stage.rawValue }
                == ["transcription"]
        )
    }

    @Test func translationFlowsPrepareUnverifiedTimedSegmentsBeforeTranslation() {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.mov")
        job.useLLMSubtitleProcessing = false
        job.targetLanguageCode = " es-MX "

        #expect(
            WorkbenchMediaFlowPlanner.transcriptionSteps(for: job, hasAPIKey: false)
                .map { $0.stage.rawValue }
                == ["transcription", "subtitlePreparation", "translation"]
        )
        #expect(
            WorkbenchMediaFlowPlanner.translationSteps(for: job)
                .map { $0.stage.rawValue }
                == ["subtitlePreparation", "translation"]
        )

        job.subtitleTrack = SubtitleTrack(sourceLanguage: "en", language: "en", cues: [])
        #expect(
            WorkbenchMediaFlowPlanner.translationSteps(for: job)
                .map { $0.stage.rawValue }
                == ["subtitlePreparation", "translation"]
        )

        job.result = TranscriptionResult(
            text: "hello world",
            language: "en",
            words: [
                .init(text: "hello", start: 0, end: 0.5, speaker: nil),
                .init(text: "world", start: 0.5, end: 1, speaker: nil),
            ],
            segments: [.init(text: "hello world", start: 0, end: 1, speaker: nil)]
        )
        job.subtitleTrack = SubtitleTrack(
            sourceLanguage: "en",
            language: "en",
            cues: [SubtitleCue(id: 0, sourceIDs: [0, 1], text: "Hello world.", start: 0, end: 1, speaker: nil)],
            usesWordTimestamps: true
        )
        #expect(
            WorkbenchMediaFlowPlanner.translationSteps(for: job)
                .map { $0.stage.rawValue }
                == ["translation"]
        )
    }

    @Test func renderedDubSegmentsExposeASubtitleTrackWithTimingAndSpeakers() throws {
        var job = WorkbenchDubJob()
        job.language = "fr"
        job.renderedSegments = [
            DubRenderedSegment(
                index: 4,
                text: "Bonjour.",
                start: 1.25,
                end: 2.1,
                speaker: "Speaker 2",
                sourceSubtitleID: 9
            ),
        ]

        let track = try #require(job.renderedSubtitleTrack)
        #expect(track.language == "fr")
        #expect(track.cues.map(\.id) == [4])
        #expect(track.cues.map(\.sourceIDs) == [[9]])
        #expect(track.cues.map(\.start) == [1.25])
        #expect(track.cues.map(\.end) == [2.1])
        #expect(track.cues.map(\.speaker) == ["Speaker 2"])

        job.subtitleTrack = SubtitleTrack(
            sourceLanguage: "fr",
            language: "fr",
            cues: [
                SubtitleCue(
                    id: 10,
                    sourceIDs: [0, 1],
                    text: "Bonjour à tous.",
                    start: 1.32,
                    end: 1.96,
                    speaker: "Speaker 2"
                ),
            ]
        )
        #expect(job.renderedSubtitleTrack?.cues.map(\.id) == [10])
        #expect(job.renderedSubtitleTrack?.cues.map(\.start) == [1.32])
    }

    @Test func sessionTitleDefaultsToFilenameAndSurvivesPersistence() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/Customer Interview.mov")
        #expect(job.sessionTitle == "Customer Interview")
        let untitledData = try JSONEncoder().encode(job)
        #expect(!String(decoding: untitledData, as: UTF8.self).contains("customTitle"))
        #expect(
            try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: untitledData).sessionTitle
                == "Customer Interview"
        )

        job.customTitle = "Launch story"
        let restored = try JSONDecoder().decode(
            WorkbenchTranscriptionJob.self,
            from: JSONEncoder().encode(job)
        )
        #expect(restored.sessionTitle == "Launch story")

        job.customTitle = "  "
        #expect(job.sessionTitle == "Customer Interview")
    }

    @Test func localCloudSyncStateSurvivesPersistence() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.mov")
        job.cloudSyncState = .pending
        job.pendingCloudSyncError = "Cloud session is not reachable."

        let restored = try JSONDecoder().decode(
            WorkbenchTranscriptionJob.self,
            from: JSONEncoder().encode(job)
        )
        #expect(restored.cloudSyncState == .pending)
        #expect(restored.pendingCloudSyncError == "Cloud session is not reachable.")
    }

    @Test func transcriptionAlignmentDiagnosticsPersistWithoutBreakingLegacyJobs() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.mov")
        job.transcriptionAlignmentDiagnostics = .init(
            trimmedHallucinatedSpanCount: 1,
            rejectedAlignmentChunkCount: 2,
            retriedAlignmentChunkCount: 3,
            estimatedUnitCount: 4,
            longestRejectedUnitDuration: 4.32
        )

        let restored = try JSONDecoder().decode(
            WorkbenchTranscriptionJob.self,
            from: JSONEncoder().encode(job)
        )
        #expect(restored.transcriptionAlignmentDiagnostics == job.transcriptionAlignmentDiagnostics)

        let legacy = try JSONDecoder().decode(
            WorkbenchTranscriptionJob.self,
            from: Data(#"{"sourcePath":"/tmp/legacy.mov"}"#.utf8)
        )
        #expect(legacy.transcriptionAlignmentDiagnostics == nil)
    }

    @Test func completedRetranscriptionReplacesArtifactsOnlyOnSuccessAndMarksCompletedDubsOutdated() {
        let transcriptionID = UUID()
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.mov")
        job.id = transcriptionID
        job.result = .init(text: "old transcript", language: "en", words: [], segments: [])
        job.editedText = "old transcript"
        job.subtitleTrack = .init(
            sourceLanguage: "en",
            language: "en",
            cues: [.init(id: 0, sourceIDs: [0], text: "Old subtitle.", start: 0, end: 1, speaker: nil)]
        )
        job.translationTracks = [.init(
            languageCode: "fr",
            track: .init(
                sourceLanguage: "en",
                language: "fr",
                cues: [.init(id: 0, sourceIDs: [0], text: "Ancien sous-titre.", start: 0, end: 1, speaker: nil)]
            )
        )]
        job.summaryMarkdown = "Old summary"
        job.summaryState = .completed

        let replacement = CompletedTranscriptionArtifacts(
            rawResult: .init(text: "raw replacement", language: "en", words: [], segments: []),
            result: .init(text: "prepared replacement", language: "en", words: [], segments: []),
            subtitleTrack: .init(
                sourceLanguage: "en",
                language: "en",
                cues: [.init(id: 0, sourceIDs: [0], text: "New subtitle.", start: 2, end: 3, speaker: nil)]
            ),
            translationTracks: [.init(
                languageCode: "ja",
                track: .init(
                    sourceLanguage: "en",
                    language: "ja",
                    cues: [.init(id: 0, sourceIDs: [0], text: "新しい字幕。", start: 2, end: 3, speaker: nil)]
                )
            )],
            diarizationDiagnostics: nil,
            alignmentDiagnostics: .init(rejectedAlignmentChunkCount: 1),
            processedSourcePath: "/tmp/rebuilt-clip.m4a"
        )

        #expect(!TranscriptionCommitPolicy.shouldCommit(status: .cancelled, artifacts: replacement))
        #expect(!TranscriptionCommitPolicy.shouldCommit(status: .failed, artifacts: replacement))
        #expect(job.result?.text == "old transcript")
        #expect(job.summaryMarkdown == "Old summary")
        #expect(TranscriptionCommitPolicy.shouldCommit(status: .completed, artifacts: replacement))

        replacement.apply(to: &job)
        #expect(job.result?.text == "prepared replacement")
        #expect(job.editedText == "prepared replacement")
        #expect(job.subtitleTrack?.text == "New subtitle.")
        #expect(job.translationTracks.map(\.languageCode) == ["ja"])
        #expect(job.summaryMarkdown == nil)
        #expect(job.summaryState == nil)
        #expect(job.transcriptionAlignmentDiagnostics == .init(rejectedAlignmentChunkCount: 1))
        #expect(job.sourcePath == "/tmp/rebuilt-clip.m4a")
        #expect(job.clipStartMs == nil)
        #expect(job.clipEndMs == nil)

        var completedDub = WorkbenchDubJob()
        completedDub.sourceTranscriptionID = transcriptionID
        completedDub.state = .completed
        var pendingDub = WorkbenchDubJob()
        pendingDub.sourceTranscriptionID = transcriptionID
        pendingDub.state = .ready
        var unrelatedDub = WorkbenchDubJob()
        unrelatedDub.sourceTranscriptionID = UUID()
        unrelatedDub.state = .completed
        var dubs = [completedDub, pendingDub, unrelatedDub]

        #expect(TranscriptionCommitPolicy.markLinkedCompletedDubsOutdated(
            &dubs,
            sourceTranscriptionID: transcriptionID,
            now: Date(timeIntervalSinceReferenceDate: 100)
        ))
        #expect(dubs[0].progressMessage == "Source subtitles changed — redub to update")
        #expect(dubs[0].modifiedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(dubs[1].progressMessage == "Ready to synthesize")
        #expect(dubs[2].progressMessage == "Ready to synthesize")
    }

    @Test func templateSummarySanitizeMarkdownDropsEmptyHeadings() {
        let raw = """
        ## Overview
        A career-change interview.

        ## Key Points
        - Left civil engineering for Chinese medicine.

        ## Details & Facts

        ## Notable Quotes
        """
        let sanitized = TemplateSummaryLLMProcessor.sanitizeMarkdown(raw)
        #expect(sanitized.contains("## Overview"))
        #expect(sanitized.contains("## Key Points"))
        #expect(!sanitized.contains("## Details & Facts"))
        #expect(!sanitized.contains("## Notable Quotes"))
    }

    @Test func templateSummarySanitizeMarkdownKeepsHeadingsWithContent() {
        let raw = """
        ```markdown
        ## Overview
        A career-change interview.

        ## Details & Facts
        - Graduated from NTU civil engineering.
        - Later trained as a TCM doctor.
        ```
        """
        let sanitized = TemplateSummaryLLMProcessor.sanitizeMarkdown(raw)
        #expect(sanitized.hasPrefix("## Overview"))
        #expect(sanitized.contains("## Details & Facts"))
        #expect(sanitized.contains("Graduated from NTU civil engineering."))
        #expect(!sanitized.contains("```"))
    }

    @Test func generalSummaryTemplateRequiresDetailsWhenSpecificsRemain() {
        let edition = SummaryTemplateDefinition.generalSummary.userEdition
        #expect(edition.contains("Never leave a heading with a blank body"))
        #expect(edition.contains("Details & Facts"))
        #expect(edition.contains("Interviews, lectures, and long sessions must include this"))
        #expect(!edition.contains("Details & Facts** (optional"))
    }

    @Test func templateSummaryPassesTemplateRequirementsToTheLocalModel() async throws {
        let client = StubLLMClient(responses: ["## Overview\nA grounded summary."])
        let template = SummaryTemplateDefinition(
            id: "private-template",
            name: "Decision Notes",
            description: "Capture decisions and ownership.",
            userEdition: "List decisions, owners, and due dates from the transcript.",
            isFallback: false,
            categoryCode: "work",
            scope: "private",
            sourceTemplateID: nil,
            emojiIcon: nil
        )

        _ = try await TemplateSummaryLLMProcessor(client: client).synthesize(
            template: template,
            transcriptLines: "A decision was made to ship Friday.",
            title: "Release planning",
            tagText: "meeting",
            sourceLanguage: "en",
            internalSummary: "Release planning discussion."
        )

        let request = try #require(await client.requests.first)
        #expect(request.user.contains("<template_requirements>"))
        #expect(request.user.contains("List decisions, owners, and due dates"))
        #expect(request.user.contains("</template_requirements>"))
    }
}
