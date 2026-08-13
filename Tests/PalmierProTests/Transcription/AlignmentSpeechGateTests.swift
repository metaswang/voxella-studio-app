import Testing
@testable import PalmierPro

@Suite("Alignment speech gate")
struct AlignmentSpeechGateTests {
    private let sampleRate = 16_000

    @Test func trimsLeadingSileroNegativeAudio() {
        let samples = tone(duration: 10, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 2, endTime: 9)]
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start >= 2 - AlignmentSpeechGate.Policy.standard.pad - AlignmentSpeechGate.Policy.standard.cellDuration)
        #expect(slice.start > 0.5)
        #expect(slice.end <= 9 + AlignmentSpeechGate.Policy.standard.pad + AlignmentSpeechGate.Policy.standard.cellDuration)
        #expect(slice.end < 9.5)
    }

    @Test func trimsLeadingQuietBedInsideSileroSpeech() {
        let samples = tone(duration: 2, amplitude: 0.0004) + tone(duration: 8, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)]
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start >= 2 - AlignmentSpeechGate.Policy.standard.pad - 0.05)
        #expect(slice.start > 1.5)
    }

    @Test func keepsLoudSpokenAudioWhenSceneIsSpeech() {
        let samples = tone(duration: 10, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)],
            sceneClassifier: StubSoundSceneClassifier(windows: [
                .init(
                    startTime: 0,
                    endTime: 10,
                    speechConfidence: 0.9,
                    musicOrSingingConfidence: 0.1,
                    topLabel: "speech",
                    topConfidence: 0.9
                ),
            ])
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start <= AlignmentSpeechGate.Policy.standard.pad)
        #expect(slice.end >= 10 - AlignmentSpeechGate.Policy.standard.pad)
    }

    @Test func splitsLoudJingleWhenSceneIsMusicWithoutSpeech() {
        let samples = tone(duration: 10, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)],
            sceneClassifier: StubSoundSceneClassifier(windows: [
                .init(
                    startTime: 0,
                    endTime: 4,
                    speechConfidence: 0.05,
                    musicOrSingingConfidence: 0.9,
                    topLabel: "singing",
                    topConfidence: 0.9
                ),
                .init(
                    startTime: 4,
                    endTime: 10,
                    speechConfidence: 0.8,
                    musicOrSingingConfidence: 0.1,
                    topLabel: "speech",
                    topConfidence: 0.8
                ),
            ])
        )
        let split = AlignmentSpeechGate.splitIntervals(
            [.init(startTime: 0, endTime: 10)],
            mask: mask
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(split.count == 1)
        #expect(split[0].startTime >= 3.9)
        #expect(slice.start >= 4 - AlignmentSpeechGate.Policy.standard.pad - 0.05)
    }

    @Test func keepsSpeechOverMusicBed() {
        let samples = tone(duration: 10, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)],
            sceneClassifier: StubSoundSceneClassifier(windows: [
                .init(
                    startTime: 0,
                    endTime: 10,
                    speechConfidence: 0.6,
                    musicOrSingingConfidence: 0.8,
                    topLabel: "music",
                    topConfidence: 0.8
                ),
            ])
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start <= AlignmentSpeechGate.Policy.standard.pad)
    }

    @Test func sceneClassifierFailureFallsBackToEnergyGate() {
        let samples = tone(duration: 10, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)],
            sceneClassifier: StubSoundSceneClassifier(error: StubSoundSceneError.failed)
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start <= AlignmentSpeechGate.Policy.standard.pad)
    }

    @Test func splitsInteriorPauseAtLeastMinInteriorPause() {
        let samples = tone(duration: 4, amplitude: 0.1)
            + tone(duration: 0.4, amplitude: 0.0002)
            + tone(duration: 5.6, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)]
        )
        let split = AlignmentSpeechGate.splitIntervals(
            [.init(startTime: 0, endTime: 10)],
            mask: mask
        )

        #expect(split.count == 2)
        #expect(split[0].endTime <= 4.1)
        #expect(split[1].startTime >= 4.3)
    }

    @Test func doesNotSplitShortInteriorPause() {
        let samples = tone(duration: 4, amplitude: 0.1)
            + tone(duration: 0.15, amplitude: 0.0002)
            + tone(duration: 5.85, amplitude: 0.1)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 0, endTime: 10)]
        )
        let split = AlignmentSpeechGate.splitIntervals(
            [.init(startTime: 0, endTime: 10)],
            mask: mask
        )

        #expect(split.count == 1)
        #expect(split[0].startTime == 0)
        #expect(split[0].endTime == 10)
    }

    @Test func abortsTrimWhenRemainingAudioIsTooShort() {
        let samples = tone(duration: 10, amplitude: 0.0002)
        let mask = AlignmentSpeechGate.mask(
            samples: samples,
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: 4.9, endTime: 5.05)]
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: 0,
            spanEnd: 10,
            contextDuration: 0.5,
            audioDuration: 10,
            mask: mask
        )

        #expect(slice.start == 0)
        #expect(slice.end == 10)
    }

    @Test func emptyInputsDoNotTrap() {
        let mask = AlignmentSpeechGate.mask(
            samples: [],
            sampleRate: sampleRate,
            speechIntervals: [.init(startTime: .nan, endTime: 1)]
        )
        let split = AlignmentSpeechGate.splitIntervals(
            [.init(startTime: .infinity, endTime: 1), .init(startTime: 0, endTime: 0)],
            mask: mask
        )
        let slice = AlignmentSpeechGate.trimmedAlignmentSlice(
            spanStart: .nan,
            spanEnd: .infinity,
            contextDuration: .nan,
            audioDuration: 0,
            mask: mask
        )

        #expect(mask.isAlignableSpeech.isEmpty)
        #expect(split.isEmpty)
        #expect(slice.start == 0)
        #expect(slice.end == 0)
    }

    private func tone(duration: Double, amplitude: Float) -> [Float] {
        let count = max(0, Int((duration * Double(sampleRate)).rounded()))
        return Array(repeating: amplitude, count: count)
    }
}

private struct StubSoundSceneClassifier: AlignmentSoundSceneClassifying {
    var windows: [AlignmentSoundSceneWindow] = []
    var error: Error?

    func classifySoundScenes(
        samples: [Float],
        sampleRate: Int,
        ranges: [ClosedRange<Double>]
    ) throws -> [AlignmentSoundSceneWindow] {
        if let error { throw error }
        return windows
    }
}

private enum StubSoundSceneError: Error {
    case failed
}
