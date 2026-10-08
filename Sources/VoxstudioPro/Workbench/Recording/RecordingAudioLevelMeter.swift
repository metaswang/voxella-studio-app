import AVFoundation
import CoreMedia
import Foundation

/// Measures capture PCM without running speech inference on the recording queue.
/// A duration-weighted histogram gates out pauses; its size does not grow with
/// recording length. Live feedback uses the last eight seconds and can recover.
struct RecordingAudioLevelMeter {
    private static let windowSeconds = 0.1
    private static let liveWindowCount = 80
    private var duration = 0.0
    private var sampleCount = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var sampleRate = 0.0
    private var windowFrames = 0
    private var windowSquares: [Double] = []
    private var windowPeak = 0.0
    private var sessionLevels = WindowLevels()
    private var recentWindows: [LevelWindow] = []
    private var completedWindows = 0
    private var isWarningActive = false

    var snapshot: RecordingAudioLevel? {
        guard sampleCount > 0 else { return nil }
        var levels = sessionLevels
        if let pendingWindow { levels.append(pendingWindow) }
        return levels.level(duration: duration, rmsDBFS: Self.decibels(sumSquares / Double(sampleCount)),
                            peakDBFS: Self.decibels(peak * peak))
    }

    mutating func append(_ sampleBuffer: CMSampleBuffer) -> RecordingAudioMeterTick? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: stream),
              let frames = AVAudioFrameCount(exactly: CMSampleBufferGetNumSamples(sampleBuffer)),
              frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }
        return append(pcm)
    }

    mutating func append(_ pcm: AVAudioPCMBuffer) -> RecordingAudioMeterTick? {
        let channels = Int(pcm.format.channelCount)
        let frames = Int(pcm.frameLength)
        let rate = pcm.format.sampleRate
        guard frames > 0, channels > 0, rate.isFinite, rate > 0,
              pcm.floatChannelData != nil || pcm.int16ChannelData != nil || pcm.int32ChannelData != nil else {
            return nil
        }
        if sampleRate != rate || windowSquares.count != channels {
            finishWindow()
            sampleRate = rate
            windowSquares = Array(repeating: 0, count: channels)
        }
        let windowSize = max(1, Int((rate * Self.windowSeconds).rounded()))
        let sampleStride = pcm.stride
        let floats = pcm.floatChannelData
        let int16 = pcm.int16ChannelData
        let int32 = pcm.int32ChannelData
        let previousWindowCount = completedWindows
        var bufferPeak = 0.0
        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = frame * sampleStride
                let value: Double
                if let floats { value = Double(floats[channel][index]) }
                else if let int16 { value = Double(int16[channel][index]) / 32_768 }
                else if let int32 { value = Double(int32[channel][index]) / 2_147_483_648 }
                else { return nil }
                let magnitude = value.isFinite ? min(1, abs(value)) : 0
                let square = magnitude * magnitude
                sumSquares += square
                windowSquares[channel] += square
                windowPeak = max(windowPeak, magnitude)
                bufferPeak = max(bufferPeak, magnitude)
            }
            windowFrames += 1
            if windowFrames >= windowSize { finishWindow() }
        }
        sampleCount += frames * channels
        duration += Double(frames) / rate
        peak = max(peak, bufferPeak)

        var warningLevel: RecordingAudioLevel?
        var didRecoverLevel = false
        if completedWindows != previousWindowCount, recentWindows.count >= Self.liveWindowCount {
            var recent = WindowLevels()
            for window in recentWindows { recent.append(window) }
            let level = recent.level(duration: recent.duration, rmsDBFS: Self.decibels(recent.energy / recent.duration),
                                     peakDBFS: Self.decibels(recentWindows.map { $0.peak * $0.peak }.max() ?? 0))
            let isLow = level.isLowLevel
            if isLow != isWarningActive {
                isWarningActive = isLow
                if isLow { warningLevel = level }
                else { didRecoverLevel = true }
            }
        }
        return RecordingAudioMeterTick(peak: Float(bufferPeak), warningLevel: warningLevel,
                                       didRecoverLevel: didRecoverLevel)
    }

    private var pendingWindow: LevelWindow? {
        guard windowFrames > 0, sampleRate > 0 else { return nil }
        return LevelWindow(power: (windowSquares.max() ?? 0) / Double(windowFrames), peak: windowPeak,
                           duration: Double(windowFrames) / sampleRate)
    }

    private mutating func finishWindow() {
        guard let window = pendingWindow else { return }
        sessionLevels.append(window)
        completedWindows += 1
        recentWindows.append(window)
        if recentWindows.count > Self.liveWindowCount { recentWindows.removeFirst() }
        windowFrames = 0
        windowPeak = 0
        for channel in windowSquares.indices { windowSquares[channel] = 0 }
    }

    private static func decibels(_ power: Double) -> Double {
        power > 0 ? 10 * log10(power) : -.infinity
    }

    private struct LevelWindow {
        let power: Double
        let peak: Double
        let duration: TimeInterval
    }

    private struct WindowLevels {
        // One dB bins, from -120 dBFS through 0 dBFS.
        var durations = Array(repeating: 0.0, count: 121)
        var energies = Array(repeating: 0.0, count: 121)
        var duration = 0.0
        var energy = 0.0
        var healthyDuration = 0.0

        mutating func append(_ window: LevelWindow) {
            let db = max(-120, min(0, RecordingAudioLevelMeter.decibels(window.power)))
            let bin = Int(db.rounded(.down)) + 120
            durations[bin] += window.duration
            energies[bin] += window.power * window.duration
            duration += window.duration
            energy += window.power * window.duration
            if window.power >= pow(10, RecordingAudioLevel.lowRMSDBFS / 10) {
                healthyDuration += window.duration
            }
        }

        func level(duration: TimeInterval, rmsDBFS: Double, peakDBFS: Double) -> RecordingAudioLevel {
            // Use the loudest sustained 300 ms as the reference. A relative
            // 15 dB gate excludes pauses even in otherwise quiet microphones.
            var loudDuration = 0.0
            var referenceDB = -120
            for bin in stride(from: 120, through: 0, by: -1) {
                loudDuration += durations[bin]
                if loudDuration + 0.000_001 >= RecordingAudioLevel.minimumHealthyDuration {
                    referenceDB = bin - 120
                    break
                }
            }
            let firstBin = max(-60, referenceDB - 15) + 120
            let activeDuration = durations[firstBin...].reduce(0, +)
            let activeEnergy = energies[firstBin...].reduce(0, +)
            return RecordingAudioLevel(
                duration: duration, rmsDBFS: rmsDBFS, peakDBFS: peakDBFS,
                activeRMSDBFS: RecordingAudioLevelMeter.decibels(activeDuration > 0 ? activeEnergy / activeDuration : 0),
                healthyDuration: healthyDuration
            )
        }
    }
}
