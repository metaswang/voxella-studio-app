import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

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
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelTransferSession: VTPixelTransferSession?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var includesVideo = false
    private var audioTrackCount = 0
    private var videoSize = (width: 0, height: 0)
    private var didStartSession = false
    private var hostOrigin: CMTime?
    private var pauseOffset: CMTime = .zero
    private var pauseBegan: CMTime?
    private var isPaused = false
    private var didAppendMedia = false
    private var didAppendVideo = false
    private var didAppendSystemAudio = false
    private var didAppendMicrophone = false
    private var didLogVideoFormat = false
    private var didLogWriterAppendFailure = false
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
        onAudioLevelWarning = request.onAudioLevelWarning

        var audioTracks = 0
        if request.configuration.capturesSystemAudio { audioTracks += 1 }
        if request.configuration.microphone.isEnabled { audioTracks += 1 }
        let writerURL: URL
        let fileType: AVFileType
        if audioTracks >= 2 {
            fileType = .mov
            writerURL = request.outputURL.deletingPathExtension().appendingPathExtension("mov")
        } else {
            fileType = includesVideo ? .mp4 : .m4a
            writerURL = request.outputURL
        }
        outputURL = writerURL
        try FileManager.default.createDirectory(
            at: writerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: request.outputURL)
        if writerURL != request.outputURL {
            try? FileManager.default.removeItem(at: writerURL)
        }

        let writer = try AVAssetWriter(outputURL: writerURL, fileType: fileType)

        if includesVideo {
            guard let filter = request.contentFilter else {
                throw RecordingError.captureFailed("A capture source is required for video recording.")
            }
            let size = outputSize(filter: filter, sourceRect: request.sourceRect)
            videoSize = size
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw RecordingError.writerFailed("The video encoder is unavailable.")
            }
            writer.add(videoInput)
            self.videoInput = videoInput
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: size.width,
                    kCVPixelBufferHeightKey as String: size.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ]
            )
        }

        if request.configuration.capturesSystemAudio {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("The system-audio encoder is unavailable.")
            }
            writer.add(input)
            systemAudioInput = input
        }

        if request.configuration.microphone.isEnabled {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("The microphone encoder is unavailable.")
            }
            writer.add(input)
            microphoneInput = input
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
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
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
        let diagnostics = RecordingSessionDiagnostics(
            microphone: microphoneMeter.snapshot,
            systemAudio: systemAudioMeter.snapshot
        )

        let completeWriter = {
            self.finalizeWriterLocked(discard: discard, diagnostics: diagnostics, resume: resume)
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

    private func finalizeWriterLocked(
        discard: Bool,
        diagnostics: RecordingSessionDiagnostics,
        resume: @escaping @Sendable (Result<RecordingStopResult, RecordingError>) -> Void
    ) {
        guard let writer, let outputURL else {
            resetLocked()
            resume(.failure(discard ? .cancelled : .emptyRecording))
            return
        }

        if discard {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.cancelled))
            return
        }

        if writer.status == .failed {
            logWriterFailure("before finish")
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.writerFailed(message)))
            return
        }

        if !didStartSession || !didAppendMedia {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.emptyRecording))
            return
        }

        if includesVideo && !didAppendVideo {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            resetLocked()
            resume(.failure(.writerFailed("The recording did not capture any video frames.")))
            return
        }

        if let input = systemAudioInput, !didAppendSystemAudio {
            appendSilence(to: input)
        }
        if let input = microphoneInput, !didAppendMicrophone {
            appendSilence(to: input)
        }

        let includesVideo = self.includesVideo
        let audioTrackCount = self.audioTrackCount
        let didAppendMedia = self.didAppendMedia
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pixelBufferAdaptor = nil

        writer.finishWriting { [weak self] in
            self?.queue.async {
                self?.completeAfterWriterFinished(
                    writer: writer,
                    outputURL: outputURL,
                    includesVideo: includesVideo,
                    audioTrackCount: audioTrackCount,
                    didAppendMedia: didAppendMedia,
                    diagnostics: diagnostics,
                    resume: resume
                )
            }
        }
    }

    private func completeAfterWriterFinished(
        writer: AVAssetWriter,
        outputURL: URL,
        includesVideo: Bool,
        audioTrackCount: Int,
        didAppendMedia: Bool,
        diagnostics: RecordingSessionDiagnostics,
        resume: @escaping @Sendable (Result<RecordingStopResult, RecordingError>) -> Void
    ) {
        guard writer.status == .completed, didAppendMedia else {
            logWriterFailure("after finish")
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
            .appendingPathExtension(includesVideo ? "mp4" : "m4a")
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
        pixelBufferAdaptor = nil
        if let pixelTransferSession {
            VTPixelTransferSessionInvalidate(pixelTransferSession)
        }
        pixelTransferSession = nil
        systemAudioInput = nil
        microphoneInput = nil
        outputURL = nil
        includesVideo = false
        audioTrackCount = 0
        videoSize = (0, 0)
        didStartSession = false
        hostOrigin = nil
        pauseOffset = .zero
        pauseBegan = nil
        isPaused = false
        didAppendMedia = false
        didAppendVideo = false
        didAppendSystemAudio = false
        didAppendMicrophone = false
        didLogVideoFormat = false
        didLogWriterAppendFailure = false
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
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        if let sourceRect = request.sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            configuration.sourceRect = sourceRect
        }
        let size = outputSize(filter: filter, sourceRect: request.sourceRect)
        configuration.width = size.width
        configuration.height = size.height
        if request.configuration.capturesVideo {
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        } else {
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
        var width = max(2, Int((rect.width * scale).rounded()))
        var height = max(2, Int((rect.height * scale).rounded()))
        width -= width % 2
        height -= height % 2
        let maxWidth = 3840
        let maxHeight = 2160
        if width > maxWidth || height > maxHeight {
            let ratio = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
            width = max(2, Int((Double(width) * ratio).rounded()))
            height = max(2, Int((Double(height) * ratio).rounded()))
            width -= width % 2
            height -= height % 2
        }
        return (width, height)
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingAudioTranscoder.sampleRate,
            AVNumberOfChannelsKey: Int(RecordingAudioTranscoder.channels),
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
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

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopping, !isPaused,
              writer?.status == .writing,
              let input = videoInput,
              input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              Self.isCompleteScreenFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        if !didLogVideoFormat {
            didLogVideoFormat = true
            Log.recording.notice(
                "recording video frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) expected=\(videoSize.width)x\(videoSize.height)"
            )
        }
        ensureSessionStarted()
        guard let encodedBuffer = pixelBufferForWriter(pixelBuffer) else { return }
        if adaptor.append(encodedBuffer, withPresentationTime: writerPTS()) {
            didAppendVideo = true
            didAppendMedia = true
        } else {
            logAppendFailure(kind: "video")
        }
    }

    private func pixelBufferForWriter(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if sourceWidth == videoSize.width,
           sourceHeight == videoSize.height,
           sourceFormat == kCVPixelFormatType_32BGRA {
            return source
        }
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else {
            return nil
        }
        if pixelTransferSession == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &pixelTransferSession)
        }
        guard let session = pixelTransferSession,
              VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            return nil
        }
        return destination
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
        guard !isStopping, !isPaused,
              writer?.status == .writing,
              let input,
              input.isReadyForMoreMediaData else {
            return
        }
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
            switch source {
            case .systemAudio: didAppendSystemAudio = true
            case .microphone: didAppendMicrophone = true
            }
        } else {
            logAppendFailure(kind: source == .systemAudio ? "system audio" : "microphone")
        }
    }

    private func appendSilence(to input: AVAssetWriterInput) {
        guard input.isReadyForMoreMediaData,
              let sample = RecordingAudioTranscoder.makeSilentSampleBuffer() else {
            return
        }
        ensureSessionStarted()
        if input.append(sample) {
            didAppendMedia = true
        }
    }

    private static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer) else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first else {
            return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        }
        if let rawValue = first[.status] as? Int, let status = SCFrameStatus(rawValue: rawValue) {
            return status == .complete
        }
        return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }

    private func logAppendFailure(kind: String) {
        guard !didLogWriterAppendFailure else { return }
        didLogWriterAppendFailure = true
        if let error = writer?.error {
            Log.recording.error(
                "recording append failed kind=\(kind) error=\(Log.detail(error))",
                telemetry: "Recording append failed"
            )
        } else {
            Log.recording.error(
                "recording append failed kind=\(kind) writerStatus=\(writer?.status.rawValue ?? -1)",
                telemetry: "Recording append failed"
            )
        }
    }

    private func logWriterFailure(_ phase: String) {
        if let error = writer?.error {
            Log.recording.error(
                "recording writer failed phase=\(phase) error=\(Log.detail(error))",
                telemetry: "Recording writer failed"
            )
        } else {
            Log.recording.error(
                "recording writer failed phase=\(phase) status=\(writer?.status.rawValue ?? -1)",
                telemetry: "Recording writer failed"
            )
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            appendVideo(sampleBuffer)
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
                return
            }
            guard !self.isStopping else { return }
            Log.recording.error(
                "recording stream stopped error=\(Log.detail(error))",
                telemetry: "Recording stream stopped"
            )
        }
    }
}
