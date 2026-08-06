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

@Suite("Flexible media flows")
struct MediaFlowTests {
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
            #"{"cues":[{"token_ids":[0,1],"text":"Hello, world."},{"token_ids":[2],"text":"Again."}]}"#,
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
            options: SubtitleProcessingPayload(maximumAttempts: 2),
            progress: { _, _, _, _ in }
        )

        #expect(track.cues.map(\.text) == ["Hello, world.", "Again."])
        #expect(track.cues.map(\.sourceIDs) == [[0, 1], [2]])
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(track.cues[0].start == 0.1)
        #expect(track.cues[0].end == 0.9)
        let requestCount = await client.requestCount
        #expect(requestCount == 2)
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
        #expect(track.cues.flatMap(\.sourceIDs) == [0, 1, 2, 3])
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(await client.requestCount == 1)
    }

    @Test func subtitleProcessorRemapsBrokenTokenIDsWithoutFailing() async throws {
        let client = StubLLMClient(responses: [
            #"{"cues":[{"token_ids":[0,3],"text":"Hello, world."},{"token_ids":[9],"text":"Again now."}]}"#,
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
        #expect(track.cues.map(\.text) == ["Hello, world.", "Again now."])
        #expect(track.cues.map(\.sourceIDs) == [[0, 1], [2, 3]])
        #expect(track.cues.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(await client.requestCount == 1)
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
        let client = StubLLMClient(responses: [
            #"{"subtitles":["Hello, world.","Again now."]}"#,
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
        #expect(track.cues.map(\.sourceIDs) == [[0, 1], [2, 3]])
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
            case .artifact(.subtitles(let track)):
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

        let translated = try await TranslationLLMProcessor(client: client).translate(
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

        let translated = try await TranslationLLMProcessor(client: client).translate(
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

        let translated = try await TranslationLLMProcessor(client: client).translate(
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

        let translated = try await TranslationLLMProcessor(client: client).translate(
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
                .init(text: "reply", start: 31, end: 34, speaker: "Speaker 2"),
            ],
            segments: [
                .init(text: "helo world", start: 0, end: 10, speaker: "Speaker 1"),
                .init(text: "this raw sentence", start: 10, end: 31, speaker: "Speaker 1"),
                .init(text: "reply", start: 31, end: 34, speaker: "Speaker 2"),
            ]
        )
        let client = StubLLMClient(responses: [
            #"{"cues":[{"token_ids":[0,1],"text":"Hello, world."},{"token_ids":[2],"text":"This sentence was corrected."},{"token_ids":[3],"text":"Reply."}]}"#,
        ])
        job.subtitleTrack = try await SubtitleLLMProcessor(client: client).process(
            transcript: try #require(job.result),
            options: SubtitleProcessingPayload(maximumAttempts: 1),
            progress: { _, _, _, _ in }
        )

        let displayed = job.displayedSegments

        #expect(displayed.count == 2)
        #expect(job.subtitleTrack?.cues.map(\.sourceIDs) == [[0, 1], [2], [3]])
        #expect(job.subtitleTrack?.cues.map(\.start) == [0, 10, 31])
        #expect(job.subtitleTrack?.cues.map(\.end) == [10, 31, 34])
        #expect(displayed[0].text == "Hello, world. This sentence was corrected.")
        #expect(displayed[0].start == 0)
        #expect(displayed[0].end == 31)
        #expect(displayed[0].speaker == "Speaker 1")
        #expect(displayed[1].text == "Reply.")
        #expect(displayed[1].speaker == "Speaker 2")
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
}
