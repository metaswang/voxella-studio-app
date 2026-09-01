import Foundation
import Testing
@testable import PalmierPro

@Suite("Diarization speech packing")
struct DiarizationSpeechPackerTests {
    @Test func checkpointStreamingParametersMatchOfflineConfig() {
        let parameters = SortformerStreamingParameters.from(
            hopLength: 160,
            subsamplingFactor: 8,
            samplingRate: 16_000,
            chunkLen: 188,
            spkcacheLen: 188,
            fifoLen: 0
        )

        #expect(abs(parameters.frameDuration - 0.08) < 0.000_001)
        #expect(abs(parameters.chunkDuration - 15.04) < 0.000_001)
        #expect(parameters.spkcacheMax == 188)
        #expect(parameters.fifoMax == 0)
    }

    @Test func packerMergesShortGapsIntoOneWindow() {
        let sampleRate = 10
        let audio = [Float](repeating: 1, count: 100)
        let pack = DiarizationSpeechPacker.pack(
            audio: audio,
            sampleRate: sampleRate,
            speechRanges: [
                SpeechTimeRange(start: 1, end: 2),
                SpeechTimeRange(start: 2.5, end: 3.5),
            ],
            audioDuration: 10
        )

        #expect(!pack.usedIdentity)
        #expect(pack.mappings.count == 1)
        #expect(abs(pack.mappings[0].originalStart - 1) < 0.000_001)
        #expect(abs(pack.mappings[0].concatStart) < 0.000_001)
        #expect(pack.samples.count == 25)
        #expect(pack.samples.allSatisfy { $0 == 1 })
    }

    @Test func packerInsertsPadBetweenDistantWindows() {
        let sampleRate = 10
        let audio = [Float](repeating: 1, count: 100)
        let pack = DiarizationSpeechPacker.pack(
            audio: audio,
            sampleRate: sampleRate,
            speechRanges: [
                SpeechTimeRange(start: 1, end: 2),
                SpeechTimeRange(start: 5, end: 6),
            ],
            audioDuration: 10
        )

        let padSamples = Int((DiarizationSpeechPacker.interWindowPad * Double(sampleRate)).rounded())
        #expect(!pack.usedIdentity)
        #expect(pack.mappings.count == 2)
        #expect(pack.samples.count == 20 + padSamples)
        #expect(pack.samples.prefix(10).allSatisfy { $0 == 1 })
        #expect(pack.samples.suffix(10).allSatisfy { $0 == 1 })
        #expect(pack.samples.dropFirst(10).prefix(padSamples).allSatisfy { $0 == 0 })
        #expect(abs(pack.mappings[1].concatStart - (1 + DiarizationSpeechPacker.interWindowPad)) < 0.000_001)
        #expect(abs(pack.coverage - 0.2) < 0.000_001)
    }

    @Test func highCoverageUsesIdentityWithoutCopyingSilenceOut() {
        let audio = [Float](repeating: 0.5, count: 100)
        let pack = DiarizationSpeechPacker.pack(
            audio: audio,
            sampleRate: 10,
            speechRanges: [SpeechTimeRange(start: 0.1, end: 9.95)],
            audioDuration: 10
        )

        #expect(pack.usedIdentity)
        #expect(pack.samples.count == audio.count)
        #expect(pack.processedAudioDuration == 10)
        #expect(pack.mappings.count == 1)
        #expect(pack.mappings[0].originalStart == 0)
        #expect(pack.mappings[0].originalEnd == 10)
    }

    @Test func emptyRangesUseIdentityOfFullAudio() {
        let audio = [Float](repeating: 0.25, count: 40)
        let pack = DiarizationSpeechPacker.pack(
            audio: audio,
            sampleRate: 10,
            speechRanges: [],
            audioDuration: 4
        )

        #expect(pack.usedIdentity)
        #expect(pack.samples.count == 40)
        #expect(pack.speechDuration == 0)
        #expect(pack.coverage == 0)
    }

    @Test func scatterWritesConcatFramesBackToOriginalTime() {
        let pack = DiarizationSpeechPack(
            samples: [Float](repeating: 1, count: 10),
            mappings: [
                DiarizationSpeechMapping(
                    concatStart: 0,
                    concatEnd: 1,
                    originalStart: 2,
                    originalEnd: 3
                ),
            ],
            speechDuration: 1,
            processedAudioDuration: 1,
            coverage: 0.25,
            usedIdentity: false
        )
        let concat: [Float] = [0.9, 0.1, 0.8, 0.2]
        let scattered = DiarizationSpeechPacker.scatterProbabilities(
            concatProbabilities: concat,
            speakerCapacity: 2,
            frameDuration: 0.5,
            pack: pack,
            audioDuration: 4
        )

        #expect(scattered.count == 16)
        #expect(scattered[8...11] == [0.9, 0.1, 0.8, 0.2][...])
        #expect(scattered.prefix(8).allSatisfy { $0 == 0 })
        #expect(scattered.suffix(4).allSatisfy { $0 == 0 })
    }

    @Test func scatterLeavesPadAndLongSilenceAtZero() {
        let pad = DiarizationSpeechPacker.interWindowPad
        let pack = DiarizationSpeechPack(
            samples: [],
            mappings: [
                DiarizationSpeechMapping(
                    concatStart: 0,
                    concatEnd: 1,
                    originalStart: 1,
                    originalEnd: 2
                ),
                DiarizationSpeechMapping(
                    concatStart: 1 + pad,
                    concatEnd: 2 + pad,
                    originalStart: 5,
                    originalEnd: 6
                ),
            ],
            speechDuration: 2,
            processedAudioDuration: 2 + pad,
            coverage: 0.2,
            usedIdentity: false
        )
        let concatFrameCount = Int(((2 + pad) / 0.5).rounded(.up))
        let concat = [Float](repeating: 0.7, count: concatFrameCount)
        let scattered = DiarizationSpeechPacker.scatterProbabilities(
            concatProbabilities: concat,
            speakerCapacity: 1,
            frameDuration: 0.5,
            pack: pack,
            audioDuration: 10
        )

        #expect(scattered.count == 20)
        #expect(scattered[2] > 0)
        #expect(scattered[3] > 0)
        #expect(scattered[10] > 0)
        #expect(scattered[11] > 0)
        #expect(scattered[6] == 0)
        #expect(scattered[7] == 0)
        #expect(scattered[8] == 0)
        #expect(scattered[9] == 0)
    }

    @Test func identityScatterKeepsConcatProbabilities() {
        let pack = DiarizationSpeechPacker.pack(
            audio: [Float](repeating: 1, count: 20),
            sampleRate: 10,
            speechRanges: [SpeechTimeRange(start: 0, end: 2)],
            audioDuration: 2
        )
        let concat: [Float] = [0.2, 0.8, 0.3, 0.7]
        let scattered = DiarizationSpeechPacker.scatterProbabilities(
            concatProbabilities: concat,
            speakerCapacity: 2,
            frameDuration: 0.5,
            pack: pack,
            audioDuration: 2
        )
        #expect(pack.usedIdentity)
        #expect(scattered == concat)
    }
}
