import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import VideoToolbox

struct RecordingEngineRequest {
    var configuration: RecordingCaptureConfiguration
    var contentFilter: SCContentFilter?
    var sourceRect: CGRect?
    var outputURL: URL
    var sessionID: UUID
    var displayID: UInt32?
    var liveWaveform: RecordingLiveWaveformStore
    var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?
    var onRuntimeEvent: (@Sendable (RecordingRuntimeEvent) -> Void)?
    var applicationSelection: RecordingApplicationSelection? = nil
    var videoSourceSize: CGSize? = nil
    var mobilePreviewSource: MobileDeviceCaptureSource? = nil
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

    mutating func append(_ sampleBuffer: CMSampleBuffer) -> RecordingAudioMeterTick? {
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
        var bufferPeak = 0.0
        if let channels = pcm.floatChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    bufferPeak = max(bufferPeak, accumulate(Double(channels[channel][frame])))
                }
            }
        } else if let channels = pcm.int16ChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    bufferPeak = max(
                        bufferPeak,
                        accumulate(Double(channels[channel][frame]) / Double(Int16.max))
                    )
                }
            }
        } else if let channels = pcm.int32ChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    bufferPeak = max(
                        bufferPeak,
                        accumulate(Double(channels[channel][frame]) / Double(Int32.max))
                    )
                }
            }
        }

        var warningLevel: RecordingAudioLevel?
        if !didIssueLowLevelWarning,
           let level = snapshot,
           level.duration >= 3,
           level.rmsDBFS < -40 {
            didIssueLowLevelWarning = true
            warningLevel = level
        }
        return RecordingAudioMeterTick(peak: Float(bufferPeak), warningLevel: warningLevel)
    }

    private mutating func accumulate(_ sample: Double) -> Double {
        let magnitude = min(1, abs(sample))
        sumSquares += magnitude * magnitude
        peak = max(peak, magnitude)
        sampleCount += 1
        return magnitude
    }

    private func decibels(for amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
}

final class ScreenCaptureRecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voxella.studio.recording", qos: .userInitiated)
    private let supervisorQueue = DispatchQueue(label: "com.voxella.studio.recording.supervisor", qos: .userInitiated)
    private let hostClock = CMClockGetHostTimeClock()
    // SCStreamConfiguration's color property is unowned; retain it for the stream lifetime.
    private let applicationBackgroundColor = CGColor(gray: 0, alpha: 1)
    private lazy var microphone = MicrophoneCaptureEngine(outputQueue: queue)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelTransferSession: VTPixelTransferSession?
    private var mobileSource: MobileDeviceCaptureSource?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var includesVideo = false
    private var audioTrackCount = 0
    private var videoSize = (width: 0, height: 0)
    private var didStartSession = false
    private var hostOrigin: CMTime?
    private var segmentGlobalStart: CMTime = .zero
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
    private var isMicrophoneMuted = false
    private var liveWaveform: RecordingLiveWaveformStore?
    private var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?
    private var onRuntimeEvent: (@Sendable (RecordingRuntimeEvent) -> Void)?
    private var currentRequest: RecordingEngineRequest?
    private var contentFilter: SCContentFilter?
    private var currentDisplayID: UInt32?
    private var captureGeneration: UInt64 = 0
    private var recoveryGeneration: UInt64 = 0
    private var healthTimer: DispatchSourceTimer?
    private var captureStartedAt: TimeInterval?
    private var microphoneHealth = RecordingHealthMachine()
    private var systemAudioHealth = RecordingHealthMachine()
    private var microphoneProgress = RecordingTrackProgress()
    private var systemAudioProgress = RecordingTrackProgress()
    private var microphoneCursor = RecordingAudioCursor()
    private var systemAudioCursor = RecordingAudioCursor()
    private var sealedSegments: [RecordingWriterSegment] = []
    private var segmentIndex = 0
    private var sessionID = UUID()
    private var captureBackend = "none"
    private var isRecovering = false
    private var isRecoveringStream = false
    private var streamRecoveryAttempts = 0
    private var didWarnDiskSpace = false
    private var finishContext: RecordingFinishContext?
    private var sessionManifest: RecordingSessionManifest?
    private var orphanedWriters: [AVAssetWriter] = []
    private var lastVideoCallback: TimeInterval = 0
    private var lastCompleteVideoFrame: TimeInterval = 0
    private var lastVideoAppended: TimeInterval = 0
    private var lastVideoPTS: Double?
    private var lastEncodedVideoBuffer: CVPixelBuffer?
    private var lastScreenFrameStatus: SCFrameStatus?
    private var pendingStopReason: RecordingStopReason = .userStop
    private let healthSnapshot = OSAllocatedUnfairLock(initialState: RecordingHealthSnapshot())
    private let durableSalvage = OSAllocatedUnfairLock(initialState: false)

    var hasDurableSalvage: Bool { durableSalvage.withLock { $0 } }

    func start(_ request: RecordingEngineRequest) async throws {
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        try await RecordingTimeout.withTimeout(seconds: RecordingLifecycleTimeout.start,
            timeoutError: request.configuration.mode == .mobileDevice ? .mobileDeviceNotStreaming : .captureNotStarted) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        guard !cancellation.withLock({ $0 }) else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        do {
                            try self.beginLocked(request, continuation: continuation)
                        } catch {
                            if self.sessionID == request.sessionID { self.discardFailedStartLocked() }
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                cancellation.withLock { $0 = true }
                self.queue.async {
                    self.cancelStartLocked(expectedSessionID: request.sessionID)
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
            self.microphoneHealth.applyPauseGrace(duration: RecordingCaptureHealth.pauseGrace)
            self.systemAudioHealth.applyPauseGrace(duration: RecordingCaptureHealth.pauseGrace)
            self.updateHealthSnapshotLocked()
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        queue.async { [weak self] in
            self?.isMicrophoneMuted = muted
        }
    }

    func handleSystemWake() {
        queue.async { [weak self] in
            guard let self, !self.isStopping, self.writer != nil else { return }
            Log.recording.notice("recording handling system wake session=\(self.sessionID.uuidString)")
            self.microphoneHealth.applyPauseGrace(duration: RecordingCaptureHealth.pauseGrace)
            self.systemAudioHealth.applyPauseGrace(duration: RecordingCaptureHealth.pauseGrace)
            self.recoverAfterInterruptionLocked(reason: "system wake")
        }
    }

    func handleDisplayChange() {
        queue.async { [weak self] in
            guard let self, !self.isStopping, self.stream != nil else { return }
            self.recoverStreamLocked(reason: "display change", streamStopped: false)
        }
    }

    func stop(
        expectedSessionID: UUID? = nil,
        mode: RecordingFinishMode = .export,
        reason: RecordingStopReason = .userStop
    ) async throws -> RecordingStopResult {
        let timeout = mode == .salvage ? RecordingLifecycleTimeout.salvageStop : RecordingLifecycleTimeout.stop
        return try await RecordingTimeout.withTimeout(seconds: timeout, timeoutError: .recordingSaveDelayed) {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    self.finishLocked(
                        mode: mode,
                        expectedSessionID: expectedSessionID,
                        reason: reason,
                        continuation: continuation
                    )
                }
            }
        }
    }

    func cancel(expectedSessionID: UUID? = nil) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if let expectedSessionID, self.sessionID != expectedSessionID {
                    continuation.resume()
                    return
                }
                guard self.writer != nil || self.stream != nil || self.mobileSource != nil || self.startContinuation != nil else {
                    continuation.resume()
                    return
                }
                self.finishLocked(mode: .discard, expectedSessionID: expectedSessionID, reason: .userDiscard) { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func beginLocked(
        _ request: RecordingEngineRequest,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        guard writer == nil, startContinuation == nil, finishContext == nil else {
            throw RecordingError.alreadyRecording
        }
        guard request.configuration.hasCaptureSource else {
            throw RecordingError.audioSourceRequired
        }
        if let diskError = Self.criticalDiskSpaceError(at: request.outputURL) {
            throw diskError
        }

        resetLocked(mode: .discard)
        captureGeneration += 1
        let generation = captureGeneration
        currentRequest = request
        contentFilter = request.contentFilter
        currentDisplayID = request.displayID
        sessionID = request.sessionID
        includesVideo = request.configuration.capturesVideo
        microphoneEnabled = request.configuration.microphone.isEnabled
        systemAudioEnabled = request.configuration.capturesPrimaryAudio
        liveWaveform = request.liveWaveform
        onAudioLevelWarning = request.onAudioLevelWarning
        onRuntimeEvent = request.onRuntimeEvent
        isStopping = false
        durableSalvage.withLock { $0 = false }
        pendingStopReason = .userStop

        var audioTracks = 0
        if request.configuration.capturesPrimaryAudio { audioTracks += 1 }
        if request.configuration.microphone.isEnabled { audioTracks += 1 }
        audioTrackCount = audioTracks
        let writerURL = request.outputURL
        outputURL = writerURL
        try FileManager.default.createDirectory(
            at: writerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if request.configuration.mode != .mobileDevice {
            try installWriterLocked(url: writerURL, request: request)
        }
        startContinuation = continuation
        captureBackend = Self.backendName(for: request.configuration)
        writeJournal(status: RecordingSessionManifest.capturing)

        let usesStreamMicrophone = request.configuration.microphone.isEnabled
            && request.configuration.requiresScreenCapture
        if request.configuration.microphone.isEnabled, !usesStreamMicrophone {
            microphone.start(
                sessionID: request.sessionID,
                generation: generation,
                deviceID: request.configuration.microphone.deviceID,
                onSample: { [weak self] sample in
                    self?.appendMicrophoneSample(sample)
                },
                onEvent: { [weak self] event in
                    self?.handleMicrophoneEventLocked(event, generation: generation)
                },
                completion: { [weak self] result in
                    self?.queue.async {
                        guard let self, self.captureGeneration == generation else { return }
                        switch result {
                        case .failure(let error):
                            self.handleStartResultLocked(error, generation: generation)
                        case .success:
                            if request.configuration.mode == .mobileDevice {
                                self.startMobileLocked(request: request, generation: generation)
                            } else if request.configuration.requiresScreenCapture {
                                do {
                                    guard let filter = request.contentFilter else {
                                        throw RecordingError.noDisplay
                                    }
                                    try self.startStreamLocked(filter: filter, request: request, generation: generation)
                                } catch {
                                    self.handleStartResultLocked(error, generation: generation)
                                }
                            } else {
                                self.handleStartResultLocked(nil, generation: generation)
                            }
                        }
                    }
                }
            )
            return
        }

        if request.configuration.mode == .mobileDevice {
            startMobileLocked(request: request, generation: generation)
        } else if request.configuration.requiresScreenCapture {
            guard let filter = request.contentFilter else {
                throw RecordingError.noDisplay
            }
            try startStreamLocked(filter: filter, request: request, generation: generation)
        } else {
            handleStartResultLocked(nil, generation: generation)
        }
    }

    func showMobilePreview() {
        queue.async { [weak self] in
            guard let source = self?.mobileSource else { return }
            Task { @MainActor in MobileDevicePreviewController.shared.show(source: source) }
        }
    }

    private func startMobileLocked(request: RecordingEngineRequest, generation: UInt64) {
        guard let deviceID = request.configuration.mobileDeviceID else {
            handleStartResultLocked(RecordingError.mobileDeviceUnavailable, generation: generation)
            return
        }
        let source = request.mobilePreviewSource ?? MobileDeviceCaptureSource()
        mobileSource = source
        Task { @MainActor in MobileDevicePreviewController.shared.show(source: source) }
        source.start(deviceID: deviceID, preset: request.configuration.mobilePreset,
                     capturesAudio: request.configuration.capturesDeviceAudio,
                     onSample: { [weak self] sample, isVideo, pts in
            self?.queue.async { [weak self] in
                guard let self, self.captureGeneration == generation, !self.isStopping else { return }
                do {
                    if isVideo, self.writer == nil {
                        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
                        var sizedRequest = request
                        sizedRequest.videoSourceSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
                        sizedRequest.configuration.video = RecordingVideoSettings()
                        self.currentRequest = sizedRequest
                        try self.installWriterLocked(url: request.outputURL, request: sizedRequest)
                    }
                    if isVideo {
                        guard let image = CMSampleBufferGetImageBuffer(sample), self.writer != nil else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        self.lastVideoCallback = now
                        self.lastCompleteVideoFrame = now
                        guard !self.isPaused else { return }
                        self.appendVideoBuffer(image, at: pts, now: now)
                        if self.didAppendVideo, self.startContinuation != nil {
                            self.handleStartResultLocked(nil, generation: generation)
                        }
                    } else if self.writer != nil {
                        self.appendConvertedAudio(sample, to: self.systemAudioInput, source: .systemAudio, capturePTS: pts)
                    }
                } catch {
                    self.handleStartResultLocked(error, generation: generation)
                }
            }
        }, onError: { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.captureGeneration == generation, !self.isStopping else { return }
                if self.startContinuation != nil {
                    self.handleStartResultLocked(error, generation: generation)
                } else {
                    self.emit(.failed(error: error, reason: "USB device capture"))
                }
            }
        })
    }

    private func installWriterLocked(url: URL, request: RecordingEngineRequest) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw RecordingError.writerFailed("A recording file already exists at the output path.")
        }
        let fileType: AVFileType
        if audioTrackCount >= 2 {
            fileType = .mov
        } else {
            fileType = includesVideo ? .mp4 : .m4a
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.movieFragmentInterval = CMTime(
            seconds: RecordingCaptureHealth.fragmentInterval,
            preferredTimescale: 600
        )

        if includesVideo {
            let size: (width: Int, height: Int)
            if let sourceSize = request.videoSourceSize {
                size = request.configuration.video.outputSize(for: sourceSize)
            } else if let filter = request.contentFilter {
                size = outputSize(filter: filter, sourceRect: request.sourceRect)
            } else {
                throw RecordingError.captureFailed("A capture source is required for video recording.")
            }
            videoSize = size
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            ]
            let fps = request.configuration.video.effectiveFrameRate
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: request.configuration.video.bitRate(width: size.width, height: size.height),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any]
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

        if request.configuration.capturesPrimaryAudio {
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
        writer.startSession(atSourceTime: .zero)
        didStartSession = true
        self.writer = writer
        outputURL = url
        // Each writer starts its own timeline at zero. Comparing its frames to
        // the previous segment's PTS would discard video until it catches up.
        lastVideoPTS = nil
        lastVideoAppended = 0
        didLogWriterAppendFailure = false
        didAppendMedia = false
        didAppendVideo = false
        didAppendMicrophone = false
        didAppendSystemAudio = false
        microphoneCursor = RecordingAudioCursor()
        systemAudioCursor = RecordingAudioCursor()
    }

    private func startStreamLocked(
        filter: SCContentFilter,
        request: RecordingEngineRequest,
        generation: UInt64
    ) throws {
        let configuration = streamConfiguration(filter: filter, request: request)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if request.configuration.capturesPrimaryAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if request.configuration.microphone.isEnabled, request.configuration.requiresScreenCapture {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            Log.recording.notice(
                "recording microphone started backend=stream device=\(request.configuration.microphone.deviceID ?? "default")"
            )
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            self?.queue.async {
                self?.handleStartResultLocked(error, generation: generation)
            }
        }
    }

    private func handleStartResultLocked(_ error: Error?, generation: UInt64) {
        guard generation == captureGeneration else { return }
        if let continuation = startContinuation {
            startContinuation = nil
            if let error {
                discardFailedStartLocked()
                continuation.resume(throwing: RecordingPermission.captureStartError(error))
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            captureStartedAt = now
            microphoneHealth.reset(at: now)
            systemAudioHealth.reset(at: now)
            startHealthMonitorLocked()
            continuation.resume()
            return
        }
        if let error {
            Log.recording.error(
                "recording stream restart failed error=\(Log.detail(error)) session=\(sessionID.uuidString)",
                telemetry: "Recording stream stopped"
            )
            streamRecoveryAttempts += 1
            if streamRecoveryAttempts >= 3 {
                emit(
                    .failed(
                        error: .captureInterrupted("System audio capture stopped and could not be restored. The recording so far was saved."),
                        reason: Log.detail(error)
                    )
                )
            } else {
                isRecoveringStream = false
                recoverStreamLocked(reason: Log.detail(error), streamStopped: true)
            }
            return
        }
        isRecovering = false
        isRecoveringStream = false
        emit(.recovering(source: "stream", message: "Waiting for capture audio…"))
    }

    private func cancelStartLocked(expectedSessionID: UUID) {
        guard startContinuation != nil else { return }
        guard sessionID == expectedSessionID else { return }
        let continuation = startContinuation
        startContinuation = nil
        discardFailedStartLocked()
        continuation?.resume(throwing: RecordingError.cancelled)
    }

    private func discardFailedStartLocked() {
        let failedURL = sessionManifest?.outputURL ?? (writer != nil ? outputURL : nil)
        // Fence late samples before releasing the writer and the capture source.
        captureGeneration += 1
        stream?.stopCapture { _ in }
        resetLocked(mode: .discard)
        if let failedURL {
            try? FileManager.default.removeItem(at: failedURL)
            RecordingSessionManifest.remove(for: failedURL)
        }
    }

    private func finishLocked(
        mode: RecordingFinishMode,
        expectedSessionID: UUID? = nil,
        reason: RecordingStopReason,
        continuation: CheckedContinuation<RecordingStopResult, Error>? = nil,
        discarded: (@Sendable (Result<RecordingStopResult, Error>) -> Void)? = nil
    ) {
        if let expectedSessionID, sessionID != expectedSessionID, startContinuation == nil {
            discarded?(.failure(RecordingError.cancelled))
            continuation?.resume(throwing: RecordingError.cancelled)
            return
        }
        if let finishContext {
            if let continuation {
                finishContext.gate.arm(continuation)
            }
            discarded?(.failure(RecordingError.cancelled))
            return
        }
        isStopping = true
        pendingStopReason = reason
        captureGeneration += 1
        microphone.fence(generation: captureGeneration)
        microphone.stop()
        mobileSource?.stop()
        mobileSource = nil
        Task { @MainActor in MobileDevicePreviewController.shared.close() }
        stopHealthMonitorLocked()
        updateHealthSnapshotLocked(isStopping: true)

        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: RecordingError.cancelled)
        }

        flushTranscodersLocked()
        let stream = self.stream
        self.stream = nil
        let diagnostics = makeDiagnosticsLocked(reason: reason)
        let operationID = UUID()
        let context = RecordingFinishContext(
            sessionID: sessionID,
            operationID: operationID,
            captureGeneration: captureGeneration,
            mode: mode,
            writer: writer,
            outputURL: outputURL,
            includesVideo: includesVideo,
            audioTrackCount: audioTrackCount,
            didAppendMedia: didAppendMedia,
            didAppendVideo: didAppendVideo,
            didAppendMicrophone: didAppendMicrophone,
            didAppendSystemAudio: didAppendSystemAudio,
            segments: sealedSegments,
            diagnostics: diagnostics,
            stopReason: reason
        )
        if let continuation {
            context.gate.arm(continuation)
        }
        finishContext = context

        let completeWriter = { [weak self] in
            self?.finalizeWriterLocked(context: context, discarded: discarded)
        }

        if let stream {
            let timeout = DispatchWorkItem { [weak self] in
                self?.queue.async {
                    guard let self, self.finishContext?.operationID == operationID else { return }
                    completeWriter()
                }
            }
            context.storeStreamTimeout(timeout)
            stream.stopCapture { [weak self] _ in
                self?.queue.async {
                    guard self?.finishContext?.operationID == operationID else { return }
                    completeWriter()
                }
            }
            queue.asyncAfter(deadline: .now() + RecordingLifecycleTimeout.streamStop, execute: timeout)
        } else {
            completeWriter()
        }
    }

    private func finalizeWriterLocked(
        context: RecordingFinishContext,
        discarded: (@Sendable (Result<RecordingStopResult, Error>) -> Void)?
    ) {
        guard finishContext?.operationID == context.operationID else { return }
        guard context.markWriterFinalized() else { return }
        let resume: @Sendable (Result<RecordingStopResult, Error>) -> Void = { result in
            discarded?(result)
            context.resume(result)
        }

        let writer = context.writer ?? self.writer
        let outputURL = context.outputURL ?? self.outputURL
        guard let writer, let outputURL else {
            if !context.segments.isEmpty {
                completePreservedOutput(context: context, currentURL: context.segments.last!.url, resume: resume)
                return
            }
            resetLocked(mode: context.mode)
            resume(.failure(context.mode == .discard ? RecordingError.cancelled : RecordingError.emptyRecording))
            return
        }

        if context.mode == .discard {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            RecordingSessionManifest.remove(for: outputURL)
            for segment in context.segments {
                try? FileManager.default.removeItem(at: segment.url)
                RecordingSessionManifest.remove(for: segment.url)
            }
            resetLocked(mode: .discard)
            resume(.failure(RecordingError.cancelled))
            return
        }

        if writer.status == .failed {
            logWriterFailure("before finish")
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            preserveOutputIfNeeded(url: outputURL, reason: message, status: RecordingSessionManifest.failed)
            completePreservedOutput(context: context, currentURL: outputURL, resume: resume)
            return
        }

        if !didStartSession || (!context.didAppendMedia && context.segments.isEmpty && !didAppendMedia) {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            RecordingSessionManifest.remove(for: outputURL)
            if !context.segments.isEmpty {
                completePreservedOutput(context: context, currentURL: context.segments.last!.url, resume: resume)
                return
            }
            resetLocked(mode: context.mode)
            resume(.failure(RecordingError.emptyRecording))
            return
        }

        if context.includesVideo && !context.didAppendVideo && !didAppendVideo && context.segments.isEmpty {
            preserveOutputIfNeeded(
                url: outputURL,
                reason: "The recording did not capture any video frames.",
                status: RecordingSessionManifest.failed
            )
            completePreservedOutput(context: context, currentURL: outputURL, resume: resume)
            return
        }

        if microphoneEnabled && !didAppendMicrophone {
            Log.recording.warning(
                "recording finished without microphone samples",
                telemetry: "Recording microphone missing"
            )
        }

        if let input = systemAudioInput, !didAppendSystemAudio {
            appendTrailingSilence(to: input, source: .systemAudio)
        }
        if let input = microphoneInput, !didAppendMicrophone {
            appendTrailingSilence(to: input, source: .microphone)
        }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pixelBufferAdaptor = nil

        let capturedWriter = writer
        capturedWriter.finishWriting { [weak self] in
            self?.queue.async {
                guard self?.finishContext?.operationID == context.operationID else {
                    self?.releaseOrphanedWriter(capturedWriter)
                    return
                }
                self?.completeAfterWriterFinished(
                    writer: capturedWriter,
                    outputURL: outputURL,
                    context: context,
                    resume: resume
                )
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, self.finishContext?.operationID == context.operationID else { return }
                self.preserveOutputIfNeeded(
                    url: outputURL,
                    reason: "Timed out while finishing the recording.",
                    status: RecordingSessionManifest.pendingFinalize
                )
                self.completePreservedOutput(context: context, currentURL: outputURL, resume: resume)
            }
        }
        context.storeWriterTimeout(timeout)
        let writerTimeout = context.mode == .salvage
            ? RecordingLifecycleTimeout.salvageWriterFinish
            : RecordingLifecycleTimeout.writerFinish
        queue.asyncAfter(deadline: .now() + writerTimeout, execute: timeout)
    }

    private func completeAfterWriterFinished(
        writer: AVAssetWriter,
        outputURL: URL,
        context: RecordingFinishContext,
        resume: @escaping @Sendable (Result<RecordingStopResult, Error>) -> Void
    ) {
        guard finishContext?.operationID == context.operationID else { return }
        guard writer.status == .completed, context.didAppendMedia || didAppendMedia || !context.segments.isEmpty else {
            logWriterFailure("after finish")
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            if context.didAppendMedia || didAppendMedia || FileManager.default.fileExists(atPath: outputURL.path) {
                preserveOutputIfNeeded(url: outputURL, reason: message, status: RecordingSessionManifest.failed)
                completePreservedOutput(context: context, currentURL: outputURL, resume: resume)
                return
            }
            if !context.segments.isEmpty {
                completePreservedOutput(context: context, currentURL: context.segments.last!.url, resume: resume)
                return
            }
            try? FileManager.default.removeItem(at: outputURL)
            RecordingSessionManifest.remove(for: outputURL)
            resetLocked(mode: context.mode)
            resume(.failure(RecordingError.writerFailed(message)))
            return
        }
        completePreservedOutput(context: context, currentURL: outputURL, resume: resume)
    }

    private func completePreservedOutput(
        context: RecordingFinishContext,
        currentURL: URL,
        resume: @escaping @Sendable (Result<RecordingStopResult, Error>) -> Void
    ) {
        guard finishContext?.operationID == context.operationID else { return }
        let segments = (context.segments + sealedSegments).reduce(into: [RecordingWriterSegment]()) { partial, segment in
            if !partial.contains(where: { $0.url == segment.url }) {
                partial.append(segment)
            }
        }
        var urls = segments.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if FileManager.default.fileExists(atPath: currentURL.path), !urls.contains(currentURL) {
            urls.append(currentURL)
        }
        let includesVideo = context.includesVideo
        let audioTrackCount = context.audioTrackCount
        let diagnostics = context.diagnostics
        let sessionID = context.sessionID
        let salvageOnly = context.mode == .salvage
        releaseWriterLocked(cancel: false)
        resetLocked(mode: context.mode, keepSalvage: true)

        guard !urls.isEmpty else {
            finishContext = nil
            resume(.failure(RecordingError.emptyRecording))
            return
        }

        let journalOK = writeJournal(
            status: salvageOnly ? RecordingSessionManifest.rawSaved : RecordingSessionManifest.pendingExport,
            outputURL: urls.last ?? currentURL,
            sessionID: sessionID,
            urls: urls
        )
        durableSalvage.withLock { $0 = journalOK }

        Task {
            let inspections = await withTaskGroup(of: RecordingMediaValidator.Inspection.self) { group in
                for url in urls {
                    group.addTask { await RecordingMediaValidator.inspect(url) }
                }
                var results: [RecordingMediaValidator.Inspection] = []
                for await inspection in group {
                    results.append(inspection)
                }
                return results
            }
            let readable = RecordingMediaValidator.readableURLs(in: urls, inspections: inspections)
            let unreadable = inspections.filter { !$0.isReadable }
            var warnings = unreadable.map { "Unreadable segment: \($0.url.lastPathComponent)" }
            var resultURL = readable.last ?? urls.last ?? currentURL
            var outcome: RecordingStopOutcomeKind = readable.count == urls.count ? .complete : .partial
            if readable.isEmpty {
                outcome = .recoveryRequired
                warnings.append("No segment could be decoded.")
                let journalOK = self.writeJournal(
                    status: RecordingSessionManifest.failed,
                    outputURL: urls.last ?? currentURL,
                    sessionID: sessionID,
                    urls: urls,
                    warnings: warnings
                )
                self.queue.async {
                    self.durableSalvage.withLock { $0 = journalOK }
                    self.finishContext = nil
                    resume(
                        .success(
                            RecordingStopResult(
                                url: resultURL,
                                diagnostics: diagnostics,
                                outcome: .recoveryRequired,
                                warnings: warnings,
                                segmentURLs: urls,
                                sessionID: sessionID,
                                journalPersisted: journalOK
                            )
                        )
                    )
                }
                return
            }

            if salvageOnly {
                outcome = readable.count == 1 ? .rawSegments : .rawSegments
                let journalOK = self.writeJournal(
                    status: RecordingSessionManifest.pendingImport,
                    outputURL: resultURL,
                    sessionID: sessionID,
                    urls: readable,
                    warnings: warnings
                )
                self.queue.async {
                    self.durableSalvage.withLock { $0 = journalOK }
                    self.finishContext = nil
                    resume(
                        .success(
                            RecordingStopResult(
                                url: resultURL,
                                diagnostics: diagnostics,
                                outcome: outcome,
                                warnings: warnings,
                                segmentURLs: readable,
                                sessionID: sessionID,
                                journalPersisted: journalOK
                            )
                        )
                    )
                }
                return
            }

            do {
                if readable.count > 1 {
                    let concatenated = currentURL.deletingLastPathComponent()
                        .appendingPathComponent("\(currentURL.deletingPathExtension().lastPathComponent)-joined")
                        .appendingPathExtension(includesVideo || audioTrackCount >= 2 ? currentURL.pathExtension : "m4a")
                    try await RecordingAudioMixer.concatenate(
                        urls: readable,
                        to: concatenated,
                        includesVideo: includesVideo
                    )
                    resultURL = concatenated
                }
                if audioTrackCount >= 2 {
                    let mixedURL = resultURL.deletingLastPathComponent()
                        .appendingPathComponent("\(resultURL.deletingPathExtension().lastPathComponent)-mixed")
                        .appendingPathExtension(includesVideo ? "mp4" : "m4a")
                    do {
                        try await RecordingAudioMixer.mixToSingleAudioTrack(
                            from: resultURL,
                            to: mixedURL,
                            includesVideo: includesVideo
                        )
                        if resultURL != currentURL {
                            try? FileManager.default.removeItem(at: resultURL)
                        }
                        resultURL = mixedURL
                    } catch {
                        warnings.append("Audio mix failed; keeping separate tracks.")
                        outcome = .partial
                        Log.recording.error(
                            "recording audio mix failed error=\(Log.detail(error))",
                            telemetry: "Recording audio mix failed"
                        )
                    }
                }
                let journalOK = self.writeJournal(
                    status: RecordingSessionManifest.pendingImport,
                    outputURL: resultURL,
                    sessionID: sessionID,
                    urls: readable,
                    warnings: warnings
                )
                self.queue.async {
                    self.durableSalvage.withLock { $0 = journalOK }
                    self.finishContext = nil
                    resume(
                        .success(
                            RecordingStopResult(
                                url: resultURL,
                                diagnostics: diagnostics,
                                outcome: outcome,
                                warnings: warnings,
                                segmentURLs: readable,
                                sessionID: sessionID,
                                journalPersisted: journalOK
                            )
                        )
                    )
                }
            } catch {
                Log.recording.error(
                    "recording segment join failed error=\(Log.detail(error))",
                    telemetry: "Recording segment join failed"
                )
                warnings.append("Could not join segments; keeping original files.")
                let journalOK = self.writeJournal(
                    status: RecordingSessionManifest.pendingImport,
                    outputURL: readable[0],
                    sessionID: sessionID,
                    urls: readable,
                    warnings: warnings
                )
                self.queue.async {
                    self.durableSalvage.withLock { $0 = journalOK }
                    self.finishContext = nil
                    resume(
                        .success(
                            RecordingStopResult(
                                url: readable[0],
                                diagnostics: diagnostics,
                                outcome: .rawSegments,
                                warnings: warnings,
                                segmentURLs: readable,
                                sessionID: sessionID,
                                journalPersisted: journalOK
                            )
                        )
                    )
                }
            }
        }
    }

    private func releaseWriterLocked(cancel: Bool) {
        if cancel, writer?.status == .writing {
            writer?.cancelWriting()
        } else if let writer, writer.status == .writing {
            orphanedWriters.append(writer)
        }
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pixelBufferAdaptor = nil
    }

    private func releaseOrphanedWriter(_ writer: AVAssetWriter) {
        orphanedWriters.removeAll { $0 === writer }
    }

    private func resetLocked(mode: RecordingFinishMode, keepSalvage: Bool = false) {
        stopHealthMonitorLocked()
        if mode == .discard {
            if writer?.status == .writing {
                writer?.cancelWriting()
            }
        } else if let writer, writer.status == .writing {
            orphanedWriters.append(writer)
        }
        stream = nil
        mobileSource?.stop()
        mobileSource = nil
        Task { @MainActor in MobileDevicePreviewController.shared.close() }
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
        segmentGlobalStart = .zero
        pauseOffset = .zero
        pauseBegan = nil
        isPaused = false
        didAppendMedia = false
        didAppendVideo = false
        didAppendSystemAudio = false
        didAppendMicrophone = false
        didLogVideoFormat = false
        didLogWriterAppendFailure = false
        isStopping = mode != .discard && keepSalvage ? false : false
        startContinuation = nil
        systemAudioMeter = RecordingAudioLevelMeter()
        microphoneMeter = RecordingAudioLevelMeter()
        systemAudioTranscoder.reset()
        microphoneTranscoder.reset()
        microphoneEnabled = false
        systemAudioEnabled = false
        isMicrophoneMuted = false
        liveWaveform = nil
        onAudioLevelWarning = nil
        onRuntimeEvent = nil
        currentRequest = nil
        contentFilter = nil
        currentDisplayID = nil
        captureStartedAt = nil
        microphoneHealth = RecordingHealthMachine()
        systemAudioHealth = RecordingHealthMachine()
        microphoneProgress = RecordingTrackProgress()
        systemAudioProgress = RecordingTrackProgress()
        microphoneCursor = RecordingAudioCursor()
        systemAudioCursor = RecordingAudioCursor()
        sealedSegments = []
        segmentIndex = 0
        captureBackend = "none"
        isRecovering = false
        isRecoveringStream = false
        streamRecoveryAttempts = 0
        didWarnDiskSpace = false
        if !keepSalvage {
            finishContext = nil
            durableSalvage.withLock { $0 = false }
            sessionManifest = nil
        }
        lastVideoCallback = 0
        lastCompleteVideoFrame = 0
        lastVideoAppended = 0
        lastVideoPTS = nil
        lastEncodedVideoBuffer = nil
        lastScreenFrameStatus = nil
        recoveryGeneration = 0
        microphone.stop()
        healthSnapshot.withLock { $0 = RecordingHealthSnapshot() }
    }

    private func streamConfiguration(
        filter: SCContentFilter,
        request: RecordingEngineRequest
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = request.configuration.capturesPrimaryAudio
        configuration.sampleRate = Int(RecordingAudioTranscoder.sampleRate)
        configuration.channelCount = Int(RecordingAudioTranscoder.channels)
        configuration.excludesCurrentProcessAudio = true
        if request.configuration.microphone.isEnabled {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = request.configuration.microphone.deviceID
        }
        configuration.showsCursor = request.configuration.capturesVideo && request.configuration.video.showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        if request.configuration.mode == .application {
            configuration.backgroundColor = applicationBackgroundColor
        }
        if let sourceRect = request.sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            configuration.sourceRect = sourceRect
        }
        let size = outputSize(filter: filter, sourceRect: request.sourceRect)
        configuration.width = size.width
        configuration.height = size.height
        if request.configuration.capturesVideo {
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(request.configuration.video.effectiveFrameRate))
        } else {
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
        }
        return configuration
    }

    private func outputSize(filter: SCContentFilter, sourceRect: CGRect?) -> (width: Int, height: Int) {
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let rect = sourceRect ?? filter.contentRect
        return (currentRequest?.configuration.video ?? RecordingVideoSettings()).outputSize(
            for: CGSize(width: rect.width * scale, height: rect.height * scale)
        )
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

    private func sessionPTS(from samplePTS: CMTime?) -> CMTime {
        let raw: CMTime
        if let samplePTS, samplePTS.isValid, samplePTS.isNumeric {
            raw = samplePTS
        } else {
            raw = CMClockGetTime(hostClock)
        }
        if hostOrigin == nil {
            hostOrigin = raw
        }
        let global = CMTimeSubtract(CMTimeSubtract(raw, hostOrigin ?? raw), pauseOffset)
        return CMTimeMaximum(.zero, CMTimeSubtract(global, segmentGlobalStart))
    }

    private func ensureSessionStarted() {
        guard !didStartSession, let writer, writer.status == .writing else { return }
        writer.startSession(atSourceTime: .zero)
        didStartSession = true
    }

    private func appendMicrophoneSample(_ sample: MicrophoneCapturedSample) {
        guard sample.sessionID == sessionID, sample.backendGeneration == captureGeneration else { return }
        appendConvertedAudio(
            sample.sampleBuffer,
            to: microphoneInput,
            source: .microphone,
            capturePTS: sample.capturePTS
        )
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lastVideoCallback = now
        guard !isStopping, !isPaused else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        let status = Self.screenFrameStatus(sampleBuffer)
        let action = RecordingVideoHealth.frameAction(status: status, applicationMode: currentRequest?.configuration.mode == .application)
        let changed = lastScreenFrameStatus != status
        lastScreenFrameStatus = status
        if action == .image { lastCompleteVideoFrame = now }
        if action == .ignore { return }
        if action != .image, !changed, now - lastVideoAppended < 1 { return }
        let pixelBuffer: CVPixelBuffer
        switch action {
        case .image:
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            pixelBuffer = image
        case .repeatImage:
            guard let previous = lastEncodedVideoBuffer else { return }
            pixelBuffer = previous
        case .black:
            guard let black = makeBlackVideoBuffer() else { return }
            pixelBuffer = black
        case .ignore: return
        }
        let frameTime = RecordingVideoHealth.frameTimestamp(
            action: action,
            sampleTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            hostTime: CMClockGetTime(hostClock)
        )
        appendVideoBuffer(pixelBuffer, at: frameTime, now: now)
    }

    private func appendStaticVideoFrame(at now: TimeInterval) {
        guard currentRequest?.configuration.mode == .application, includesVideo,
              !isStopping, !isPaused, now - lastVideoAppended >= 1 else { return }
        let action = RecordingVideoHealth.frameAction(status: lastScreenFrameStatus, applicationMode: true)
        let buffer: CVPixelBuffer?
        switch action {
        case .repeatImage: buffer = lastEncodedVideoBuffer
        case .black: buffer = makeBlackVideoBuffer()
        default: return
        }
        guard let buffer else { return }
        // Static streams may stop sending callbacks entirely. Keep the writer's
        // video track progressing without changing the selected content.
        appendVideoBuffer(buffer, at: CMClockGetTime(hostClock), now: now)
    }

    private func appendVideoBuffer(_ pixelBuffer: CVPixelBuffer, at frameTime: CMTime, now: TimeInterval) {
        guard writer?.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else { return }
        if !didLogVideoFormat {
            didLogVideoFormat = true
            Log.recording.notice(
                "recording video frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) expected=\(videoSize.width)x\(videoSize.height)"
            )
        }
        ensureSessionStarted()
        guard let encodedBuffer = pixelBufferForWriter(pixelBuffer) else { return }
        let pts = sessionPTS(from: frameTime)
        if let lastVideoPTS, pts.seconds <= lastVideoPTS { return }
        if adaptor.append(encodedBuffer, withPresentationTime: pts) {
            didAppendVideo = true
            didAppendMedia = true
            lastVideoAppended = now
            lastVideoPTS = pts.seconds
            lastEncodedVideoBuffer = encodedBuffer
        } else {
            logAppendFailure(kind: "video")
            if writer?.status == .failed {
                rotateWriterLocked(reason: "video append failed")
            }
        }
    }

    private func makeBlackVideoBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        return buffer
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
            if let transfer = pixelTransferSession {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
        }
        guard let session = pixelTransferSession,
              VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            return nil
        }
        return destination
    }

    private enum AudioMeterSource: Hashable {
        case systemAudio
        case microphone
    }

    private func appendConvertedAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        source: AudioMeterSource,
        capturePTS: CMTime? = nil
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let samplePTS = capturePTS ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        mutateHealth(source) { $0.noteReceived(at: now) }
        mutateProgress(source) { $0.noteReceived(at: now, pts: samplePTS) }
        if health(for: source).phase == .healthy, isRecovering {
            isRecovering = false
            emit(.recovered(source: source == .microphone ? "microphone" : "system audio"))
        }
        updateHealthSnapshotLocked()
        guard !isStopping, !isPaused, let input else { return }
        if writer?.status == .failed {
            logAppendFailure(kind: "writer before audio append")
            rotateWriterLocked(reason: "writer failed during audio append")
            return
        }
        guard writer?.status == .writing else { return }

        let timelineTime = sessionPTS(from: samplePTS)
        let sampleDuration = RecordingAudioTranscoder.sampleDuration(sampleBuffer)
        var planned: (silenceFrom: CMTime?, commitPTS: CMTime) = (nil, timelineTime)
        mutateCursor(source) { planned = $0.plan(samplePTS: timelineTime, gapThreshold: RecordingCaptureHealth.gapFillThreshold) }
        if let silenceFrom = planned.silenceFrom {
            appendSilence(to: input, source: source, from: silenceFrom, to: planned.commitPTS, now: now)
        }

        if source == .microphone, isMicrophoneMuted {
            appendSilence(
                to: input,
                source: source,
                from: planned.commitPTS,
                duration: sampleDuration,
                now: now
            )
            return
        }

        let transcoder = source == .systemAudio ? systemAudioTranscoder : microphoneTranscoder
        let converted = transcoder.transcodeAll(sampleBuffer, presentationTime: planned.commitPTS)
        guard !converted.isEmpty else {
            mutateHealth(source) { $0.noteConversionFailure() }
            return
        }
        mutateHealth(source) { $0.noteConverted(at: now) }
        for sample in converted {
            let tick: RecordingAudioMeterTick?
            switch source {
            case .systemAudio:
                tick = systemAudioMeter.append(sample)
            case .microphone:
                tick = microphoneMeter.append(sample)
            }
            if let level = tick?.warningLevel {
                switch source {
                case .systemAudio where !microphoneEnabled:
                    onAudioLevelWarning?(RecordingAudioLevelWarning(track: currentRequest?.configuration.mode == .mobileDevice ? .deviceAudio : .systemAudio, level: level))
                case .microphone where !systemAudioEnabled:
                    onAudioLevelWarning?(RecordingAudioLevelWarning(track: .microphone, level: level))
                default:
                    break
                }
            }
            if commitAudioSample(sample, to: input, source: source, now: now, tick: tick) == false {
                break
            }
        }
    }

    @discardableResult
    private func commitAudioSample(
        _ sample: CMSampleBuffer,
        to input: AVAssetWriterInput,
        source: AudioMeterSource,
        now: TimeInterval,
        tick: RecordingAudioMeterTick? = nil
    ) -> Bool {
        ensureSessionStarted()
        guard input.isReadyForMoreMediaData else {
            mutateHealth(source) { $0.noteWriterNotReady(at: now) }
            logDroppedSample(source: source)
            updateHealthSnapshotLocked()
            return false
        }
        guard input.append(sample) else {
            mutateHealth(source) { $0.noteAppendFailure() }
            logAppendFailure(kind: source == .systemAudio ? "system audio" : "microphone")
            if writer?.status == .failed {
                rotateWriterLocked(reason: source == .systemAudio ? "system audio append failed" : "microphone append failed")
            }
            return false
        }
        let frames = Int64(CMSampleBufferGetNumSamples(sample))
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        mutateCursor(source) {
            $0.commit(
                start: pts,
                frames: frames,
                sampleRate: RecordingAudioTranscoder.sampleRate
            )
        }
        mutateHealth(source) { $0.noteCommitted(at: now) }
        mutateProgress(source) { $0.noteCommitted(at: now, pts: pts, frames: frames) }
        didAppendMedia = true
        switch source {
        case .systemAudio:
            if !didAppendSystemAudio {
                Log.recording.notice("recording system audio sample appended")
            }
            didAppendSystemAudio = true
        case .microphone:
            if !didAppendMicrophone {
                Log.recording.notice("recording microphone sample appended")
            }
            didAppendMicrophone = true
        }
        if let tick {
            liveWaveform?.ingest(peak: tick.peak, at: now)
        }
        updateHealthSnapshotLocked()
        return true
    }

    private func appendTrailingSilence(to input: AVAssetWriterInput, source: AudioMeterSource) {
        let start = cursor(for: source).nextPTS ?? .zero
        appendSilence(
            to: input,
            source: source,
            from: start,
            duration: CMTime(value: 2_048, timescale: 48_000),
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func appendSilence(
        to input: AVAssetWriterInput,
        source: AudioMeterSource,
        from start: CMTime,
        duration: CMTime,
        now: TimeInterval
    ) {
        guard duration.isNumeric, duration.seconds > 0 else { return }
        appendSilence(to: input, source: source, from: start, to: CMTimeAdd(start, duration), now: now)
    }

    private func appendSilence(
        to input: AVAssetWriterInput,
        source: AudioMeterSource,
        from start: CMTime,
        to end: CMTime,
        now: TimeInterval
    ) {
        var pts = start
        let chunk = CMTime(seconds: 0.5, preferredTimescale: 48_000)
        while CMTimeCompare(pts, end) < 0 {
            let remaining = CMTimeSubtract(end, pts)
            let duration = CMTimeMinimum(remaining, chunk)
            let frames = AVAudioFrameCount(max(1, (duration.seconds * RecordingAudioTranscoder.sampleRate).rounded()))
            guard let sample = RecordingAudioTranscoder.makeSilentSampleBuffer(
                frameCount: frames,
                presentationTime: pts
            ) else {
                break
            }
            guard commitAudioSample(sample, to: input, source: source, now: now) else { break }
            pts = cursor(for: source).nextPTS ?? CMTimeAdd(pts, CMTime(value: CMTimeValue(frames), timescale: 48_000))
        }
    }

    private func flushTranscodersLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        if let input = systemAudioInput {
            let pts = systemAudioCursor.nextPTS ?? sessionPTS(from: nil)
            for pcm in systemAudioTranscoder.flushAll() {
                if let sample = RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: pts) {
                    _ = commitAudioSample(sample, to: input, source: .systemAudio, now: now)
                }
            }
        }
        if let input = microphoneInput {
            let pts = microphoneCursor.nextPTS ?? sessionPTS(from: nil)
            for pcm in microphoneTranscoder.flushAll() {
                if let sample = RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: pts) {
                    _ = commitAudioSample(sample, to: input, source: .microphone, now: now)
                }
            }
        }
    }

    private func health(for source: AudioMeterSource) -> RecordingHealthMachine {
        switch source {
        case .systemAudio: systemAudioHealth
        case .microphone: microphoneHealth
        }
    }

    private func cursor(for source: AudioMeterSource) -> RecordingAudioCursor {
        switch source {
        case .systemAudio: systemAudioCursor
        case .microphone: microphoneCursor
        }
    }

    // Mutable accessors keep copies from the getters above from being discarded.
    private func setHealth(_ source: AudioMeterSource, _ value: RecordingHealthMachine) {
        switch source {
        case .systemAudio: systemAudioHealth = value
        case .microphone: microphoneHealth = value
        }
    }

    private func mutateHealth(_ source: AudioMeterSource, _ body: (inout RecordingHealthMachine) -> Void) {
        var value = health(for: source)
        body(&value)
        setHealth(source, value)
    }

    private func mutateProgress(_ source: AudioMeterSource, _ body: (inout RecordingTrackProgress) -> Void) {
        switch source {
        case .systemAudio: body(&systemAudioProgress)
        case .microphone: body(&microphoneProgress)
        }
    }

    private func mutateCursor(_ source: AudioMeterSource, _ body: (inout RecordingAudioCursor) -> Void) {
        switch source {
        case .systemAudio: body(&systemAudioCursor)
        case .microphone: body(&microphoneCursor)
        }
    }

    private static func screenFrameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first else {
            return nil
        }
        if let rawValue = first[.status] as? Int, let status = SCFrameStatus(rawValue: rawValue) {
            return status
        }
        return nil
    }

    private func logAppendFailure(kind: String) {
        guard !didLogWriterAppendFailure else { return }
        didLogWriterAppendFailure = true
        if let error = writer?.error {
            Log.recording.error(
                "recording append failed kind=\(kind) error=\(Log.detail(error)) session=\(sessionID.uuidString) backend=\(captureBackend)",
                telemetry: "Recording append failed"
            )
        } else {
            Log.recording.error(
                "recording append failed kind=\(kind) writerStatus=\(writer?.status.rawValue ?? -1) session=\(sessionID.uuidString) backend=\(captureBackend)",
                telemetry: "Recording append failed"
            )
        }
    }

    private func logDroppedSample(source: AudioMeterSource) {
        let count = source == .systemAudio ? systemAudioHealth.dropped : microphoneHealth.dropped
        guard count == 1 || count.isMultiple(of: 50) else { return }
        Log.recording.warning(
            "recording writer not ready dropped=\(count) source=\(source == .systemAudio ? "system audio" : "microphone") session=\(sessionID.uuidString)"
        )
    }

    private func logWriterFailure(_ phase: String) {
        if let error = writer?.error {
            Log.recording.error(
                "recording writer failed phase=\(phase) error=\(Log.detail(error)) session=\(sessionID.uuidString) backend=\(captureBackend)",
                telemetry: "Recording writer failed"
            )
        } else {
            Log.recording.error(
                "recording writer failed phase=\(phase) status=\(writer?.status.rawValue ?? -1) session=\(sessionID.uuidString) backend=\(captureBackend)",
                telemetry: "Recording writer failed"
            )
        }
    }

    private func handleMicrophoneEventLocked(_ event: MicrophoneCaptureEvent, generation: UInt64) {
        guard generation == captureGeneration else { return }
        switch event {
        case .recovering(let message):
            isRecovering = true
            microphoneHealth.noteRestartAttempt(at: ProcessInfo.processInfo.systemUptime)
            updateHealthSnapshotLocked()
            emit(.recovering(source: "microphone", message: message))
        case .recovered:
            isRecovering = microphoneHealth.phase != .healthy
            if microphoneHealth.phase == .healthy {
                emit(.recovered(source: "microphone"))
            }
        case .failed(let error):
            emit(.failed(error: error, reason: "microphone"))
        }
    }

    private func recoverAfterInterruptionLocked(reason: String) {
        if microphoneEnabled, currentRequest?.configuration.requiresScreenCapture != true {
            microphoneHealth.noteRestartAttempt(at: ProcessInfo.processInfo.systemUptime)
            microphone.recover()
        }
        if stream != nil {
            recoverStreamLocked(reason: reason, streamStopped: false)
        }
        updateHealthSnapshotLocked()
    }

    private func recoverStreamLocked(reason: String, streamStopped: Bool) {
        guard !isStopping, let request = currentRequest else { return }
        guard !isRecoveringStream else { return }
        streamRecoveryAttempts += 1
        if streamRecoveryAttempts > 3 {
            emit(
                .failed(
                    error: .captureInterrupted("System audio capture stopped and could not be restored. The recording so far was saved."),
                    reason: reason
                )
            )
            return
        }
        isRecovering = true
        isRecoveringStream = true
        recoveryGeneration += 1
        let recGen = recoveryGeneration
        let generation = captureGeneration
        emit(.recovering(source: "stream", message: "Reconnecting capture…"))
        Log.recording.notice(
            "recording stream recovering reason=\(reason) attempt=\(streamRecoveryAttempts) session=\(sessionID.uuidString)"
        )
        let displayID = currentDisplayID
        let recoveringStream = streamStopped ? nil : stream
        nonisolated(unsafe) let previousFilter = contentFilter ?? request.contentFilter
        Task { [weak self] in
            guard let self else { return }
            do {
                let filter = try await self.rebuildContentFilter(request: request, displayID: displayID, previousFilter: previousFilter)
                var recreate = recoveringStream == nil
                if let recoveringStream {
                    do { try await recoveringStream.updateContentFilter(filter) }
                    catch { recreate = true }
                }
                let needsRecreation = recreate
                self.queue.async {
                    guard self.recoveryGeneration == recGen, self.captureGeneration == generation, !self.isStopping else { return }
                    self.contentFilter = filter
                    if needsRecreation {
                        self.recreateStreamLocked(reason: reason, request: request, generation: generation, filter: filter)
                        return
                    }
                    self.isRecoveringStream = false
                    self.emit(.recovering(source: "stream", message: "Waiting for capture audio…"))
                }
            } catch let lost as RecordingError where lost == .captureTargetUnavailable || lost == .captureApplicationsUnavailable {
                self.queue.async {
                    guard self.recoveryGeneration == recGen, self.captureGeneration == generation else { return }
                    self.isRecoveringStream = false
                    self.emit(.captureTargetLost(message: lost.localizedDescription))
                    self.emit(.failed(error: lost, reason: "capture target lost"))
                }
            } catch {
                self.queue.async {
                    guard self.recoveryGeneration == recGen, self.captureGeneration == generation, !self.isStopping else { return }
                    self.isRecoveringStream = false
                    self.emit(.failed(error: .captureInterrupted("Capture stopped and could not be restored. The recording so far was saved."), reason: reason))
                }
            }
        }
    }

    private func recreateStreamLocked(reason: String, request: RecordingEngineRequest, generation: UInt64, filter: SCContentFilter) {
        let old = stream
        stream = nil
        old?.stopCapture { _ in }
        do {
            try startStreamLocked(filter: filter, request: request, generation: generation)
        } catch {
            isRecoveringStream = false
            emit(
                .failed(
                    error: .captureInterrupted("Capture stopped and could not be restored. The recording so far was saved."),
                    reason: reason
                )
            )
        }
    }

    private func rebuildContentFilter(request: RecordingEngineRequest, displayID: UInt32?, previousFilter: SCContentFilter?) async throws -> SCContentFilter {
        if request.configuration.mode == .application {
            guard let selection = request.applicationSelection else { throw RecordingError.captureApplicationsUnavailable }
            let content = try await RecordingPermission.shareableContent(includeOffscreenWindows: true)
            return try RecordingApplicationContent.filter(selection: selection, content: content, requireAll: false)
        }
        // A window filter stays window-scoped when reconnecting.
        if request.configuration.mode == .window, let previousFilter { return previousFilter }
        let content = try await RecordingPermission.shareableContent()
        guard let displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.captureTargetUnavailable
        }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    private func startHealthMonitorLocked() {
        stopHealthMonitorLocked()
        let timer = DispatchSource.makeTimerSource(queue: supervisorQueue)
        timer.schedule(
            deadline: .now() + RecordingCaptureHealth.checkInterval,
            repeating: RecordingCaptureHealth.checkInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkHealthFromSupervisor()
        }
        timer.resume()
        healthTimer = timer
        updateHealthSnapshotLocked()
    }

    private func stopHealthMonitorLocked() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func checkHealthFromSupervisor() {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = healthSnapshot.withLock { $0 }
        if snapshot.isStopping { return }
        if let deadline = snapshot.failureDeadline, now >= deadline, !snapshot.isHealthy {
            queue.async { [weak self] in
                self?.emit(
                    .failed(
                        error: .captureInterrupted("Recording stopped receiving audio. The recording so far was saved."),
                        reason: "supervisor deadline"
                    )
                )
            }
            return
        }
        queue.async { [weak self] in
            self?.checkHealthLocked()
        }
    }

    private func checkHealthLocked() {
        guard !isStopping, writer != nil else { return }
        if let diskError = Self.criticalDiskSpaceError(at: outputURL ?? currentRequest?.outputURL) {
            emit(.failed(error: diskError, reason: "disk space"))
            return
        }
        if !didWarnDiskSpace, Self.isDiskSpaceLow(at: outputURL ?? currentRequest?.outputURL) {
            didWarnDiskSpace = true
            emit(.recovering(source: "disk", message: "Disk space is running low."))
            Log.recording.warning("recording disk space low session=\(sessionID.uuidString)")
        }
        guard !isPaused, let started = captureStartedAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        appendStaticVideoFrame(at: now)
        applyHealthDecision(
            microphoneHealth.evaluate(at: now, startedAt: started, enabled: microphoneEnabled),
            source: "microphone",
            now: now
        )
        applyHealthDecision(
            systemAudioHealth.evaluate(at: now, startedAt: started, enabled: systemAudioEnabled,
                                       allowsIdleSource: currentRequest?.configuration.mode == .mobileDevice),
            source: "system audio",
            now: now
        )
        if includesVideo,
           lastCompleteVideoFrame > 0,
           lastVideoAppended > 0,
           RecordingVideoHealth.shouldFail(now: now, lastCallback: lastVideoCallback,
                                          lastCompleteFrame: lastCompleteVideoFrame, lastAppend: lastVideoAppended,
                                          frameAction: RecordingVideoHealth.frameAction(status: lastScreenFrameStatus,
                                              applicationMode: currentRequest?.configuration.mode == .application)),
           (currentRequest?.configuration.mode == .mobileDevice
            || (!microphoneEnabled && !systemAudioEnabled)
            || (microphoneEnabled && now - microphoneHealth.lastReceived <= RecordingCaptureHealth.stallTimeout)
            || (systemAudioEnabled && now - systemAudioHealth.lastReceived <= RecordingCaptureHealth.stallTimeout)) {
            emit(
                .failed(
                    error: .captureInterrupted("Recording stopped receiving video. The recording so far was saved."),
                    reason: "video freeze"
                )
            )
        }
        updateHealthSnapshotLocked()
    }

    private func applyHealthDecision(_ decision: RecordingHealthMachine.Decision, source: String, now: TimeInterval) {
        switch decision {
        case .none:
            break
        case .restartCapture(let reason):
            isRecovering = true
            emit(.recovering(source: source, message: "Recording lost the audio feed. Reconnecting…"))
            Log.recording.warning(
                "recording capture stalled source=\(source) reason=\(reason) session=\(sessionID.uuidString)"
            )
            if source == "microphone" {
                microphoneHealth.noteRestartAttempt(at: now)
                microphone.recover()
            } else if currentRequest?.configuration.mode == .mobileDevice {
                emit(.failed(error: .captureInterrupted("Device audio stopped. Unlock or reconnect your device. The recording so far was saved."), reason: reason))
            } else {
                recoverStreamLocked(reason: reason, streamStopped: false)
            }
        case .rolloverWriter(let reason):
            emit(.recovering(source: "writer", message: "Recording hit a write delay and continued in a new file."))
            rotateWriterLocked(reason: "\(source) \(reason)")
        case .rebuildConverter(let reason):
            if source == "microphone" {
                microphoneTranscoder.reset()
            } else {
                systemAudioTranscoder.reset()
            }
            Log.recording.warning("recording converter rebuilt source=\(source) reason=\(reason)")
        case .fail(let reason):
            emit(
                .failed(
                    error: .captureInterrupted("Recording stopped receiving audio. The recording so far was saved."),
                    reason: "\(source) \(reason)"
                )
            )
        }
    }

    private func rotateWriterLocked(reason: String) {
        guard !isStopping, let request = currentRequest, let currentURL = outputURL else { return }
        Log.recording.error(
            "recording rotating writer reason=\(reason) session=\(sessionID.uuidString) path=\(currentURL.lastPathComponent) error=\(writer?.error.map(Log.detail) ?? "none")"
        )
        let localDuration = max(
            microphoneCursor.nextPTS?.seconds ?? 0,
            systemAudioCursor.nextPTS?.seconds ?? 0
        )
        if didAppendMedia {
            sealedSegments.append(
                RecordingWriterSegment(
                    index: segmentIndex,
                    url: currentURL,
                    globalStart: segmentGlobalStart.seconds,
                    localDuration: localDuration,
                    status: RecordingSessionManifest.rawSaved,
                    didAppendMedia: didAppendMedia,
                    didAppendVideo: didAppendVideo,
                    didAppendMicrophone: didAppendMicrophone,
                    didAppendSystemAudio: didAppendSystemAudio
                )
            )
        }
        preserveOutputIfNeeded(url: currentURL, reason: reason, status: RecordingSessionManifest.rawSaved)
        let oldWriter = writer
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pixelBufferAdaptor = nil
        writer = nil
        microphoneCursor = RecordingAudioCursor()
        systemAudioCursor = RecordingAudioCursor()
        didStartSession = false
        didAppendMedia = false
        didAppendVideo = false
        didAppendMicrophone = false
        didAppendSystemAudio = false
        segmentGlobalStart = CMTimeAdd(segmentGlobalStart, CMTime(seconds: localDuration, preferredTimescale: 48_000))
        segmentIndex += 1
        let nextURL = makeSegmentURL(from: currentURL)
        do {
            try installWriterLocked(url: nextURL, request: request)
            writeJournal(status: RecordingSessionManifest.capturing)
            emit(.recovering(source: "writer", message: "Recording hit a write error and continued in a new file."))
        } catch {
            outputURL = currentURL
            emit(
                .failed(
                    error: .writerFailed(error.localizedDescription),
                    reason: reason
                )
            )
        }
        oldWriter?.finishWriting { [weak self] in
            Log.recording.notice("recording previous segment finished path=\(currentURL.lastPathComponent)")
            if let oldWriter {
                self?.queue.async {
                    self?.releaseOrphanedWriter(oldWriter)
                }
            }
        }
        if let oldWriter {
            orphanedWriters.append(oldWriter)
        }
    }

    private func makeSegmentURL(from base: URL) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-seg\(segmentIndex)")
            .appendingPathExtension(base.pathExtension)
    }

    private func preserveOutputIfNeeded(url: URL, reason: String, status: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let note = url.appendingPathExtension("error.txt")
        try? "\(reason)\nsession=\(sessionID.uuidString)\nbackend=\(captureBackend)\n"
            .write(to: note, atomically: true, encoding: .utf8)
        writeJournal(status: status, outputURL: url)
        Log.recording.error(
            "recording preserving output path=\(url.lastPathComponent) reason=\(reason) session=\(sessionID.uuidString)"
        )
    }

    @discardableResult
    private func writeJournal(
        status: String,
        outputURL: URL? = nil,
        sessionID: UUID? = nil,
        urls: [URL]? = nil,
        warnings: [String]? = nil
    ) -> Bool {
        let outputURL = outputURL ?? self.outputURL
        guard let outputURL else { return false }
        var segments = sealedSegments.map(\.journalSegment)
        if let urls {
            for (index, url) in urls.enumerated() where !segments.contains(where: { $0.path == url.path }) {
                segments.append(
                    RecordingJournalSegment(
                        index: index,
                        path: url.path,
                        globalStart: 0,
                        localDuration: nil,
                        status: status,
                        didAppendMedia: true,
                        didAppendVideo: includesVideo,
                        didAppendMicrophone: microphoneEnabled,
                        didAppendSystemAudio: systemAudioEnabled
                    )
                )
            }
        }
        let manifest = RecordingSessionManifest(
            sessionID: (sessionID ?? self.sessionID).uuidString,
            startedAt: Date(),
            outputPath: outputURL.path,
            mode: currentRequest?.configuration.mode.rawValue ?? sessionManifest?.mode ?? "unknown",
            backend: captureBackend,
            deviceID: currentRequest?.configuration.microphone.deviceID,
            status: status,
            segments: segments,
            includesVideo: includesVideo,
            audioTrackCount: audioTrackCount,
            warnings: warnings,
            stopReason: pendingStopReason.logLabel,
            recordingKind: currentRequest?.configuration.recordingKind ?? sessionManifest?.recordingKind,
            sessionProjectID: currentRequest?.configuration.sessionProjectID ?? sessionManifest?.sessionProjectID
        )
        sessionManifest = manifest
        let ok = RecordingSessionManifest.write(manifest)
        if !ok {
            Log.recording.error(
                "recording journal persist failed session=\(manifest.sessionID) status=\(status)",
                telemetry: "Recording journal persist failed"
            )
        }
        return ok
    }

    private func makeDiagnosticsLocked(reason: RecordingStopReason) -> RecordingSessionDiagnostics {
        RecordingSessionDiagnostics(
            microphone: microphoneMeter.snapshot,
            systemAudio: systemAudioMeter.snapshot,
            lastMicrophoneReceivePTS: microphoneProgress.lastReceivedPTS,
            lastMicrophoneAppendPTS: microphoneProgress.lastCommittedPTS,
            lastSystemAudioReceivePTS: systemAudioProgress.lastReceivedPTS,
            lastSystemAudioAppendPTS: systemAudioProgress.lastCommittedPTS,
            lastVideoAppendPTS: lastVideoPTS,
            microphoneDropped: microphoneHealth.dropped,
            systemAudioDropped: systemAudioHealth.dropped,
            failedAppends: microphoneHealth.failedAppends + systemAudioHealth.failedAppends,
            conversionFailures: microphoneHealth.conversionFailures + systemAudioHealth.conversionFailures,
            restartCount: microphoneHealth.restartCount + streamRecoveryAttempts,
            segmentCount: sealedSegments.count + (didAppendMedia ? 1 : 0),
            stopReason: reason
        )
    }

    private func updateHealthSnapshotLocked(isStopping: Bool? = nil) {
        let nowStopping = isStopping ?? self.isStopping
        let lastReceived = max(microphoneHealth.lastReceived, systemAudioHealth.lastReceived)
        let lastAppended = max(microphoneHealth.lastAppended, systemAudioHealth.lastAppended)
        let deadline = [microphoneHealth.failureDeadline, systemAudioHealth.failureDeadline].compactMap { $0 }.min()
        let healthy = (!microphoneEnabled || microphoneHealth.phase == .healthy)
            && (!systemAudioEnabled || systemAudioHealth.phase == .healthy)
        healthSnapshot.withLock { snapshot in
            snapshot.sessionID = sessionID
            snapshot.isStopping = nowStopping
            snapshot.isHealthy = healthy
            snapshot.failureDeadline = deadline
            snapshot.lastReceived = lastReceived
            snapshot.lastAppended = lastAppended
        }
    }

    private func emit(_ event: RecordingRuntimeEvent) {
        onRuntimeEvent?(event)
    }

    private static func backendName(for configuration: RecordingCaptureConfiguration) -> String {
        if configuration.mode == .mobileDevice { return "usbDevice" }
        if configuration.requiresScreenCapture {
            return configuration.microphone.isEnabled ? "stream" : "stream-audio"
        }
        if configuration.microphone.deviceID == nil {
            return "engine"
        }
        return "microphone"
    }

    private static func criticalDiskSpaceError(at url: URL?) -> RecordingError? {
        guard let url,
              let bytes = RecordingSessionManifest.availableBytes(at: url.deletingLastPathComponent()),
              bytes < RecordingCaptureHealth.minimumFreeBytes else {
            return nil
        }
        return .diskSpaceLow
    }

    private static func isDiskSpaceLow(at url: URL?) -> Bool {
        guard let url,
              let bytes = RecordingSessionManifest.availableBytes(at: url.deletingLastPathComponent()) else {
            return false
        }
        return bytes < RecordingCaptureHealth.lowFreeBytes
    }

    private static func isUserStopped(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamError.errorDomain && ns.code == SCStreamError.Code.userStopped.rawValue
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, !isStopping else { return }
        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendConvertedAudio(sampleBuffer, to: systemAudioInput, source: .systemAudio)
        case .microphone:
            appendConvertedAudio(sampleBuffer, to: microphoneInput, source: .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            guard stream === self.stream else { return }
            if let startContinuation = self.startContinuation {
                self.startContinuation = nil
                self.discardFailedStartLocked()
                startContinuation.resume(throwing: RecordingPermission.captureStartError(error))
                return
            }
            guard !self.isStopping else { return }
            Log.recording.error(
                "recording stream stopped error=\(Log.detail(error)) session=\(self.sessionID.uuidString) backend=\(self.captureBackend)",
                telemetry: "Recording stream stopped"
            )
            if Self.isUserStopped(error) {
                self.emit(.userStopped)
                return
            }
            self.stream = nil
            self.recoverStreamLocked(reason: Log.detail(error), streamStopped: true)
        }
    }
}
