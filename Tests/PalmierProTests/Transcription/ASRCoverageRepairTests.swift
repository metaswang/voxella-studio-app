import Testing
@testable import PalmierPro

@Suite("ASR coverage repair")
struct ASRCoverageRepairTests {
    @Test func retriesTheTwentySixSecondWordHoleFromWuQiToHostGreeting() throws {
        let mask = speechMask(duration: 180, alignable: [(79.9, 172.5)])
        let covered: [ASRSpeechRange] = [
            .init(start: 79.916, end: 125.644),
            .init(start: 125.884, end: 126.704),
            .init(start: 153.104, end: 172.464),
        ]

        let uncovered = ASRCoverageRepair.uncoveredSpeech(mask: mask, covered: covered)
        #expect(uncovered.count == 1)
        let hole = try #require(uncovered.first)
        #expect(hole.start > 126.5)
        #expect(hole.start < 127.2)
        #expect(hole.end > 152.6)
        #expect(hole.end < 153.2)
        #expect(hole.end - hole.start > 25)

        let retry = ASRCoverageRepair.retryRanges(from: uncovered, audioDuration: 180)
        let retryRange = try #require(retry.first)
        #expect(retry.count == 1)
        #expect(retryRange.start > 125.644)
        #expect(retryRange.start < 126.704)
        #expect(retryRange.end >= 153.104)

        let greeting = ASRSpeechRange(start: 125.884, end: 126.704)
        let physician = ASRSpeechRange(start: 124.924, end: 125.644)
        #expect(ASRCoverageRepair.overlaps(greeting, with: retry))
        #expect(!ASRCoverageRepair.overlaps(physician, with: retry))
        #expect(ASRCoverageRepair.excluding([physician, greeting], overlapping: retry) == [physician])
    }

    @Test func ignoresBreathPausesShorterThanTheRetryThreshold() {
        let mask = speechMask(duration: 20, alignable: [(0, 20)])
        let covered: [ASRSpeechRange] = [
            .init(start: 0.1, end: 4),
            .init(start: 5.16, end: 8),
            .init(start: 8.4, end: 19.8),
        ]

        let uncovered = ASRCoverageRepair.uncoveredSpeech(mask: mask, covered: covered)
        #expect(uncovered.isEmpty)
    }

    @Test func doesNotRetryMusicVetoedAudioWithoutWords() {
        let mask = speechMask(duration: 40, alignable: [(0, 10), (36, 40)])
        let covered: [ASRSpeechRange] = [
            .init(start: 0.2, end: 9.8),
            .init(start: 36.1, end: 39.5),
        ]

        let uncovered = ASRCoverageRepair.uncoveredSpeech(mask: mask, covered: covered)
        #expect(uncovered.isEmpty)
    }

    @Test func retriesAlignableSpeechWhenTheFirstPassEmittedNoWords() throws {
        let mask = speechMask(duration: 30, alignable: [(2, 28)])
        let uncovered = ASRCoverageRepair.uncoveredSpeech(mask: mask, covered: [])
        let hole = try #require(uncovered.first)
        #expect(uncovered.count == 1)
        #expect(hole.start < 2.1)
        #expect(hole.end > 27.9)
    }

    @Test func emptyMaskAndInvalidTimesDoNotTrap() {
        let empty = AlignmentSpeechMask(
            policy: AlignmentSpeechGate.Policy.standard,
            audioDuration: 0,
            isAlignableSpeech: []
        )
        #expect(ASRCoverageRepair.uncoveredSpeech(mask: empty, covered: []).isEmpty)
        #expect(
            ASRCoverageRepair.uncoveredSpeech(
                mask: speechMask(duration: 5, alignable: [(0, 5)]),
                covered: [.init(start: .nan, end: 1), .init(start: 2, end: 1)]
            ).count == 1
        )
    }

    @Test func paddedCoverageDoesNotRetryTheFortyAndOneOhFourCentisecondInternalGaps() {
        let mask = speechMask(duration: 30, alignable: [(0, 30)])
        let covered: [ASRSpeechRange] = [
            .init(start: 0.1, end: 10.0),
            .init(start: 10.40, end: 18.0),
            .init(start: 19.04, end: 29.5),
        ]

        let uncovered = ASRCoverageRepair.uncoveredSpeech(mask: mask, covered: covered)
        #expect(uncovered.isEmpty)
    }

    @Test func emptyRetryKeepsFirstPassBoundaryWords() {
        let mask = speechMask(duration: 30, alignable: [(0, 30)])
        let firstPass: [ASRSpeechRange] = [
            .init(start: 8.2, end: 9.6),
            .init(start: 9.6, end: 10.0),
            .init(start: 21.0, end: 22.4),
        ]
        let cores = [ASRSpeechRange(start: 10, end: 20)]

        #expect(
            ASRCoverageRepair.retryOutcome(
                firstPassCovered: firstPass,
                retryCovered: [],
                cores: cores,
                mask: mask
            ) == .keepFirstPass
        )
        #expect(firstPass.contains { abs($0.start - 9.6) < 1e-9 && abs($0.end - 10.0) < 1e-9 })
        #expect(firstPass.contains { abs($0.start - 21.0) < 1e-9 })
    }

    @Test func retryThatOnlyFillsTheCoreKeepsBoundaryWords() {
        let mask = speechMask(duration: 30, alignable: [(0, 30)])
        let firstPass: [ASRSpeechRange] = [
            .init(start: 8.2, end: 9.6),
            .init(start: 9.6, end: 10.0),
            .init(start: 21.0, end: 22.4),
        ]
        let cores = [ASRSpeechRange(start: 10, end: 20)]
        let retry = [ASRSpeechRange(start: 10.2, end: 19.7)]

        #expect(
            ASRCoverageRepair.retryOutcome(
                firstPassCovered: firstPass,
                retryCovered: retry,
                cores: cores,
                mask: mask
            ) == .accept
        )
        let spliced = ASRCoverageRepair.replacingCore(
            firstPassCovered: firstPass,
            retryCovered: retry,
            cores: cores
        )
        #expect(spliced.contains { $0.start <= 8.2 + 1e-9 && $0.end >= 10.0 - 1e-9 })
        #expect(spliced.contains { abs($0.start - 21.0) < 1e-9 })
        #expect(spliced.contains { abs($0.start - 10.2) < 1e-9 })
    }

    @Test func acceptedRetryReplacesOnlyTheCoreAndDropsPaddedContextDuplicates() {
        let firstPass: [ASRSpeechRange] = [
            .init(start: 8.0, end: 9.5),
            .init(start: 21.2, end: 22.0),
        ]
        let cores = [ASRSpeechRange(start: 10, end: 20)]
        let retry: [ASRSpeechRange] = [
            .init(start: 8.0, end: 9.5),
            .init(start: 10.1, end: 19.8),
            .init(start: 21.2, end: 22.0),
        ]

        let spliced = ASRCoverageRepair.replacingCore(
            firstPassCovered: firstPass,
            retryCovered: retry,
            cores: cores
        )
        #expect(spliced == [
            .init(start: 8.0, end: 9.5),
            .init(start: 10.1, end: 19.8),
            .init(start: 21.2, end: 22.0),
        ])
    }

    private func speechMask(duration: Double, alignable: [(Double, Double)]) -> AlignmentSpeechMask {
        let policy = AlignmentSpeechGate.Policy.standard
        let cellCount = max(1, Int((duration / policy.cellDuration).rounded(.up)))
        var cells = Array(repeating: false, count: cellCount)
        for (start, end) in alignable {
            guard start.isFinite, end.isFinite, end > start else { continue }
            let lower = max(0, Int((start / policy.cellDuration).rounded(.down)))
            let upper = min(cellCount - 1, Int(((end - 1e-9) / policy.cellDuration).rounded(.down)))
            if lower <= upper {
                for index in lower...upper { cells[index] = true }
            }
        }
        return AlignmentSpeechMask(
            policy: policy,
            audioDuration: duration,
            isAlignableSpeech: cells
        )
    }
}
