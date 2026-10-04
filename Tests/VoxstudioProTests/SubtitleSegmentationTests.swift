import Foundation
import Testing
@testable import VoxstudioPro

private actor SubtitleModeLLMStub: LLMTextClient {
    func complete(system: String, user: String) async throws -> String {
        user.contains("<asr_input>") ? #"{"text":"Hello, world."}"# : #"{"lines":["Hello, world."]}"#
    }
}

@Suite struct SubtitleSegmentationTests {
    @Test(arguments: [false, true]) func whisperTranscriptionOnlyCreatesSubtitlesWhenSelected(enabled: Bool) async throws {
        let raw = TranscriptionResult(
            text: "hello world", language: "en",
            words: [.init(text: "hello", start: 0, end: 0.5), .init(text: "world", start: 0.5, end: 1)],
            segments: [.init(text: "hello world", start: 0, end: 1)], asrEngine: .whisper
        )
        let output = LocalTranscriptionOutput(
            result: raw,
            diarizationDiagnostics: .init(backend: .disabled, elapsedSeconds: 0, processedChunks: 0, detectedSpeakerCount: 0, requestedSpeakerCount: nil, warnings: []),
            alignmentDiagnostics: .init(), engine: .whisper, routeConfidence: 1,
            route: .init(engine: .whisper, scores: .zero, reason: .userLocked, topLanguage: "en", parakeetDomainLanguage: nil, whisperHint: nil, routeConfidence: 1, speechDuration: 1)
        )
        let executor = MediaFlowExecutor(
            llmClientFactory: {
                if enabled { Issue.record("Selected local captions must skip Whisper LLM recovery") }
                return SubtitleModeLLMStub()
            },
            transcriptionFactory: { _, _ in output }
        )
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/stub-whisper.wav")
        job.useLLMSubtitleProcessing = enabled
        let request = MediaFlowRequest(
            input: .media(job.sourceURL),
            steps: WorkbenchMediaFlowPlanner.transcriptionSteps(
                for: job, subtitleSegmentationMethod: .localCaptions, hasSubtitleModel: false, hasTranslationModel: false
            )
        )
        var transcript: TranscriptionResult?
        var track: SubtitleTrack?
        var terminal: MediaJobStatus?
        for await event in executor.events(for: request) {
            if case .artifact(.transcription(let result, _, _)) = event { transcript = result }
            if case .artifact(.subtitles(let result, _)) = event { track = result }
            if case .progress(let progress) = event, progress.status == .completed || progress.status == .failed { terminal = progress.status }
        }
        #expect(terminal == .completed)
        if enabled {
            #expect(track?.text == "hello world")
        } else {
            #expect(track == nil)
            #expect(transcript?.text == "Hello, world.")
            #expect(transcript?.words == raw.words)
        }
    }

    @Test @MainActor func automaticChoiceRequiresBYOKAndConnectedSubtitleProvider() async throws {
        let suite = "SubtitleSegmentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LLMSettingsStore(defaults: defaults, legacyDefaults: [], credentialSaver: { _, _ in })
        let providerID = settings.addProvider(kind: .openAI)
        let provider = try #require(settings.provider(id: providerID))
        try settings.updateRoute(
            LLMModelRoute(primaryModel: "\(provider.normalizedPrefix)/subtitle-model", fallbackModels: [], policy: .default(for: .subtitleProcessing)),
            for: .subtitleProcessing
        )
        let connected: [UUID: ProviderConnectionState] = [providerID: .connected]

        // A connected provider alone is insufficient: the key and BYOK toggle matter.
        settings.useBYOK = true
        #expect(settings.subtitleSegmentationMethod(connectionStates: connected) == .localCaptions)
        try await settings.saveAPIKey("test-only-key", providerID: providerID)
        #expect(settings.subtitleSegmentationMethod(connectionStates: connected) == .llm)
        for state in [ProviderConnectionState.untested, .testing, .failed("offline", isRateLimited: false)] {
            #expect(settings.subtitleSegmentationMethod(connectionStates: [providerID: state]) == .localCaptions)
        }
        #expect(settings.subtitleSegmentationMethod(connectionStates: [:]) == .localCaptions)
        settings.useBYOK = false
        #expect(settings.subtitleSegmentationMethod(connectionStates: connected) == .localCaptions)

        // A connection belonging to a different route must not enable LLM subtitles.
        settings.useBYOK = true
        let otherID = settings.addProvider(kind: .anthropic)
        try await settings.saveAPIKey("other-test-key", providerID: otherID)
        #expect(settings.subtitleSegmentationMethod(connectionStates: [otherID: .connected]) == .localCaptions)
        try settings.updateRoute(.default(for: .subtitleProcessing), for: .subtitleProcessing)
        #expect(settings.subtitleSegmentationMethod(connectionStates: connected) == .localCaptions)
    }

    @Test func checkboxControlsSegmentationIndependentlyOfAIAvailability() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/interview.wav")
        #expect(job.useLLMSubtitleProcessing == false)
        for method in [SubtitleSegmentationMethod.localCaptions, .llm] {
            let steps = WorkbenchMediaFlowPlanner.transcriptionSteps(
                for: job, subtitleSegmentationMethod: method, hasSubtitleModel: true, hasTranslationModel: true
            )
            #expect(steps.map(\.stage) == [.transcription])
        }
        job.useLLMSubtitleProcessing = true
        for hasModel in [false, true] {
            let steps = WorkbenchMediaFlowPlanner.transcriptionSteps(
                for: job, subtitleSegmentationMethod: .localCaptions, hasSubtitleModel: hasModel, hasTranslationModel: hasModel
            )
            #expect(steps.map(\.stage) == [.transcription, .subtitlePreparation])
            guard case .prepareSubtitles(let payload) = steps.last else { Issue.record("Missing subtitles"); return }
            #expect(payload.segmentationMethod == .localCaptions)
        }
        let llmSteps = WorkbenchMediaFlowPlanner.transcriptionSteps(
            for: job, subtitleSegmentationMethod: .llm, hasSubtitleModel: true, hasTranslationModel: false
        )
        guard case .prepareSubtitles(let payload) = llmSteps.last else { Issue.record("Missing LLM subtitles"); return }
        #expect(payload.segmentationMethod == .llm)
        #expect(payload.requiresConnectedBYOK)
    }

    @Test func localCaptionsMatchVideoEditorAndPreserveWordTimingAndSpeakers() throws {
        let words = (0..<40).map { index in
            TranscriptionWord(text: "word\(index)", start: 5 + Double(index), end: 5.8 + Double(index), speaker: index < 20 ? "Host" : "Guest")
        }
        let transcript = TranscriptionResult(
            text: words.map(\.text).joined(separator: " "), language: "en", words: words,
            segments: [
                .init(text: words[..<20].map(\.text).joined(separator: " "), start: 5, end: 25, speaker: "Host"),
                .init(text: words[20...].map(\.text).joined(separator: " "), start: 25, end: 45, speaker: "Guest"),
            ]
        )
        let clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 45 * 30)
        let editorPhrases = CaptionTranscriptMapper.phrases(
            for: clip, result: transcript, fps: 30, maxWords: nil, minDuration: AppTheme.Caption.minDisplayDuration,
            fits: { CaptionSpecBuilder.lineFits($0, style: EditorViewModel.CaptionRequest.defaultLocalStyle, canvasWidth: 1920, canvasHeight: 1080) }
        )
        let track = try LocalSubtitleProcessor.process(transcript)

        #expect(track.cues.count > transcript.segments.count)
        #expect(track.cues.map(\.text) == editorPhrases.map(\.text))
        #expect(track.cues.map(\.start) == editorPhrases.map(\.start))
        #expect(track.cues.map(\.end) == editorPhrases.map(\.end))
        #expect(track.text == transcript.text)
        #expect(track.usesWordTimestamps)
        #expect(track.cues.flatMap(\.sourceIDs) == Array(words.indices))
        #expect(track.cues.filter { $0.start < 25 }.allSatisfy { $0.speaker == "Host" && $0.end <= 25 })
        #expect(track.cues.filter { $0.start >= 25 }.allSatisfy { $0.speaker == "Guest" })
    }

    @Test func localCaptionsSupportDenseScriptsAndMissingWordTimings() throws {
        let chinese = "今天我们一起学习字幕切分功能。它可以帮助大家更轻松地阅读视频中的内容。"
        let words = chinese.enumerated().map { index, character in
            TranscriptionWord(text: String(character), start: Double(index) * 0.3, end: Double(index + 1) * 0.3, speaker: "Host")
        }
        let track = try LocalSubtitleProcessor.process(.init(text: chinese, language: "zh", words: words, segments: []))
        #expect(track.cues.count > 1)
        #expect(track.cues.map(\.text).joined() == chinese)
        #expect(track.cues.allSatisfy { ElasticSubtitleSegmenter.LayoutProfile().measure($0.text).fits && $0.speaker == "Host" })

        let english = "This is a long sentence without word timestamps that must still become several readable captions while preserving the recognized text exactly."
        let segmentTrack = try LocalSubtitleProcessor.process(.init(
            text: english, language: "en", words: [], segments: [.init(text: english, start: 3, end: 20, speaker: "Guest")]
        ))
        #expect(segmentTrack.cues.count > 1)
        #expect(segmentTrack.text == english)
        #expect(!segmentTrack.usesWordTimestamps)
        #expect(segmentTrack.cues.first?.start == 3)
        #expect(segmentTrack.cues.last?.end == 20)
        #expect(segmentTrack.cues.allSatisfy { $0.speaker == "Guest" && $0.end > $0.start })
    }

    @Test func localSubtitleFlowCompletesWithoutConstructingAnLLMClient() async throws {
        struct UnexpectedLLM: Error {}
        let executor = MediaFlowExecutor(llmClientFactory: { Issue.record("Local captions must not construct an LLM client"); throw UnexpectedLLM() })
        let transcript = TranscriptionResult(
            text: "hello world", language: "en",
            words: [.init(text: "hello", start: 0, end: 0.5), .init(text: "world", start: 0.5, end: 1)],
            segments: [.init(text: "hello world", start: 0, end: 1)]
        )
        let request = MediaFlowRequest(
            input: .transcript(transcript: transcript, subtitles: nil, translation: nil),
            steps: [.prepareSubtitles(.init(segmentationMethod: .localCaptions))]
        )
        var track: SubtitleTrack?
        var terminal: MediaJobProgressEvent?
        for await event in executor.events(for: request) {
            if case .artifact(.subtitles(let result, let rebuilt)) = event {
                track = result
                #expect(rebuilt == nil)
            }
            if case .progress(let progress) = event, progress.status == .completed || progress.status == .failed {
                terminal = progress
            }
        }
        #expect(track?.text == "hello world")
        #expect(terminal?.status == .completed)
        #expect(terminal?.message.contains("failed") == false)
    }
}
