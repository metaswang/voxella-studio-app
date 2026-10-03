import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Speaker boundary evidence and refinement")
struct SpeakerBoundaryRefinementTests {
    private func timeline(_ probabilities: [Float], frame: Double = 0.08) -> SpeakerActivityTimeline {
        let duration = Double(probabilities.count / 2) * frame
        return .init(intervals: [.init(start: 0, end: duration, speakerID: 0, confidence: 0.9),
                                 .init(start: 0, end: duration, speakerID: 1, confidence: 0.9)],
                     probabilities: probabilities, frameDuration: frame, speakerCapacity: 2,
                     audioDuration: duration,
                     diagnostics: .init(backend: .mlxStreamingSortformer, elapsedSeconds: 0,
                                        processedChunks: 1, detectedSpeakerCount: 2, requestedSpeakerCount: nil, warnings: []))
    }

    @Test func zeroOverlapNeighborDoesNotOutvoteActualAudio() throws {
        let t = timeline([0.9, 0.1, 0.1, 0.9])
        let evidence = try #require(t.attributionForWord(start: 0.07, end: 0.075))
        #expect(evidence.speakerID == 0)
        #expect(abs(evidence.absoluteProbability - 0.9) < 0.00001)
        #expect(abs(evidence.supportDuration - 0.005) < 0.00001)
        #expect(t.speakerForWord(start: 0.07, end: 0.1) == 1)
    }

    @Test func invalidAndSilentWindowsAbstainEvenWithIntervals() {
        let t = timeline([0, 0, 0, 0])
        for pair in [(0.02, 0.02), (0.03, 0.02), (Double.nan, 0.1), (0.0, Double.infinity), (0.02, 0.05), (0.2, 0.3)] {
            #expect(t.attributionForWord(start: pair.0, end: pair.1) == nil)
        }
        let distant = SpeakerActivityTimeline(intervals: [.init(start: 1, end: 2, speakerID: 0, confidence: 0.9)],
            probabilities: [], frameDuration: 0, speakerCapacity: 1, audioDuration: 3, diagnostics: t.diagnostics)
        #expect(distant.attributionForWord(start: 0, end: 0.5) == nil)
    }

    @Test func relativeConfidenceDoesNotHideWeakAbsoluteEvidence() throws {
        let t = timeline([0.001, 0.00001])
        let evidence = try #require(t.attributionForWord(start: 0, end: 0.08))
        #expect(evidence.confidence > 0.98)
        #expect(evidence.absoluteProbability < 0.01)
    }

    @Test func confidentOneWordReplyAndChineseCompoundSurvive() {
        let t = timeline([0.98, 0.01, 0.01, 0.98, 0.98, 0.01])
        let words = [TranscriptionWord(text: "Ready?", start: 0, end: 0.08),
                     .init(text: "Yes!", start: 0.08, end: 0.16), .init(text: "Good.", start: 0.16, end: 0.24)]
        let resolved = LexicalSpeakerResolver.resolving(words, timeline: t, languageCode: "en")
        #expect(resolved.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        let chinese = LexicalSpeakerResolver.resolving([
            .init(text: "费", start: 0, end: 0.05), .init(text: "力", start: 0.05, end: 0.08),
            .init(text: "吗", start: 0.08, end: 0.16)], timeline: t, languageCode: "zh")
        #expect(chinese[0].speaker == chinese[1].speaker)
        #expect(chinese[1].speakerBoundary == .none)
    }

    @Test func weakOutgoingTailDoesNotEraseClearIncomingBoundary() {
        let t = timeline([0.02, 0.001, 0.001, 0.98])
        let resolved = LexicalSpeakerResolver.resolving([
            .init(text: "Tail.", start: 0, end: 0.08),
            .init(text: "Hello", start: 0.08, end: 0.16)
        ], timeline: t, languageCode: "en")
        #expect(resolved.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(resolved[1].speakerBoundary == .hard)
    }

    private func fixture() -> (SpeakerActivityTimeline, [TranscriptionWord]) {
        let t = timeline([0.99, 0.01, 0.99, 0.01, 0.99, 0.01, 0.01, 0.99, 0.01, 0.99, 0.01, 0.99])
        let words = [TranscriptionWord(text: "Jev.", start: 0, end: 0.16, speaker: "Speaker 1", speakerConfidence: 0.99, timingQuality: .aligned),
                     .init(text: "My", start: 0.16, end: 0.24, speaker: "Speaker 1", speakerConfidence: 0.96, timingQuality: .aligned),
                     .init(text: "name", start: 0.32, end: 0.4, speaker: "Speaker 2", speakerConfidence: 0.99, timingQuality: .aligned)]
        return (t, words)
    }

    @Test func highConfidenceMisalignedShortPrefixIsRechecked() async throws {
        let (t, words) = fixture()
        let result = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            [.init(text: "Jev", start: 0, end: 0.16), .init(text: "My", start: 0.24, end: 0.32),
             .init(text: "name", start: 0.32, end: 0.4)]
        }
        #expect(result.diagnostics.acceptedCount == 1)
        #expect(result.words.map(\.text) == words.map(\.text))
        #expect(result.words[1].speaker == "Speaker 2")
        #expect(result.words[1].speakerBoundary == .hard)
        #expect(result.words[2].speakerBoundary == .none)
    }

    @Test func successfulWindowCannotRewriteFailedWindowAfterLongPause() async throws {
        let (_, first) = fixture()
        let second = first.map {
            TranscriptionWord(text: $0.text, start: $0.start! + 10, end: $0.end! + 10,
                              speaker: $0.speaker, speakerConfidence: $0.speakerConfidence,
                              speakerBoundary: .none, timingQuality: $0.timingQuality)
        }
        var frames = Array(repeating: [Float(0.99), Float(0.01)], count: 140)
        for index in [3, 4, 5, 128, 129, 130] { frames[index] = [0.01, 0.99] }
        let t = timeline(frames.flatMap { $0 })
        let result = try await SpeakerBoundaryRefiner.refine(words: first + second, timeline: t, languageCode: "en") { window in
            if window.wordIndices.lowerBound > 0 { throw CocoaError(.fileNoSuchFile) }
            return [.init(text: "Jev", start: 0, end: 0.16), .init(text: "My", start: 0.24, end: 0.32),
                    .init(text: "name", start: 0.32, end: 0.4)]
        }
        #expect(result.diagnostics == .init(candidateCount: 2, acceptedCount: 1, unresolvedCount: 1))
        #expect(result.words[1].speaker == "Speaker 2")
        #expect(Array(result.words[3...]) == second)
    }

    @Test func incompleteAlignmentAndUnavailableModelKeepOriginalWords() async throws {
        let (t, words) = fixture()
        let missing = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            [.init(text: "name", start: 0.32, end: 0.4)]
        }
        let unavailable = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            throw CocoaError(.fileNoSuchFile)
        }
        for result in [missing, unavailable] {
            #expect(result.words == words)
            #expect(result.diagnostics.unresolvedCount == 1)
        }
    }

    @Test func overlapDoesNotGetResolvedBySentenceGrammar() async throws {
        let (_, words) = fixture()
        let t = timeline(Array(repeating: [Float(0.8), Float(0.8)], count: 6).flatMap { $0 })
        let result = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            words.map { .init(text: $0.text, start: $0.start!, end: $0.end!) }
        }
        #expect(result.words == words)
        #expect(result.diagnostics.unresolvedCount == 1)
    }

    @Test func punctuationAndChineseTokenizationMapBackToOriginalWords() throws {
        let words = [TranscriptionWord(text: "费力", start: 0, end: 0.2), .init(text: "吗？", start: 0.2, end: 0.3)]
        let window = SpeakerBoundaryRefiner.Window(wordIndices: 0..<2, start: 0, end: 0.4, text: "费力吗？")
        let mapped = try #require(SpeakerBoundaryRefiner.remap([
            .init(text: "费", start: 0, end: 0.1), .init(text: "力", start: 0.1, end: 0.2),
            .init(text: "吗", start: 0.2, end: 0.3)], onto: words, window: window))
        #expect(mapped.map(\.text) == words.map(\.text))
        #expect(mapped[0].end == 0.2)
    }

    @Test func coarseContextCannotTriggerAnUnboundedModelReplay() async throws {
        let t = timeline(Array(repeating: [Float(0.99), Float(0.01)], count: 500).flatMap { $0 })
        let words = [TranscriptionWord(text: "Long", start: 0, end: 25, speaker: "Speaker 1", timingQuality: .estimated),
                     .init(text: "reply", start: 25, end: 26, speaker: "Speaker 2", timingQuality: .estimated)]
        let result = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            Issue.record("Coarse context longer than 12 seconds must not run a model")
            return []
        }
        #expect(result.words == words)
        #expect(result.diagnostics.unresolvedCount == 1)
    }

    @Test func collapsedAlignmentIsRejected() {
        let (_, words) = fixture()
        let window = SpeakerBoundaryRefiner.Window(wordIndices: 0..<3, start: 0, end: 0.5, text: "Jev. My name")
        #expect(SpeakerBoundaryRefiner.remap([
            .init(text: "Jev", start: 0, end: 0.4), .init(text: "My", start: 0, end: 0.4),
            .init(text: "name", start: 0, end: 0.4)], onto: words, window: window) == nil)
    }

    @Test func cancelledReplayCannotApplyTimings() async throws {
        let (t, words) = fixture()
        let task = Task {
            try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
                try await Task.sleep(for: .seconds(10))
                return []
            }
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test func singleSpeakerKeepsFastPath() async throws {
        let (_, words) = fixture()
        var t = timeline([0.99, 0.01])
        t = .init(intervals: [.init(start: 0, end: 0.08, speakerID: 0, confidence: 1)],
                  probabilities: t.probabilities, frameDuration: t.frameDuration,
                  speakerCapacity: t.speakerCapacity, audioDuration: t.audioDuration, diagnostics: t.diagnostics)
        let result = try await SpeakerBoundaryRefiner.refine(words: words, timeline: t, languageCode: "en") { _ in
            Issue.record("Single speaker must not load an aligner")
            return []
        }
        #expect(result.words == words)
        #expect(result.diagnostics.candidateCount == 0)
    }

    @Test func legacyDiagnosticsDecodeWithZeroRefinementCounts() throws {
        let old = try JSONDecoder().decode(TranscriptionAlignmentDiagnostics.self, from: Data("{}".utf8))
        #expect(old.speakerBoundaryRefinement == .init())
    }

    @Test func subtitleMetadataPreservesExistingFieldsAndDecodesLegacyDefaults() throws {
        let legacy = Data(#"{"sourceLanguage":"en","language":"en","usesWordTimestamps":true,"cues":[{"id":9,"sourceIDs":[88],"text":"My","start":27.2,"end":27.28,"speaker":"Speaker 1"}]}"#.utf8)
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: legacy)
        #expect(track.processingVersion == nil)
        #expect(track.cues[0].timingQuality == .unknown)
        #expect(track.cues[0].boundaryBefore == nil)
        var enriched = track
        enriched.processingVersion = "elastic-v1"
        enriched.cues[0].timingQuality = .estimated
        enriched.cues[0].boundaryBefore = .hard
        enriched.cues[0].protectedSpans = ["My"]
        enriched.cues[0].segmentationHints = ["sentence-start"]
        enriched.cues[0].displayLineBreaks = [2]
        let restored = try JSONDecoder().decode(SubtitleTrack.self, from: JSONEncoder().encode(enriched))
        #expect(restored == enriched)
    }

    @Test func currentCasePatchKeepsTextAndMergesSourceIDs() throws {
        let (t, original) = fixture()
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/fixture.wav")
        job.result = .init(text: "Jev. My name", language: "en", words: original,
                           segments: TranscriptSegmenter.aggregate(words: original, language: "en"))
        job.editedText = "Jev. My name"
        job.subtitleTrack = .init(sourceLanguage: "en", language: "en", cues: [
            .init(id: 8, sourceIDs: [0], text: "Jev.", start: 0, end: 0.16, speaker: "Speaker 1"),
            .init(id: 9, sourceIDs: [1], text: "My", start: 0.16, end: 0.24, speaker: "Speaker 1"),
            .init(id: 10, sourceIDs: [2], text: "name", start: 0.32, end: 0.4, speaker: "Speaker 2")
        ], usesWordTimestamps: true)
        let updated = LexicalSpeakerResolver.resolving([
            original[0], .init(text: "My", start: 0.24, end: 0.32, timingQuality: .aligned), original[2]],
            timeline: t, languageCode: "en")
        let repaired = try #require(WorkbenchSpeakerBoundaryRepair.applying(to: job, words: updated,
                                      diagnostics: .init(candidateCount: 1, acceptedCount: 1)))
        #expect(repaired.result?.text == job.result?.text)
        #expect(repaired.editedText == job.editedText)
        #expect(repaired.subtitleTrack?.cues.map(\.text) == ["Jev.", "My name"])
        #expect(repaired.subtitleTrack?.cues.last?.sourceIDs == [1, 2])
        #expect(repaired.subtitleTrack?.cues.last?.speaker == "Speaker 2")
        #expect(try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: JSONEncoder().encode(repaired)).result == repaired.result)
    }
}
