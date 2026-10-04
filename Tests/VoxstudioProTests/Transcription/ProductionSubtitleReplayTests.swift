#if BUNDLED_SPEECH
import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import Testing
@testable import VoxstudioPro

/// Opt-in replay of the actual user case, never overwrites Workbench or downloads models.
@Suite struct ProductionSubtitleReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTUDIO_SUBTITLE_REPLAY"] == "1"))
    @MainActor func scoliosisOriginalCacheAlignment() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
        let data = try Data(contentsOf: root.appendingPathComponent("Library/Application Support/VoxStudio/workbench.json"))
        let work = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let job = try #require((work["transcriptions"] as? [[String: Any]])?.first { $0["id"] as? String == "5A5B0854-C2C6-4E0C-BC90-E000211B4E25" })
        let transcript = try JSONDecoder().decode(TranscriptionResult.self, from: JSONSerialization.data(withJSONObject: job["result"]!))
        let text = transcript.words[1059..<1520].map(\.text).joined()
        let cache = root.appendingPathComponent("Library/Caches/VoxStudio/DecodedAudio/VfnDyrd1VaY_clip_20m18s-28m20s.mp4_86400372_1790856038_16kmono.caf")
        let audio = try AudioFileLoader.load(url: cache, targetSampleRate: 16_000)
        let model = try await Qwen3ForcedAligner.fromPretrained(modelId: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
            cacheDir: root.appendingPathComponent("Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ForcedAligner-0.6B-4bit"), offlineMode: true)
        let mask = AlignmentSpeechGate.mask(samples: audio, sampleRate: 16_000,
            speechIntervals: [.init(startTime: 231.2879375, endTime: 321.7879375)])
        let aligned = try LongFormAlignmentEngine.alignDetailed(audio: audio, sampleRate: 16_000,
            spans: [.init(text: text, startTime: 231.2879375, endTime: 321.2879375)],
            language: "Chinese", aligner: model, speechMask: mask, progress: { _, message in print("CASE REPLAY", message) })
        #expect(aligned.words.count == 461)
        #expect(aligned.coarseTimedUnitCount < 25)
        let na = aligned.words[1411 - 1059]
        print("CASE REPLAY 那", na.startTime, na.endTime, "estimated", aligned.coarseTimedUnitCount, "retry", aligned.retriedAlignmentChunkCount)
        #expect(na.text == "那")
        #expect(abs(Double(na.startTime) - 301.344) < 0.2)
        #expect(aligned.timingQualities[1411 - 1059] == .aligned)
        if let rerun = (work["transcriptions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "41EE6138-491D-4CF8-95CF-BDC0F0E53217" }) {
            let newer = try JSONDecoder().decode(TranscriptionResult.self, from: JSONSerialization.data(withJSONObject: rerun["result"]!))
            let newerText = newer.words.filter { ($0.start ?? -1) >= 231.287 && ($0.start ?? -1) < 321.287 }.map(\.text).joined()
            let check = try LongFormAlignmentEngine.alignDetailed(audio: audio, sampleRate: 16_000,
                spans: [.init(text: newerText, startTime: 231.2879375, endTime: 321.2879375)],
                language: "Chinese", aligner: model, speechMask: mask, progress: { _, _ in })
            print("CASE REPLAY fresh ASR", check.words.count, check.coarseTimedUnitCount)
            #expect(check.coarseTimedUnitCount < 25)
        }
        let audioDuration = Double(audio.count) / 16_000
        let diarizer = try MLXStreamingSortformerEngine(modelDirectory: LocalModelManager.directory(for: .sortformerDiarization), modelRevision: "e23e6404bd9859e93edbf94a740eb1c7fc58f12e")
        let timeline = try await diarizer.diarize(audio: audio, sampleRate: 16_000,
            speechRanges: [.init(start: 0, end: audioDuration)], policy: .standard(requestedSpeakerCount: 2),
            progress: { _ in })
        let attributed = LexicalSpeakerResolver.assignSpeakers(to: aligned.words, timeline: timeline,
            audioDuration: audioDuration, languageCode: "zh")
        let doctor = attributed[1410 - 1059].speaker
        let host = attributed[1411 - 1059].speaker
        print("CASE REPLAY speakers", doctor ?? "nil", host ?? "nil", "Na confidence", attributed[1411 - 1059].speakerConfidence ?? -1)
        #expect(host != nil && host != doctor)
        #expect(host == attributed[1415 - 1059].speaker)
        if let output = ProcessInfo.processInfo.environment["VOXSTUDIO_SUBTITLE_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var words = transcript.words
            for index in aligned.words.indices {
                let word = attributed[index]
                words[1059 + index] = word.withTimingQuality(aligned.timingQualities[index])
            }
            let original = try JSONDecoder().decode(SubtitleTrack.self, from: JSONSerialization.data(withJSONObject: job["subtitleTrack"]!))
            let fullText = ElasticSubtitleSegmenter.joinChunks(original.cues.map(\.text), languageCode: "zh")
            let anchors = ElasticSubtitleSegmenter.anchors(text: fullText, words: words)
            let result = try ElasticSubtitleSegmenter.optimize(.init(text: fullText, languageCode: "zh", proposedLines: original.cues.map(\.text),
                protectedSpans: ["打开之后你的骨头慢慢就可以归位", "比较加重的时候", "那谢谢吴医生"], anchors: anchors))
            let cues = result.cues.enumerated().map { index, cue in
                let members = anchors.filter { NSIntersectionRange($0.range, cue.range).length > 0 }
                let a = members.first?.start ?? original.cues.first!.start
                let b = max(a + 0.001, members.last?.end ?? a)
                return SubtitleCue(id: index, sourceIDs: [], text: cue.text, start: a, end: b, speaker: nil,
                    timingQuality: SubtitleTimingQuality.aggregate(members.map(\.quality)), displayLineBreaks: cue.displayLineBreaks)
            }
            let revised = SubtitleTrack(sourceLanguage: "zh", language: "zh", cues: cues, usesWordTimestamps: true, processingVersion: "elastic-v1")
            let translations = job["translationTracks"] as! [[String: Any]]
            let english = try JSONDecoder().decode(SubtitleTrack.self, from: JSONSerialization.data(withJSONObject: translations[0]["track"]!))
            var target: [SubtitleCue] = []
            for cue in english.cues {
                let optimized = try ElasticSubtitleSegmenter.optimize(.init(text: cue.text, languageCode: "en", start: cue.start, end: cue.end))
                for part in optimized.cues {
                    let length = max(1, (cue.text as NSString).length)
                    let start = cue.start + (cue.end - cue.start) * Double(part.range.location) / Double(length)
                    let end = cue.start + (cue.end - cue.start) * Double(NSMaxRange(part.range)) / Double(length)
                    target.append(SubtitleCue(id: target.count, sourceIDs: cue.sourceIDs, text: part.text, start: start, end: max(start + 0.001, end), speaker: cue.speaker,
                        timingQuality: .estimated, displayLineBreaks: part.displayLineBreaks))
                }
            }
            let revisedEnglish = SubtitleTrack(sourceLanguage: "zh", language: "en", cues: target, processingVersion: "elastic-v1")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for (name, track) in [("source-before", original), ("source-after", revised), ("english-before", english), ("english-after", revisedEnglish)] {
                try encoder.encode(track).write(to: folder.appendingPathComponent(name + ".json"))
                let segments = track.cues.map { SessionExportSegment(start: $0.start, end: $0.end, text: $0.displayText, speaker: $0.speaker) }
                for format in [SessionExportFormat.srt, .vtt] {
                    let value = SessionExportFormatter.render(segments: segments, format: format, variant: .original, translationOrder: .originalFirst, includeSpeakers: false, includeTimestamps: true, stripEdgePunctuation: false)
                    try value.write(to: folder.appendingPathComponent(name + "." + format.rawValue), atomically: true, encoding: .utf8)
                }
            }
            let report: [String: Any] = ["case": "脊椎侧弯运动与日常注意事项", "originalNaStart": transcript.words[1411].start!, "replayedNaStart": na.startTime,
                "alignedWords": aligned.words.count - aligned.coarseTimedUnitCount, "estimatedWords": aligned.coarseTimedUnitCount,
                "retries": aligned.retriedAlignmentChunkCount, "previousSpeaker": doctor ?? "unknown", "naSpeaker": host ?? "unknown",
                "scope": "Original decoded audio replay for the rejected 461-word block; existing finalized source/translated text resegmented in an isolated copy. Other word times retain legacy unknown quality. Protection hints are explicit regression fixtures, not new LLM results. English projected times remain estimated."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("case-replay.json"))
        }
        Memory.clearCache()
    }
}
#endif
