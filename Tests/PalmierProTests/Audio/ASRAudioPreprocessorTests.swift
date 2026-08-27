import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("ASR audio preprocessing")
struct ASRAudioPreprocessorTests {
    @Test func lowLevelSpeechReceivesBoundedGainWithoutClipping() {
        let amplitude = Float(pow(10, -45.0 / 20.0))
        let result = ASRAudioPreprocessor.prepare(samples: Array(repeating: amplitude, count: 16_000))

        #expect(result.original.rmsDBFS < -44)
        #expect(result.didApplyGain)
        #expect(result.appliedGainDB <= ASRAudioPreprocessor.maximumGainDB)
        #expect(result.processed.peakDBFS <= ASRAudioPreprocessor.targetPeakDBFS + 0.1)
        #expect(result.samples.allSatisfy { abs($0) <= 1 })
    }

    @Test func silenceIsNotAmplified() {
        let result = ASRAudioPreprocessor.prepare(samples: Array(repeating: 0, count: 16_000))

        #expect(result.original.isEffectivelySilent)
        #expect(!result.didApplyGain)
        #expect(result.samples.allSatisfy { $0 == 0 })
    }

    @Test func healthyLevelIsLeftUnchanged() {
        let amplitude = Float(pow(10, -12.0 / 20.0))
        let samples = Array(repeating: amplitude, count: 16_000)
        let result = ASRAudioPreprocessor.prepare(samples: samples)

        #expect(!result.didApplyGain)
        #expect(result.samples == samples)
    }

    @Test func recordingDiagnosticsWarnForLowTracksOnly() {
        let low = RecordingAudioLevel(duration: 2, rmsDBFS: -45, peakDBFS: -32)
        let healthy = RecordingAudioLevel(duration: 2, rmsDBFS: -20, peakDBFS: -6)

        #expect(
            RecordingSessionDiagnostics(microphone: low, systemAudio: healthy).warningMessage == nil
        )
        #expect(
            RecordingSessionDiagnostics(microphone: healthy, systemAudio: low).warningMessage == nil
        )
        #expect(
            RecordingSessionDiagnostics(microphone: low, systemAudio: nil).warningMessage
                == "The recording level was low for microphone. Move closer to the microphone or raise the source volume before recording again."
        )
        #expect(
            RecordingSessionDiagnostics(microphone: low, systemAudio: low).warningMessage
                == "The recording level was low for microphone and system audio. Move closer to the microphone or raise the source volume before recording again."
        )
    }

    @Test func liveRecordingWarningIdentifiesItsTrack() {
        let level = RecordingAudioLevel(duration: 3, rmsDBFS: -45, peakDBFS: -30)
        let warning = RecordingAudioLevelWarning(track: .microphone, level: level)

        #expect(warning.message.contains("microphone"))
        #expect(warning.level == level)
    }

    @Test func transcodesNarrowMicrophonePCMWithoutTurningItIntoNoise() throws {
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let frames: AVAudioFrameCount = 1_600
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        input.frameLength = frames
        let channel = try #require(input.floatChannelData?[0])
        let amplitude: Float = 0.5
        for index in 0..<Int(frames) {
            channel[index] = amplitude * sin(2 * Float.pi * 440 * Float(index) / 16_000)
        }

        let transcoder = RecordingAudioTranscoder()
        let output = try #require(transcoder.resample(input))
        #expect(output.format.sampleRate == RecordingAudioTranscoder.sampleRate)
        #expect(output.format.channelCount == RecordingAudioTranscoder.channels)
        #expect(!output.format.isInterleaved)
        #expect(output.frameLength > 3_200)
        #expect(output.frameLength < 6_400)

        let left = try #require(output.floatChannelData?[0])
        var sumSquares = 0.0
        var peak = 0.0
        var zeroCrossings = 0
        let count = Int(output.frameLength)
        for index in 0..<count {
            let sample = Double(left[index])
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
            if index > 0, (left[index] >= 0) != (left[index - 1] >= 0) {
                zeroCrossings += 1
            }
        }
        let rms = sqrt(sumSquares / Double(count))
        let zeroCrossingRate = Double(zeroCrossings) * RecordingAudioTranscoder.sampleRate / Double(max(count - 1, 1))
        #expect(rms > 0.2)
        #expect(rms < 0.5)
        #expect(peak > 0.3)
        #expect(peak < 0.7)
        #expect(zeroCrossingRate > 200)
        #expect(zeroCrossingRate < 1_200)
    }

    @Test func transcodesSuccessiveMicrophoneBuffersOnTheSameConverter() throws {
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let frames: AVAudioFrameCount = 1_600
        func tone() throws -> AVAudioPCMBuffer {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
            input.frameLength = frames
            let channel = try #require(input.floatChannelData?[0])
            for index in 0..<Int(frames) {
                channel[index] = 0.5 * sin(2 * Float.pi * 440 * Float(index) / 16_000)
            }
            return input
        }

        let transcoder = RecordingAudioTranscoder()
        let first = try #require(transcoder.resample(try tone()))
        let second = try #require(transcoder.resample(try tone()))
        #expect(first.frameLength > 3_200)
        #expect(second.frameLength > 3_200)
        #expect(second.frameLength == first.frameLength)
        let left = try #require(second.floatChannelData?[0])
        var peak = 0.0
        for index in 0..<Int(second.frameLength) {
            peak = max(peak, abs(Double(left[index])))
        }
        #expect(peak > 0.3)
    }
}
