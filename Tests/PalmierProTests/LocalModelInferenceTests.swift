import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

#if BUNDLED_SPEECH
@Suite("Voxella local model inference", .serialized)
struct LocalModelInferenceTests {
    private static let enabled = ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"
    private static let realAudioEnabled = ProcessInfo.processInfo.environment["VOXELLA_RUN_REAL_AUDIO"] == "1"

    @Test
    func forcedAlignerTimingsAreClampedAndPositive() {
        let raw = [(0.0, 0.0), (0.5, 0.5), (60.4, 60.56), (60.56, 60.56)]
        var previousStart = 0.0
        let normalized = raw.map { start, end in
            let timing = LocalSpeechPipeline.normalizedWordTiming(
                start: start,
                end: end,
                previousStart: previousStart,
                audioDuration: 60
            )
            previousStart = timing.start
            return timing
        }

        #expect(normalized.allSatisfy { $0.end > $0.start })
        #expect(normalized.allSatisfy { $0.start >= 0 && $0.end <= 60 })
        #expect(zip(normalized, normalized.dropFirst()).allSatisfy { pair in
            pair.0.start <= pair.1.start
        })
    }

    @Test(.enabled(if: enabled))
    func englishSingleSpeakerTranscriptionIsTimed() async throws {
        let source = Self.fixture("en-single.wav")
        let result = try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: source,
            languageCode: "en",
            speakerCount: 1,
            progress: { _, _ in }
        )

        let normalized = result.text.lowercased()
        #expect(["welcome", "local", "timestamp"].filter(normalized.contains).count >= 2)
        #expect(Self.timestampsAreValid(result.words, duration: try await Self.duration(of: source)))
        #expect(Set(result.words.compactMap(\.speaker)).count == 1)
    }

    @Test(.enabled(if: realAudioEnabled))
    func realEnglishWarroomAudioCoversTheFullMinute() async throws {
        let source = URL(fileURLWithPath: "/Users/adamwang/Downloads/warroom20251115.clip_002313_5_16k_last1min.m4a")
        let duration = try await Self.duration(of: source)
        let output = try await LocalSpeechPipeline.shared.transcribeDetailed(
            sourceURL: source,
            languageCode: "en",
            speakerCount: 1,
            progressUpdate: { update in
                print(
                    "[warroom-en] \(update.stage.rawValue) "
                        + "\(update.completed ?? 0)/\(update.total ?? 0) \(update.message)"
                )
            }
        )

        let result = output.result
        let normalized = result.text.lowercased()
        print("[warroom-en] transcript=\(result.text)")
        print(
            "[warroom-en] words=\(result.words.count) "
                + "lastEnd=\(result.words.last?.end ?? 0) duration=\(duration)"
        )
        #expect(["country", "republicans", "president"].filter(normalized.contains).count >= 2)
        #expect(Self.timestampsAreValid(result.words, duration: duration))
        #expect((result.words.last?.end ?? 0) >= duration - 2)
        #expect(Set(result.words.compactMap(\.speaker)) == ["Speaker 1"])
        #expect(output.diarizationDiagnostics.backend == .singleSpeaker)
        #expect(
            !output.diarizationDiagnostics.warnings.contains {
                $0.contains("word timings are estimates")
            }
        )
    }

    @Test(.enabled(if: realAudioEnabled))
    func realLongChineseAudioKeepsAlignmentThroughTheTail() async throws {
        let source = URL(fileURLWithPath: "/Users/adamwang/Downloads/黄建筑师.m4a")
        let duration = try await Self.duration(of: source)
        let output = try await LocalSpeechPipeline.shared.transcribeDetailed(
            sourceURL: source,
            languageCode: "zh",
            speakerCount: 1,
            progressUpdate: { update in
                print("[long-zh] \(update.stage.rawValue) \(update.completed ?? 0)/\(update.total ?? 0) \(update.message)")
            }
        )

        let result = output.result
        print(
            "[long-zh] words=\(result.words.count) characters=\(result.text.count) "
                + "lastEnd=\(result.words.last?.end ?? 0) duration=\(duration)"
        )
        print("[long-zh] warnings=\(output.diarizationDiagnostics.warnings)")
        #expect(result.text.count > 1_000)
        #expect(Self.timestampsAreValid(result.words, duration: duration))
        #expect((result.words.last?.end ?? 0) >= duration * 0.80)
        #expect(Set(result.words.compactMap(\.speaker)) == ["Speaker 1"])
        #expect(output.diarizationDiagnostics.backend == .singleSpeaker)
    }

    @Test(.enabled(if: enabled))
    func chineseSingleSpeakerTranscriptionIsTimed() async throws {
        let source = Self.fixture("zh-single.wav")
        let result = try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: source,
            languageCode: nil,
            speakerCount: 1,
            progress: { _, _ in }
        )

        #expect(
            ["欢迎", "测试", "时间"].filter(result.text.contains).count >= 2,
            "Transcript: \(result.text)"
        )
        #expect(result.language?.hasPrefix("zh") == true, "Language: \(result.language ?? "nil")")
        #expect(Self.timestampsAreValid(result.words, duration: try await Self.duration(of: source)))
        #expect(Set(result.words.compactMap(\.speaker)).count == 1)
    }

    @Test(.enabled(if: enabled))
    func englishTwoSpeakerTranscriptionHasAlignedWords() async throws {
        let source = Self.fixture("en-two-speakers.wav")
        let result = try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: source,
            languageCode: "en",
            speakerCount: 2,
            progress: { _, _ in }
        )

        let normalized = result.text.lowercased()
        #expect(["local", "caption", "editor", "timestamp"].filter(normalized.contains).count >= 2)
        #expect(!result.words.isEmpty)
        let duration = try await Self.duration(of: source)
        #expect(Self.timestampsAreValid(result.words, duration: duration))
        #expect(Set(result.words.compactMap(\.speaker)).count == 2)
        #expect(Self.dominantSpeaker(result.words, before: duration / 2)
            != Self.dominantSpeaker(result.words, after: duration / 2))
    }

    @Test(.enabled(if: enabled))
    func chineseTwoSpeakerTranscriptionHasAlignedWords() async throws {
        let source = Self.fixture("zh-two-speakers.wav")
        let result = try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: source,
            languageCode: "zh",
            speakerCount: 2,
            progress: { _, _ in }
        )

        #expect(
            ["说话", "检测", "字幕", "时间"].filter(result.text.contains).count >= 2,
            "Transcript: \(result.text)"
        )
        #expect(Self.timestampsAreValid(result.words, duration: try await Self.duration(of: source)))
        #expect(
            Set(result.words.compactMap(\.speaker)).count == 2,
            "Speakers: \(result.words.compactMap(\.speaker))"
        )
    }

    @Test(.enabled(if: enabled))
    func silenceIsRejectedBeforeWhisper() async {
        do {
            _ = try await LocalSpeechPipeline.shared.transcribe(
                sourceURL: Self.fixture("silence.wav"),
                languageCode: nil,
                speakerCount: nil,
                progress: { _, _ in }
            )
            Issue.record("Silence unexpectedly produced a transcript")
        } catch LocalAIError.emptyTranscript {
            // Expected: the local VAD gate prevents Whisper hallucinations.
        } catch {
            Issue.record("Unexpected silence error: \(error)")
        }
    }

    @Test(.enabled(if: enabled), arguments: [DubModelChoice.medium])
    func qwenDubProducesAudible24kMono(choice: DubModelChoice) async throws {
        let output = try await LocalDubPipeline.shared.synthesize(
            script: "Voxella Studio keeps this dubbing test on this Mac.",
            language: "en",
            model: choice,
            referenceAudioURL: nil,
            referenceText: "",
            progress: { _, _ in }
        )
        try Self.validateDub(output)
    }

    @Test(.enabled(if: enabled))
    func qwenDubFlowAlignsSynthesizedScriptAndBuildsSubtitles() async throws {
        let script = "Alpha begins now. Bravo follows after the pause. Charlie closes the test."
        let payload = DubFlowPayload(
            segments: [DubSegmentPayload(index: 0, text: script, speaker: "Narrator")],
            language: "en",
            model: .medium,
            reference: nil,
            speakerReferences: [:]
        )
        let request = MediaFlowRequest(
            input: .script(script),
            steps: WorkbenchMediaFlowPlanner.dubSteps(payload: payload, hasAPIKey: false)
        )
        var dub: DubFlowResult?
        var alignment: KnownTextAlignmentOutput?
        var subtitles: SubtitleTrack?

        for await event in MediaFlowExecutor.shared.events(for: request) {
            switch event {
            case .artifact(.dub(let output)):
                dub = output
            case .artifact(.alignment(let output)):
                alignment = output
            case .artifact(.subtitles(let track, _)):
                subtitles = track
            case .progress(let progress) where progress.status == .failed:
                Issue.record(NSError(
                    domain: "VoxellaDubFlowExperiment",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: progress.message]
                ))
            default:
                break
            }
        }

        let rendered = try #require(dub)
        defer { try? FileManager.default.removeItem(at: rendered.outputURL) }
        let aligned = try #require(alignment)
        let track = try #require(subtitles)
        let duration = try await Self.duration(of: rendered.outputURL)
        print(
            "[dub-align] duration=\(duration) words=\(aligned.result.words.count) "
                + "cues=\(track.cues.count) estimated=\(aligned.diagnostics.estimatedUnitCount) "
                + "first=\(aligned.result.words.first?.start ?? -1) "
                + "last=\(aligned.result.words.last?.end ?? -1)"
        )
        #expect(Self.timestampsAreValid(aligned.result.words, duration: duration))
        #expect(aligned.result.words.count >= 8)
        #expect(Set(aligned.result.words.compactMap(\.speaker)) == ["Narrator"])
        #expect(track.cues.count >= 2)
        #expect(track.cues.allSatisfy { $0.end > $0.start && $0.end <= duration + 0.1 })
    }

    @Test(.enabled(if: enabled))
    func qwenSmallAutoLanguageProducesChineseAudio() async throws {
        let output = try await LocalDubPipeline.shared.synthesize(
            script: "欢迎使用完全本地运行的配音功能。",
            language: "auto",
            model: .medium,
            referenceAudioURL: nil,
            referenceText: "",
            progress: { _, _ in }
        )
        try Self.validateDub(output)
    }

    @Test(.enabled(if: enabled))
    func qwenSmallVoiceCloneUsesReferenceAudio() async throws {
        let reference = Self.fixture("tts-reference.wav")
        let output = try await LocalDubPipeline.shared.synthesize(
            script: "This sentence verifies local voice cloning.",
            language: "en",
            model: .medium,
            referenceAudioURL: reference,
            referenceText: "",
            progress: { _, _ in }
        )
        try Self.validateDub(output)
    }

    @Test(.enabled(if: enabled))
    func qwenSmallICLVoiceCloneUsesReferenceTranscript() async throws {
        let output = try await LocalDubPipeline.shared.synthesize(
            script: "This sentence verifies local in-context voice cloning.",
            language: "en",
            model: .medium,
            referenceAudioURL: Self.fixture("en-single.wav"),
            referenceText: "Welcome to Voxella Studio. This recording tests local word timestamps.",
            progress: { _, _ in }
        )
        try Self.validateDub(output)
    }

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("data/test-fixtures/voxella-local")
            .appendingPathComponent(name)
    }

    private static func duration(of url: URL) async throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func timestampsAreValid(_ words: [TranscriptionWord], duration: Double) -> Bool {
        var previous = 0.0
        for word in words {
            guard let start = word.start, let end = word.end,
                  start >= 0, start >= previous, end > start, end <= duration + 0.1 else { return false }
            previous = start
        }
        return true
    }

    private static func dominantSpeaker(
        _ words: [TranscriptionWord],
        before boundary: Double
    ) -> String? {
        dominantSpeaker(words.filter { (($0.start ?? 0) + ($0.end ?? 0)) / 2 < boundary })
    }

    private static func dominantSpeaker(
        _ words: [TranscriptionWord],
        after boundary: Double
    ) -> String? {
        dominantSpeaker(words.filter { (($0.start ?? 0) + ($0.end ?? 0)) / 2 >= boundary })
    }

    private static func dominantSpeaker(_ words: [TranscriptionWord]) -> String? {
        Dictionary(grouping: words.compactMap(\.speaker), by: { $0 })
            .max { $0.value.count < $1.value.count }?.key
    }

    private static func validateDub(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 24_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 24_000 * 8 / 10)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            Issue.record("Unable to allocate dub validation buffer")
            return
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            Issue.record("Dub output has no PCM channel")
            return
        }
        let count = Int(buffer.frameLength)
        let meanSquare = (0..<count).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(max(1, count))
        #expect(sqrt(meanSquare) > 0.003)
    }
}
#endif
