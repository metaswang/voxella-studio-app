import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Recording audio level")
struct RecordingAudioLevelTests {
    @Test func pausesDoNotDiluteAudibleSpeechIntoALowLevelWarning() throws {
        var meter = RecordingAudioLevelMeter()
        _ = try append(seconds: 2, rmsDBFS: nil, to: &meter)
        for _ in 0..<4 {
            _ = try append(seconds: 0.4, rmsDBFS: -33, to: &meter)
            _ = try append(seconds: 0.4, rmsDBFS: -48, to: &meter)
        }
        _ = try append(seconds: 4, rmsDBFS: nil, to: &meter)
        let level = try #require(meter.snapshot)
        #expect(level.rmsDBFS < -40)
        #expect(try #require(level.activeRMSDBFS) > -40)
        #expect(!level.isLowLevel)
        #expect(RecordingSessionDiagnostics(microphone: level, systemAudio: nil).warningMessage == nil)
    }

    @Test func speechRemainsHealthyAfterLongSilence() throws {
        var meter = RecordingAudioLevelMeter()
        _ = try append(seconds: 0.6, rmsDBFS: -30, to: &meter)
        for _ in 0..<30 { _ = try append(seconds: 1, rmsDBFS: nil, to: &meter) }
        let level = try #require(meter.snapshot)
        #expect(level.rmsDBFS < -40)
        #expect(!level.isLowLevel)
    }

    @Test func liveWarningClearsOnRecoveryAndCanWarnAgain() throws {
        var meter = RecordingAudioLevelMeter()
        let low = try append(seconds: 8, rmsDBFS: -46, to: &meter)
        #expect(low.warningLevel?.isLowLevel == true)
        #expect(!low.didRecoverLevel)
        #expect(try append(seconds: 0.2, rmsDBFS: -20, to: &meter).didRecoverLevel == false)
        let recovered = try append(seconds: 0.4, rmsDBFS: -20, to: &meter)
        #expect(recovered.warningLevel == nil)
        #expect(recovered.didRecoverLevel)
        #expect(try append(seconds: 8, rmsDBFS: -46, to: &meter).warningLevel?.isLowLevel == true)
    }

    @Test func shortStartupSilenceDoesNotWarn() throws {
        var meter = RecordingAudioLevelMeter()
        #expect(try append(seconds: 3, rmsDBFS: nil, to: &meter).warningLevel == nil)
        #expect(try append(seconds: 2, rmsDBFS: -28, to: &meter).warningLevel == nil)
        #expect(try append(seconds: 3, rmsDBFS: nil, to: &meter).warningLevel == nil)
        #expect(meter.snapshot?.isLowLevel == false)
    }

    @Test func silenceAndSustainedQuietSpeechStillWarn() throws {
        for rms in [nil, -46.0, -55.0] as [Double?] {
            var meter = RecordingAudioLevelMeter()
            #expect(try append(seconds: 8, rmsDBFS: rms, to: &meter).warningLevel != nil)
            let level = try #require(meter.snapshot)
            #expect(level.isLowLevel)
            #expect(RecordingSessionDiagnostics(microphone: level, systemAudio: nil).warningMessage != nil)
        }
    }

    @Test func singleClickDoesNotHideSilentRecording() throws {
        var meter = RecordingAudioLevelMeter()
        _ = try append(seconds: 0.1, rmsDBFS: -6, to: &meter)
        _ = try append(seconds: 5, rmsDBFS: nil, to: &meter)
        #expect(meter.snapshot?.isLowLevel == true)
    }

    @Test func veryShortRecordingDoesNotClaimTheMicrophoneIsTooQuiet() throws {
        var meter = RecordingAudioLevelMeter()
        _ = try append(seconds: 2, rmsDBFS: nil, to: &meter)
        #expect(meter.snapshot?.isLowLevel == false)
    }

    @Test func silentStereoChannelDoesNotLowerTheActiveChannelLevel() throws {
        var meter = RecordingAudioLevelMeter()
        let pcm = try tone(seconds: 4, rmsDBFS: -38, channels: 2, silentFirstChannel: true)
        let sample = try #require(RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: .zero))
        let tick = meter.append(sample)
        #expect(tick != nil)
        let level = try #require(meter.snapshot)
        #expect(level.rmsDBFS < -40)
        #expect(abs(try #require(level.activeRMSDBFS) + 38) < 0.01)
        #expect(!level.isLowLevel)
    }

    @Test(arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32])
    func interleavedStereoUsesTheChannelStride(_ format: AVAudioCommonFormat) throws {
        var meter = RecordingAudioLevelMeter()
        let pcm = try tone(seconds: 4, rmsDBFS: -38, channels: 2, interleaved: true,
                           commonFormat: format, silentFirstChannel: true)
        let sample = try #require(RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: .zero))
        let tick = meter.append(sample)
        _ = try #require(tick)
        let level = try #require(meter.snapshot)
        #expect(abs(try #require(level.activeRMSDBFS) + 38) < 0.05)
        #expect(!level.isLowLevel)
    }

    @Test func durationSurvivesSampleRateChangesAndSmallBuffers() throws {
        var meter = RecordingAudioLevelMeter()
        let first = try tone(seconds: 2, rmsDBFS: -30, sampleRate: 16_000)
        _ = meter.append(first)
        for _ in 0..<100 {
            _ = meter.append(try tone(seconds: 0.02, rmsDBFS: -30, sampleRate: 48_000))
        }
        let level = try #require(meter.snapshot)
        #expect(abs(level.duration - 4) < 0.000_001)
        #expect(abs(try #require(level.activeRMSDBFS) + 30) < 0.01)
        #expect(!level.isLowLevel)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOX_RECORDING_LEVEL_REPLAY"] != nil))
    func replayCapturedAudioThroughTheProductionMeter() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOX_RECORDING_LEVEL_REPLAY"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var meter = RecordingAudioLevelMeter()
        while file.framePosition < file.length {
            try file.read(into: pcm)
            let sample = try #require(RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: .zero))
            let tick = meter.append(sample)
            _ = try #require(tick)
        }
        let level = try #require(meter.snapshot)
        print("Recording level replay: \(level)")
        #expect(level.rmsDBFS < -40) // This is the old false-positive condition.
        #expect(try #require(level.activeRMSDBFS) > -40)
        #expect(!level.isLowLevel)
        #expect(RecordingSessionDiagnostics(microphone: level, systemAudio: nil).warningMessage == nil)
    }

    private func append(seconds: Double, rmsDBFS: Double?, to meter: inout RecordingAudioLevelMeter) throws -> RecordingAudioMeterTick {
        let tick = meter.append(try tone(seconds: seconds, rmsDBFS: rmsDBFS))
        return try #require(tick)
    }

    private func tone(seconds: Double, rmsDBFS: Double?, sampleRate: Double = 48_000,
                      channels: AVAudioChannelCount = 1, interleaved: Bool = false,
                      commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
                      silentFirstChannel: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate,
                                              channels: channels, interleaved: interleaved))
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        let amplitude = rmsDBFS.map { pow(10, $0 / 20) * sqrt(2) } ?? 0
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                let value = silentFirstChannel && channel == 0 ? 0 : amplitude * sin(2 * .pi * 440 * Double(frame) / sampleRate)
                let index = frame * pcm.stride
                if let data = pcm.floatChannelData { data[channel][index] = Float(value) }
                else if let data = pcm.int16ChannelData { data[channel][index] = Int16(value * 32_767) }
                else if let data = pcm.int32ChannelData { data[channel][index] = Int32(value * 2_147_483_647) }
            }
        }
        return pcm
    }
}
