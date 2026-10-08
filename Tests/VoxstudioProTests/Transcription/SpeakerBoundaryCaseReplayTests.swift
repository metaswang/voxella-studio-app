#if BUNDLED_SPEECH
import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import MLXAudioSTT
import Testing
@testable import VoxstudioPro

/// Explicitly opted-in read-only replay. Never writes the user's Workbench.
@Suite("Speaker boundary production replay", .serialized)
struct SpeakerBoundaryCaseReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTUDIO_PREFIX_ASR"] == "1"))
    @MainActor func shortNativeReplay() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoxStudio/NetVideo/TbkUKCm3CHQ-5A3884D5-7D33-4EF4-90FD-CC54DC24A4DF.mp4")
        let audio = try AudioFileLoader.load(url: path, targetSampleRate: 16_000)
        let model = try ParakeetModel.fromDirectory(LocalModelManager.directory(for: .parakeetTDT06Bv3))
        let result = model.generateAligned(audio: MLXArray(Array(audio[25 * 16_000..<31 * 16_000])), generationParameters: STTGenerateParameters())
        print("PREFIX ASR", result.text)
        for token in result.sentences.flatMap(\.tokens) {
            print("PREFIX ASR", token.text, token.start + 25, token.end + 25)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTUDIO_SPEAKER_REPLAY"] == "1"))
    @MainActor func jevPrefix() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
        let inputURL = ProcessInfo.processInfo.environment["VOXSTUDIO_SPEAKER_INPUT"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Library/Application Support/VoxStudio/workbench.json")
        let input = try Data(contentsOf: inputURL)
        let snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: input)
        let job = try #require(snapshot.transcriptions.first { $0.id.uuidString == "401902CA-21B7-4198-BB42-B3BF681CF2AA" })
        let original = try #require(job.result)
        let directory = try #require(ProcessInfo.processInfo.environment["VOXSTUDIO_SPEAKER_ARTIFACTS"])
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try input.write(to: output.appendingPathComponent("workbench-before.json"), options: .withoutOverwriting)
        let audio = try AudioFileLoader.load(url: job.sourceURL, targetSampleRate: 16_000)
        let duration = Double(audio.count) / 16_000
        var engine: Nemotron3DiarizationEngine? = try .init(
            modelDirectory: LocalModelManager.directory(for: .nemotron3Diarization),
            modelRevision: "8be6cfb8a8009b1e11419208c819f6e20c94b4a3")
        let timeline = try await engine!.diarize(audio: audio, sampleRate: 16_000,
            speechRanges: [.init(start: 0, end: duration)], policy: .standard(requestedSpeakerCount: nil), progress: { _ in })
        let frameRecords = (Int(26.4 / timeline.frameDuration)..<Int(30.5 / timeline.frameDuration)).map { frame in
            ["start": Double(frame) * timeline.frameDuration,
             "probabilities": Array(timeline.probabilities[(frame * timeline.speakerCapacity)..<((frame + 1) * timeline.speakerCapacity)])] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: frameRecords, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("speaker-frames.json"))
        engine = nil
        Memory.clearCache()
        let aligner = try await Qwen3ForcedAligner.fromPretrained(
            modelId: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
            cacheDir: LocalModelManager.directory(for: .forcedAligner), offlineMode: true)
        // Limit the replay to the annotated turn; keep all other words verbatim.
        let lower = try #require(original.words.firstIndex { ($0.start ?? 0) >= 25 })
        let upper = try #require(original.words.lastIndex { ($0.end ?? 0) <= 31.5 }) + 1
        let local = Array(original.words[lower..<upper])
        let replay = try await SpeakerBoundaryRefiner.refine(words: local, timeline: timeline, languageCode: "en") { window in
            let a = Int((window.start * 16_000).rounded(.down))
            let b = min(audio.count, Int((window.end * 16_000).rounded(.up)))
            let offset = Double(a) / 16_000
            let aligned = aligner.align(audio: Array(audio[a..<b]), text: window.text,
                                        sampleRate: 16_000, language: "English")
            let timings = aligned.map {
                SpeakerBoundaryRefiner.Timing(text: $0.text, start: Double($0.startTime) + offset,
                                              end: Double($0.endTime) + offset)
            }
            let records = timings.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("alignment-\(window.wordIndices.lowerBound).json"))
            print("SPEAKER REPLAY window", window.start, window.end, window.text)
            for timing in timings { print("SPEAKER REPLAY timing", timing.text, timing.start, timing.end) }
            return timings
        }
        print("SPEAKER REPLAY diagnostics", replay.diagnostics)
        // The real Qwen replay is deliberately rejected: its context edges and
        // silent release tails do not provide unambiguous acoustic support.
        #expect(replay.words == local)
        #expect(replay.diagnostics.acceptedCount == 0)
        #expect(replay.diagnostics.unresolvedCount > 0)
        try encoder.encode(replay.diagnostics).write(to: output.appendingPathComponent("refinement.json"))
        // One-off user-annotated repair, corroborated by the independent 25–31s
        // Parakeet replay and 20ms waveform onset. These are estimates, not
        // accepted forced-alignment timestamps or automatic speaker decisions.
        var words = original.words
        let estimates: [(Int, Double, Double)] = [
            (87, 26.40, 26.92), (88, 27.38, 27.48), (89, 27.48, 27.72),
            (90, 27.72, 27.88), (91, 27.88, 28.36)
        ]
        for (index, start, end) in estimates {
            let old = words[index]
            words[index] = .init(text: old.text, start: start, end: end,
                                speaker: index == 87 ? "Speaker 1" : "Speaker 2",
                                speakerConfidence: nil, speakerBoundary: index == 88 ? .hard : .none,
                                timingQuality: .estimated)
        }
        let oldMy = try #require(timeline.attributionForWord(start: original.words[88].start!, end: original.words[88].end!))
        #expect(oldMy.absoluteProbability < 0.2)
        let onset = Array(audio[Int(27.38 * 16_000)..<Int(27.40 * 16_000)])
        let rms = sqrt(onset.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(onset.count))
        #expect(rms > 0.1)
        let note: [String: Any] = ["mode": "user-annotated estimated repair", "voicedOnset": 27.38,
            "onsetRMS": rms, "oldMyAbsoluteProbability": oldMy.absoluteProbability,
            "timingQuality": "estimated", "automaticAlignmentAccepted": false]
        try JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("case-review.json"))
        try encoder.encode(words).write(to: output.appendingPathComponent("words-after.json"))
        #expect(words.map(\.text) == original.words.map(\.text))
        try #require(words[88].speaker == "Speaker 2")
        #expect(words[87].speaker == "Speaker 1")
        #expect(words[92].speaker == "Speaker 1")
        let store = WorkbenchStore(persistenceURL: output.appendingPathComponent("isolated-workbench.json"))
        while store.isHydrating { await Task.yield() }
        store.transcriptions = [job]
        let applied = store.applySpeakerBoundaryRepair(inTranscription: job.id, expected: original,
                                                       words: words, diagnostics: replay.diagnostics)
        try #require(applied)
        try await store.saveMCPChanges()
        let repaired = try #require(store.transcriptions.first)
        let staleApplied = store.applySpeakerBoundaryRepair(inTranscription: job.id, expected: original,
                                                            words: words, diagnostics: replay.diagnostics)
        #expect(!staleApplied)
        #expect(repaired.result?.text == original.text)
        #expect(repaired.subtitleTrack?.cues.contains { $0.text == "My name is Jeff." && $0.speaker == "Speaker 2" } == true)
        try encoder.encode(job).write(to: output.appendingPathComponent("job-before.json"))
        try encoder.encode(repaired).write(to: output.appendingPathComponent("job-after.json"))
        for (name, track) in [("before", job.subtitleTrack!), ("after", repaired.subtitleTrack!)] {
            let segments = track.cues.map { SessionExportSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
            for format in [SessionExportFormat.srt, .vtt] {
                let text = SessionExportFormatter.render(segments: segments, format: format, variant: .original,
                    translationOrder: .originalFirst, includeSpeakers: true, includeTimestamps: true, stripEdgePunctuation: false)
                try text.write(to: output.appendingPathComponent("\(name).\(format.rawValue)"), atomically: true, encoding: .utf8)
            }
        }
        let (disk, outcome) = await WorkbenchPersistence(URL: output.appendingPathComponent("isolated-workbench.json")).load()
        #expect(outcome == .loaded)
        #expect(disk?.transcriptions.first?.result == repaired.result)
        #expect(disk?.transcriptions.first?.subtitleTrack == repaired.subtitleTrack)
        let restored = try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: encoder.encode(repaired))
        #expect(restored.result == repaired.result)
        #expect(restored.subtitleTrack == repaired.subtitleTrack)
        Memory.clearCache()
    }
}
#endif
