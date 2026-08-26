import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

struct RecordingEngineRequest {
    var configuration: RecordingCaptureConfiguration
    var contentFilter: SCContentFilter?
    var sourceRect: CGRect?
    var outputURL: URL
    var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?
}

private struct RecordingAudioLevelMeter {
    private var frameCount = 0
    private var sampleCount = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var sampleRate = 48_000.0
    private var didIssueLowLevelWarning = false

    var snapshot: RecordingAudioLevel? {
        guard frameCount > 0, sampleCount > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return RecordingAudioLevel(
            duration: Double(frameCount) / sampleRate,
            rmsDBFS: decibels(for: rms),
            peakDBFS: decibels(for: peak)
        )
    }

    mutating func append(_ sampleBuffer: CMSampleBuffer) -> RecordingAudioLevel? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription),
              let frameCount = AVAudioFrameCount(exactly: CMSampleBufferGetNumSamples(sampleBuffer)),
              frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }

        self.sampleRate = streamDescription.pointee.mSampleRate > 0
            ? streamDescription.pointee.mSampleRate
            : sampleRate
        self.frameCount += Int(frameCount)
        if let channels = pcm.floatChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    accumulate(Double(channels[channel][frame]))
                }
            }
        } else if let channels = pcm.int16ChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    accumulate(Double(channels[channel][frame]) / Double(Int16.max))
                }
            }
        } else if let channels = pcm.int32ChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    accumulate(Double(channels[channel][frame]) / Double(Int32.max))
                }
            }
        }

        guard !didIssueLowLevelWarning,
              let level = snapshot,
              level.duration >= 3,
              level.rmsDBFS < -40 else {
            return nil
        }
        didIssueLowLevelWarning = true
        return level
    }

    private mutating func accumulate(_ sample: Double) {
        let magnitude = min(1, abs(sample))
        sumSquares += magnitude * magnitude
        peak = max(peak, magnitude)
        sampleCount += 1
    }

    private func decibels(for amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
}

final class ScreenCaptureRecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voxella.studio.recording", qos: .userInitiated)
    private let hostClock = CMClockGetHostTimeClock()
    private lazy var microphone = MicrophoneCaptureEngine(outputQueue: queue)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var includesVideo = false
    private var audioTrackCount = 0
    private var didStartSession = false
    private var hostOrigin: CMTime?
    private var pauseOffset: CMTime = .zero
    private var pauseBegan: CMTime?
    private var isPaused = false
    private var didAppendMedia = false
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var isStopping = false
    private var systemAudioMeter = RecordingAudioLevelMeter()
    private var microphoneMeter = RecordingAudioLevelMeter()
    private var systemAudioTranscoder = RecordingAudioTranscoder()
    private var microphoneTranscoder = RecordingAudioTranscoder()
    private var microphoneEnabled = false
    private var systemAudioEnabled = false
    private var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?

    func start(_ request: RecordingEngineRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.captureFailed("Recording engine unavailable."))
                    return
                }
                do {
                    try self.beginLocked(request, continuation: continuation)
                } catch {
                    self.resetLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
            self.pauseBegan = CMClockGetTime(self.hostClock)
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.isPaused else { return }
            if let pauseBegan = self.pauseBegan {
                self.pauseOffset = CMTimeAdd(
                    self.pauseOffset,
                    CMTimeSubtract(CMClockGetTime(self.hostClock), pauseBegan)
                )
            }
            self.pauseBegan = nil
            self.isPaused = false
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        queue.async { [weak self] in
            self?.microphone.isMuted = muted
        }
    }

    func stop() async throws -> RecordingStopResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.captureFailed("Recording engine unavailable."))
                    return
                }
                self.finishLocked(discard: false, continuation: continuation)
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                guard self.writer != nil || self.stream != nil || self.startContinuation != nil else {
                    continuation.resume()
                    return
                }
                self.finishLocked(discard: true) { (_: Result<RecordingStopResult, Error>) in
                    continuation.resume()
                }
            }
        }
    }

    private func beginLocked(
        _ request: RecordingEngineRequest,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        guard writer == nil, startContinuation == nil else {
            throw RecordingError.alreadyRecording
        }
        guard request.configuration.hasAudioSource else {
            throw RecordingError.audioSourceRequired
        }

        resetLocked()
        includesVideo = request.configuration.capturesVideo
        microphoneEnabled = request.configuration.microphone.isEnabled
        systemAudioEnabled = request.configuration.capturesSystemAudio
        outputURL = request.outputURL
        onAudioLevelWarning = request.onAudioLevelWarning
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: request.outputURL)

        let fileType: AVFileType = includesVideo ? .mp4 : .m4a
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: fileType)
        var audioTracks = 0

        if includesVideo {
            guard let filter = request.contentFilter else {
                throw RecordingError.captureFailed("A capture source is required for video recording.")
            }
            let size = outputSize(filter: filter, sourceRect: request.sourceRect)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw RecordingError.writerFailed("The video encoder is unavailable.")
            }
            writer.add(videoInput)
            self.videoInput = videoInput
        }

        if request.configuration.capturesSystemAudio {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("The system-audio encoder is unavailable.")
            }
            writer.add(input)
            systemAudioInput = input
            audioTracks += 1
        }

        if request.configuration.microphone.isEnabled {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("The microphone encoder is unavailable.")
            }
            writer.add(input)
            microphoneInput = input
            audioTracks += 1
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        self.writer = writer
        audioTrackCount = audioTracks
        startContinuation = continuation

        if request.configuration.microphone.isEnabled {
            try microphone.start(deviceID: request.configuration.microphone.deviceID) { [weak self] sample in
                self?.appendConvertedAudio(sample, to: self?.microphoneInput, source: .microphone)
            }
        }

        if request.configuration.requiresScreenCapture {
            guard let filter = request.contentFilter else {
                throw RecordingError.noDisplay
            }
            let configuration = streamConfiguration(
                filter: filter,
                request: request
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            if includesVideo {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            } else {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            }
            if request.configuration.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            self.stream = stream
            stream.startCapture { [weak self] error in
                self?.queue.async {
                    self?.handleStartResultLocked(error)
                }
            }
        } else {
            handleStartResultLocked(nil)
        }
    }

    private func handleStartResultLocked(_ error: Error?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error {
            resetLocked()
            continuation.resume(throwing: RecordingError.captureFailed(error.localizedDescription))
            return
        }
        continuation.resume()
    }

    private func finishLocked(
        discard: Bool,
        continuation: CheckedContinuation<RecordingStopResult, Error>? = nil,
        discarded: (@Sendable (Result<RecordingStopResult, Error>) -> Void)? = nil
    ) {
        guard !isStopping else {
            discarded?(.failure(RecordingError.cancelled))
            continuation?.resume(throwing: RecordingError.cancelled)
            return
        }
        isStopping = true
        let resume: @Sendable (Result<RecordingStopResult, RecordingError>) -> Void = { result in
            switch result {
            case .success(let stopResult):
                continuation?.resume(returning: stopResult)
                discarded?(.success(stopResult))
            case .failure(let error):
                continuation?.resume(throwing: error)
                discarded?(.failure(error))
            }
        }
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: RecordingError.cancelled)
        }
        microphone.stop()
        let stream = self.stream
        self.stream = nil
        let writer = self.writer
        let outputURL = self.outputURL
        let includesVideo = self.includesVideo
        let audioTrackCount = self.audioTrackCount
        let didAppendMedia = self.didAppendMedia
        let diagnostics = RecordingSessionDiagnostics(
            microphone: microphoneMeter.snapshot,
            systemAudio: systemAudioMeter.snapshot
        )
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil

        let completeWriter = {
            guard let writer, let outputURL else {
                self.resetLocked()
                if discard {
                    resume(.failure(RecordingError.cancelled))
                } else {
                    resume(.failure(RecordingError.emptyRecording))
                }
                return
            }
            writer.finishWriting { [weak self] in
                self?.queue.async {
                    self?.completeAfterWriterFinished(
                        writer: writer,
                        outputURL: outputURL,
                        includesVideo: includesVideo,
                        audioTrackCount: audioTrackCount,
                        didAppendMedia: didAppendMedia,
                        diagnostics: diagnostics,
                        discard: discard,
                        resume: resume
                    )
                }
            }
        }

        if let stream {
            stream.stopCapture { [weak self] _ in
                self?.queue.async {
                    completeWriter()
                }
            }
        } else {
            completeWriter()
        }
    }

    private func completeAfterWriterFinished(
        writer: AVAssetWriter,
        outputURL: URL,
        includesVideo: Bool,
        audioTrackCount: Int,
        didAppendMedia: Bool,
        diagnostics: RecordingSessionDiagnostics,
        discard: Bool,
        resume: @escaping @Sendable (Result<RecordingStopResult, RecordingError>) -> Void
    ) {
        if discard {
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.cancelled))
            return
        }
        guard writer.status == .completed, didAppendMedia else {
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.writerFailed(message)))
            return
        }
        if audioTrackCount < 2 {
            resetLocked()
            resume(.success(RecordingStopResult(url: outputURL, diagnostics: diagnostics)))
            return
        }
        let mixedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent)-mixed")
            .appendingPathExtension(outputURL.pathExtension)
        resetLocked()
        Task {
            do {
                try await RecordingAudioMixer.mixToSingleAudioTrack(
                    from: outputURL,
                    to: mixedURL,
                    includesVideo: includesVideo
                )
                try? FileManager.default.removeItem(at: outputURL)
                resume(.success(RecordingStopResult(url: mixedURL, diagnostics: diagnostics)))
            } catch {
                Log.recording.error(
                    "recording audio mix failed error=\(Log.detail(error))",
                    telemetry: "Recording audio mix failed"
                )
                try? FileManager.default.removeItem(at: mixedURL)
                resume(.success(RecordingStopResult(url: outputURL, diagnostics: diagnostics)))
            }
        }
    }

    private func resetLocked() {
        if writer?.status == .writing {
            writer?.cancelWriting()
        }
        stream = nil
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        outputURL = nil
        includesVideo = false
        audioTrackCount = 0
        didStartSession = false
        hostOrigin = nil
        pauseOffset = .zero
        pauseBegan = nil
        isPaused = false
        didAppendMedia = false
        isStopping = false
        startContinuation = nil
        systemAudioMeter = RecordingAudioLevelMeter()
        microphoneMeter = RecordingAudioLevelMeter()
        systemAudioTranscoder.reset()
        microphoneTranscoder.reset()
        microphoneEnabled = false
        systemAudioEnabled = false
        onAudioLevelWarning = nil
        microphone.stop()
    }

    private func streamConfiguration(
        filter: SCContentFilter,
        request: RecordingEngineRequest
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = request.configuration.capturesSystemAudio
        configuration.sampleRate = Int(RecordingAudioTranscoder.sampleRate)
        configuration.channelCount = Int(RecordingAudioTranscoder.channels)
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = request.configuration.capturesVideo
        if let sourceRect = request.sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            configuration.sourceRect = sourceRect
        }
        let size = outputSize(filter: filter, sourceRect: request.sourceRect)
        configuration.width = size.width
        configuration.height = size.height
        if !request.configuration.capturesVideo {
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
            configuration.showsCursor = false
        }
        return configuration
    }

    private func outputSize(filter: SCContentFilter, sourceRect: CGRect?) -> (width: Int, height: Int) {
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let rect = sourceRect ?? filter.contentRect
        let width = max(2, Int((rect.width * scale).rounded()))
        let height = max(2, Int((rect.height * scale).rounded()))
        return (width - width % 2, height - height % 2)
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingAudioTranscoder.sampleRate,
            AVNumberOfChannelsKey: Int(RecordingAudioTranscoder.channels),
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: RecordingAudioTranscoder.canonicalFormatDescription
        )
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func writerPTS() -> CMTime {
        let now = CMClockGetTime(hostClock)
        if hostOrigin == nil {
            hostOrigin = now
        }
        return CMTimeSubtract(CMTimeSubtract(now, hostOrigin ?? now), pauseOffset)
    }

    private func ensureSessionStarted() {
        guard !didStartSession, let writer else { return }
        writer.startSession(atSourceTime: .zero)
        didStartSession = true
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard !isPaused, let input, input.isReadyForMoreMediaData else { return }
        ensureSessionStarted()
        guard let retimed = retimedCopy(sampleBuffer, pts: writerPTS()) else { return }
        if input.append(retimed) {
            didAppendMedia = true
        }
    }

    private enum AudioMeterSource {
        case systemAudio
        case microphone
    }

    private func appendConvertedAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        source: AudioMeterSource
    ) {
        guard !isPaused, let input, input.isReadyForMoreMediaData else { return }
        let transcoder = source == .systemAudio ? systemAudioTranscoder : microphoneTranscoder
        guard let converted = transcoder.transcode(sampleBuffer) else { return }
        switch source {
        case .systemAudio:
            if let level = systemAudioMeter.append(converted), !microphoneEnabled {
                onAudioLevelWarning?(RecordingAudioLevelWarning(track: .systemAudio, level: level))
            }
        case .microphone:
            if let level = microphoneMeter.append(converted), !systemAudioEnabled {
                onAudioLevelWarning?(RecordingAudioLevelWarning(track: .microphone, level: level))
            }
        }
        ensureSessionStarted()
        if input.append(converted) {
            didAppendMedia = true
        }
    }

    private func retimedCopy(_ sample: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr else { return nil }
        return copy
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            append(sampleBuffer, to: videoInput)
        case .audio:
            appendConvertedAudio(sampleBuffer, to: systemAudioInput, source: .systemAudio)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            if let startContinuation = self.startContinuation {
                self.startContinuation = nil
                self.resetLocked()
                startContinuation.resume(throwing: RecordingError.captureFailed(error.localizedDescription))
            }
        }
    }
}
