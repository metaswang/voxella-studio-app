import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Speaker voiceprints")
struct SpeakerVoiceprintTests {
    private func unit(_ index: Int, dimension: Int = 8, tilt: Float = 0) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[index] = 1
        vector[(index + 1) % dimension] = tilt
        return vector
    }

    @Test func aggregateWeightsByEffectiveDuration() throws {
        let print = try #require(SpeakerVoiceprintPolicy.aggregate([
            .init(vector: unit(0), duration: 9),
            .init(vector: unit(0, tilt: 0.2), duration: 1),
        ], version: "v"))
        #expect(print.effectiveDuration == 10)
        #expect(print.segmentCount == 2)
        #expect(print.quality == .ready)
        let norm = print.vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-5)
        #expect(print.vector[0] > print.vector[1] * 10)
    }

    @Test func enrollmentNeedsThreeSecondsOfSpeech() {
        let short = SpeakerVoiceprintPolicy.aggregate(
            [.init(vector: unit(0), duration: 2.9)], version: "v",
            minimumDuration: SpeakerVoiceprintPolicy.minimumEnrollmentDuration
        )
        #expect(short == nil)
        let enough = SpeakerVoiceprintPolicy.aggregate(
            [.init(vector: unit(0), duration: 1.5), .init(vector: unit(0), duration: 1.5)], version: "v",
            minimumDuration: SpeakerVoiceprintPolicy.minimumEnrollmentDuration
        )
        #expect(enough != nil)
    }

    @Test func mixedSpeakersAreFlaggedForReview() throws {
        let print = try #require(SpeakerVoiceprintPolicy.aggregate([
            .init(vector: unit(0), duration: 5),
            .init(vector: unit(0), duration: 5),
            .init(vector: unit(4), duration: 5),
        ], version: "v"))
        #expect(print.quality == .needsReview)
        #expect(print.consistency < SpeakerVoiceprintPolicy.consistencyFloor)
    }

    @Test func degenerateSegmentsAreIgnored() {
        let zero = [Float](repeating: 0, count: 8)
        let nan = [Float](repeating: .nan, count: 8)
        #expect(SpeakerVoiceprintPolicy.aggregate([.init(vector: zero, duration: 5)], version: "v") == nil)
        #expect(SpeakerVoiceprintPolicy.aggregate([.init(vector: nan, duration: 5)], version: "v") == nil)
        #expect(SpeakerVoiceprintPolicy.aggregate([], version: "v") == nil)
        // Mismatched dimensions cannot be averaged.
        #expect(SpeakerVoiceprintPolicy.aggregate(
            [.init(vector: unit(0), duration: 5), .init(vector: [1, 0], duration: 5)], version: "v"
        ) == nil)
        #expect(SpeakerVoiceprintPolicy.cosine([1, 0], [1, 0, 0]) == 0)
    }

    @Test func windowsSplitLongRangesAndDropShortOnes() {
        let windows = SpeakerVoiceprintPolicy.windows(for: [
            .init(start: 0, end: 20),
            .init(start: 30, end: 30.9),
        ])
        #expect(windows.allSatisfy { $0.end - $0.start <= SpeakerVoiceprintPolicy.maximumWindow + 1e-9 })
        #expect(windows.allSatisfy { $0.end - $0.start >= SpeakerVoiceprintPolicy.minimumWindow })
        #expect(windows.allSatisfy { $0.start >= 0.1 && $0.end <= 19.9 })
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.start < $1.start })
        let capped = SpeakerVoiceprintPolicy.windows(for: [.init(start: 0, end: 400)], limit: 20)
        #expect(capped.reduce(0) { $0 + $1.end - $1.start } <= 20 + SpeakerVoiceprintPolicy.maximumWindow)
    }

    @Test func enrollmentSpeechRangesBridgeShortPauses() {
        let rate = 16_000.0
        func tone(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        }
        let audio = tone(2) + [Float](repeating: 0, count: Int(0.2 * rate)) + tone(1)
            + [Float](repeating: 0, count: Int(1 * rate)) + tone(1.5)
        let ranges = SpeakerEnrollmentAudio.speechRanges(samples: audio, sampleRate: rate)
        #expect(ranges.count == 2)
        #expect(abs((ranges.first?.end ?? 0) - 3.2) < 0.1)
        #expect(SpeakerEnrollmentAudio.speechRanges(samples: [Float](repeating: 0, count: 16_000), sampleRate: rate).isEmpty)
    }
}

@Suite("Speaker identity matching")
struct SpeakerIdentityMatcherTests {
    private let calibration = SpeakerMatchCalibration(
        acceptThreshold: 0.6, minimumMargin: 0.1, minimumEvidence: 2, version: "test"
    )
    private let alice = UUID()
    private let bob = UUID()

    private func print(_ vector: [Float], duration: Double = 10, quality: SpeakerVoiceprint.Quality = .ready) -> SpeakerVoiceprint {
        SpeakerVoiceprint(
            vector: SpeakerVoiceprintPolicy.normalized(vector)!, effectiveDuration: duration,
            segmentCount: 3, consistency: quality == .ready ? 0.9 : 0.2, quality: quality, version: "e"
        )
    }

    private var candidates: [SpeakerMatchCandidate] {
        [
            .init(personID: alice, name: "Alice", voiceprint: print([1, 0, 0, 0])),
            .init(personID: bob, name: "Bob", voiceprint: print([0, 1, 0, 0])),
        ]
    }

    @Test func clearMatchesAreNamedAndUnknownVoicesStayAnonymous() {
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([0.95, 0.1, 0.05, 0]), overlapsWith: []),
            .init(label: "Speaker 2", voiceprint: print([0, 0, 1, 0]), overlapsWith: []),
        ], candidates: candidates, calibration: calibration)
        #expect(decisions[0].status == .matched)
        #expect(decisions[0].personID == alice)
        #expect(decisions[0].nameSnapshot == "Alice")
        #expect(decisions[1].status == .unknown)
        #expect(decisions[1].personID == nil)
    }

    @Test func closeCandidatesAreAmbiguous() {
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([0.7, 0.68, 0, 0]), overlapsWith: []),
        ], candidates: candidates, calibration: calibration)
        #expect(decisions[0].status == .ambiguous)
        #expect(decisions[0].personID == nil)
    }

    @Test func nonOverlappingLabelsMayShareAPerson() {
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([1, 0.05, 0, 0]), overlapsWith: []),
            .init(label: "Speaker 3", voiceprint: print([0.98, 0, 0.1, 0]), overlapsWith: []),
        ], candidates: candidates, calibration: calibration)
        #expect(decisions.allSatisfy { $0.status == .matched && $0.personID == alice })
    }

    @Test func simultaneousLabelsCannotBeTheSamePerson() {
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([1, 0.05, 0, 0]), overlapsWith: ["Speaker 2"]),
            .init(label: "Speaker 2", voiceprint: print([0.9, 0, 0.2, 0]), overlapsWith: ["Speaker 1"]),
        ], candidates: candidates, calibration: calibration)
        #expect(decisions[0].status == .matched)
        #expect(decisions[0].personID == alice)
        #expect(decisions[1].status == .conflict)
        #expect(decisions[1].personID == nil)
    }

    @Test func shortOrMixedEvidenceIsNeverNamed() {
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([1, 0, 0, 0], duration: 1), overlapsWith: []),
            .init(label: "Speaker 2", voiceprint: print([0, 1, 0, 0], quality: .needsReview), overlapsWith: []),
            .init(label: "Speaker 3", voiceprint: nil, overlapsWith: []),
        ], candidates: candidates, calibration: calibration)
        #expect(decisions.map(\.status) == [.insufficientEvidence, .needsReview, .insufficientEvidence])
        #expect(decisions.allSatisfy { $0.personID == nil })
    }

    @Test func voiceprintsFromAnotherEmbeddingVersionAreNotCompared() {
        var stale = candidates
        stale[0].voiceprint.version = "old"
        let decisions = SpeakerIdentityMatcher.match(channels: [
            .init(label: "Speaker 1", voiceprint: print([1, 0, 0, 0]), overlapsWith: []),
        ], candidates: [stale[0]], calibration: calibration)
        #expect(decisions[0].status == .unknown)
    }

    @Test func calibrationMeetsTheFalseNameTargetAndReportsIntervals() throws {
        var trials: [SpeakerMatchCalibration.Trial] = []
        for index in 0..<300 {
            let score = 0.55 + Double(index % 40) / 100
            trials.append(.init(bestScore: score, margin: 0.2, isCorrect: true, personEnrolled: true))
        }
        for index in 0..<100 {
            let score = 0.3 + Double(index % 35) / 100
            trials.append(.init(bestScore: score, margin: 0.05, isCorrect: false, personEnrolled: false))
        }
        let report = try #require(SpeakerMatchCalibration.calibrate(trials: trials, version: "cal"))
        #expect(report.falseNameRate <= 0.01)
        #expect(report.recall > 0.9)
        #expect(report.recallInterval.lowerBound <= report.recall && report.recall <= report.recallInterval.upperBound)
        #expect(report.falseNameRateUpper >= report.falseNameRate)
        #expect(report.trialCount == 400)
        #expect(SpeakerMatchCalibration.current.acceptThreshold > 0.45)
    }
}

@Suite("Speaker evidence")
struct SpeakerEvidenceBuilderTests {
    private func timeline(_ intervals: [SpeakerActivityInterval]) -> SpeakerActivityTimeline {
        SpeakerActivityTimeline(
            intervals: intervals, probabilities: [], frameDuration: 0, speakerCapacity: 8, audioDuration: 30,
            diagnostics: .init(backend: .nemotron3, elapsedSeconds: 0, processedChunks: 1,
                               detectedSpeakerCount: 2, requestedSpeakerCount: nil, warnings: [])
        )
    }

    @Test func subtractRemovesOverlappedSpeech() {
        let pieces = SpeakerEvidenceBuilder.subtract(
            .init(start: 0, end: 10), [.init(start: 2, end: 3), .init(start: 8, end: 12)]
        )
        #expect(pieces == [.init(start: 0, end: 2), .init(start: 3, end: 8)])
    }

    @Test func evidenceUsesFinalLabelsAndRecordsOverlap() throws {
        let intervals = [
            SpeakerActivityInterval(start: 0, end: 10, speakerID: 3, confidence: 0.9),
            SpeakerActivityInterval(start: 9, end: 20, speakerID: 5, confidence: 0.9),
        ]
        let words = [
            TranscriptionWord(text: "hi", start: 1, end: 2, speaker: "Speaker 1"),
            TranscriptionWord(text: "there", start: 3, end: 4, speaker: "Speaker 1"),
            TranscriptionWord(text: "yes", start: 12, end: 13, speaker: "Speaker 2"),
        ]
        let evidence = SpeakerEvidenceBuilder.build(timeline: timeline(intervals), words: words)
        #expect(evidence.map(\.label) == ["Speaker 1", "Speaker 2"])
        let first = try #require(evidence.first)
        #expect(first.cleanRanges == [.init(start: 0, end: 9)])
        #expect(first.overlapsWith == ["Speaker 2"])
        #expect(abs(first.activeDuration - 10) < 1e-9)
        #expect(evidence[1].cleanRanges == [.init(start: 10, end: 20)])
    }

    @Test func timelinesWithoutActivityGiveNoEvidence() {
        var unavailable = timeline([.init(start: 0, end: 5, speakerID: 0, confidence: 1)])
        unavailable = SpeakerActivityTimeline(
            intervals: unavailable.intervals, probabilities: [], frameDuration: 0, speakerCapacity: 1,
            audioDuration: 5, diagnostics: .init(backend: .singleSpeaker, elapsedSeconds: 0, processedChunks: 0,
                                                 detectedSpeakerCount: 1, requestedSpeakerCount: 1, warnings: [])
        )
        #expect(SpeakerEvidenceBuilder.build(timeline: unavailable, words: []).isEmpty)
    }
}

@Suite("Speaker options and identity persistence")
struct SpeakerIdentityPersistenceTests {
    @Test func speakerCountSupportsOneToEight() {
        #expect(SpeakerCountOption.allCases.compactMap(\.count).filter { $0 > 0 } == Array(1...8))
        #expect(SpeakerCountOption.off.count == 0)
        #expect(SpeakerCountOption.auto.count == nil)
        #expect(SpeakerCountOption(rawValue: "eight")?.count == 8)
    }

    @Test func jobRoundTripsCandidatesAndIdentities() throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/a.wav")
        let person = UUID()
        job.candidatePersonIDs = [person]
        job.speakerIdentities = SessionSpeakerIdentities(entries: [
            .init(anonymousLabel: "Speaker 2", displayLabel: "Alice", personID: person,
                  nameSnapshot: "Alice", status: .matched, score: 0.81, margin: 0.3),
        ], matchKey: "k")
        let decoded = try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.candidatePersonIDs == [person])
        #expect(decoded.speakerIdentities == job.speakerIdentities)
        #expect(decoded.speakerIdentities?.entry(displayLabel: "Alice")?.anonymousLabel == "Speaker 2")
    }

    @Test func legacyJobsDecodeWithoutIdentityFields() throws {
        let job = WorkbenchTranscriptionJob(sourcePath: "/tmp/a.wav")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        object.removeValue(forKey: "candidatePersonIDs")
        object.removeValue(forKey: "speakerIdentities")
        object["speakerCount"] = "four"
        let decoded = try JSONDecoder().decode(
            WorkbenchTranscriptionJob.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.candidatePersonIDs.isEmpty)
        #expect(decoded.speakerIdentities == nil)
        #expect(decoded.speakerCount == .four)
    }

    @Test func diagnosticsKeepEvidenceThroughWarnings() throws {
        var diagnostics = DiarizationDiagnostics(
            backend: .nemotron3, elapsedSeconds: 1, processedChunks: 1, detectedSpeakerCount: 1,
            requestedSpeakerCount: nil, warnings: []
        )
        diagnostics.speakerEvidence = [.init(label: "Speaker 1", cleanRanges: [.init(start: 0, end: 4)],
                                             activeDuration: 4, overlapsWith: [])]
        let warned = diagnostics.addingWarning("w")
        #expect(warned.speakerEvidence == diagnostics.speakerEvidence)
        let decoded = try JSONDecoder().decode(DiarizationDiagnostics.self, from: JSONEncoder().encode(warned))
        #expect(decoded.speakerEvidence?.first?.cleanDuration == 4)
    }

    @Test func wordTurnsProvideEvidenceForOlderTranscripts() {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/a.wav")
        let result = TranscriptionResult(text: "a b c", language: "en", words: [
            .init(text: "a", start: 0, end: 1.5, speaker: "Speaker 1"),
            .init(text: "b", start: 1.6, end: 3, speaker: "Speaker 1"),
            .init(text: "c", start: 5, end: 5.4, speaker: "Speaker 2"),
        ], segments: [])
        job.result = result
        let evidence = WorkbenchStore.speakerEvidence(for: job, result: result)
        #expect(evidence.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(evidence[0].cleanRanges == [.init(start: 0, end: 3)])
        #expect(evidence[1].cleanRanges.isEmpty)
    }
}
