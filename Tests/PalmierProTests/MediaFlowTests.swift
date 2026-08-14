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
            usesAnchorTiming: true,
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
            usesAnchorTiming: true,
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

    @Test func subtitleProcessorFallsBackToSourceTimingWhenRemapIsUnanchored() async throws {
        let client = StubLLMClient(responses: [
            #"{"subtitles":["A concise rewritten opening.","A rewritten closing thought."]}"#,
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

        #expect(output.track.cues.allSatisfy { cue in
            !cue.text.contains("concise rewritten") && !cue.text.contains("closing thought")
        })
        #expect(output.track.cues.flatMap(\.sourceIDs) == Array(words.indices))
        #expect(output.track.cues.first?.start == 0)
        #expect(output.track.cues.last?.end == 5.5)
        #expect(output.warnings.contains { $0.contains("source-timed") })
        #expect(!output.warnings.contains { $0.contains("interpolated source timing") })
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
            #"{"cues":[{"token_ids":[1,0],"text":"Wrong order"}]}"#,
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
        #expect(firstRequest.system.contains("correction, punctuation restoration, and subtitle segmentation"))
        #expect(firstRequest.system.contains("Phonetic plausibility first"))
        #expect(firstRequest.system.contains("Punctuation restoration and segmentation happen together"))
        #expect(firstRequest.system.contains("Never cross a known speaker boundary"))
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

    @Test func structuredOutputDecoderUsesFinalJSONAfterReasoning() async throws {
        let client = StubLLMClient(responses: [
            """
            <think>
            I should return {"cues": "an array"}, then verify every token.
            </think>
            ```json
            {"cues":[{"token_ids":[0,1],"text":"请测试声音。"}]}
            ```
            """,
        ])
        let transcript = TranscriptionResult(
            text: "请测试声音。",
            language: "zh",
            words: [
                .init(text: "请测试", start: 0, end: 0.5, speaker: nil),
                .init(text: "声音。", start: 0.5, end: 1, speaker: nil),
            ],
            segments: []
        )

        let track = try await SubtitleLLMProcessor(client: client).process(
            transcript: transcript,
            options: SubtitleProcessingPayload(maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.map(\.text) == ["请测试声音。"])
        #expect(track.cues.map(\.sourceIDs) == [[0, 1]])
        #expect(await client.requestCount == 1)
    }

    @Test func invalidSubtitleJSONPreservesExistingTimedTrack() async throws {
        let client = StubLLMClient(responses: ["<think>{not final}</think> not-json"])
        let executor = MediaFlowExecutor(llmClientFactory: { client })
        let transcript = TranscriptionResult(
            text: "请测试一下声音。",
            language: "zh",
            words: [.init(text: "请测试一下声音。", start: 0, end: 2, speaker: nil)],
            segments: [.init(text: "请测试一下声音。", start: 0, end: 2, speaker: nil)]
        )
        let baseline = SubtitleTrack.fromTranscript(transcript)
        let request = MediaFlowRequest(
            input: .transcript(transcript: transcript, subtitles: baseline, translation: nil),
            steps: [
                .prepareSubtitles(SubtitleProcessingPayload(
                    maximumAttempts: 1,
                    invalidOutputFallback: .preserveTimedTranscript
                )),
            ]
        )
        var resultingTrack: SubtitleTrack?
        var terminalProgress: MediaJobProgressEvent?

        for await event in executor.events(for: request) {
            switch event {
            case .artifact(.subtitles(let track, _)):
                resultingTrack = track
            case .progress(let progress) where progress.status == .completed:
                terminalProgress = progress
            default:
                break
            }
        }

        #expect(resultingTrack?.cues.map(\.text) == baseline.cues.map(\.text))
        #expect(resultingTrack?.cues.map(\.start) == baseline.cues.map(\.start))
        #expect(resultingTrack?.cues.map(\.end) == baseline.cues.map(\.end))
        #expect(terminalProgress?.step == "flow_completed")
        #expect(terminalProgress?.status == .completed)
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
}
