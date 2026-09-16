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
    var sessionID: UUID
    var displayID: UInt32?
    var liveWaveform: RecordingLiveWaveformStore
    var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?
    var onRuntimeEvent: (@Sendable (RecordingRuntimeEvent) -> Void)?
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

private struct RecordingTrackHealth {
    var lastReceived: TimeInterval = 0
    var lastAppended: TimeInterval = 0
    var dropped = 0
    var failedAppends = 0
    var conversionFailures = 0

    mutating func reset(at uptime: TimeInterval) {
        lastReceived = uptime
        lastAppended = uptime
        dropped = 0
        failedAppends = 0
        conversionFailures = 0
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
    private var isMicrophoneMuted = false
    private var liveWaveform: RecordingLiveWaveformStore?
    private var onAudioLevelWarning: (@Sendable (RecordingAudioLevelWarning) -> Void)?
    private var onRuntimeEvent: (@Sendable (RecordingRuntimeEvent) -> Void)?
    private var currentRequest: RecordingEngineRequest?
    private var contentFilter: SCContentFilter?
    private var currentDisplayID: UInt32?
    private var captureGeneration: UInt64 = 0
    private var healthTimer: DispatchSourceTimer?
    private var captureStartedAt: TimeInterval?
    private var microphoneHealth = RecordingTrackHealth()
    private var systemAudioHealth = RecordingTrackHealth()
    private var nextAudioPTS: [AudioMeterSource: CMTime] = [:]
    private var completedSegments: [URL] = []
    private var segmentIndex = 0
    private var sessionID = UUID()
    private var captureBackend = "none"
    private var isRecovering = false
    private var stallBeganAt: TimeInterval?
    private var streamRecoveryAttempts = 0
    private var didWarnDiskSpace = false
    private var finishResumed = false
    private var didFinalizeWriter = false
    private var sessionManifest: RecordingSessionManifest?

    func start(_ request: RecordingEngineRequest) async throws {
        try await Self.withTimeout(seconds: RecordingLifecycleTimeout.start) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.queue.async {
                        do {
                            try self.beginLocked(request, continuation: continuation)
                        } catch {
                            self.resetLocked()
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                self.queue.async {
                    self.cancelStartLocked()
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
            let now = ProcessInfo.processInfo.systemUptime
            self.microphoneHealth.lastReceived = now
            self.microphoneHealth.lastAppended = now
            self.systemAudioHealth.lastReceived = now
            self.systemAudioHealth.lastAppended = now
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
            self.recoverAfterInterruptionLocked(reason: "system wake")
        }
    }

    func handleDisplayChange() {
        queue.async { [weak self] in
            guard let self, !self.isStopping, self.stream != nil else { return }
            self.recoverStreamLocked(reason: "display change")
        }
    }

    func stop() async throws -> RecordingStopResult {
        try await Self.withTimeout(seconds: RecordingLifecycleTimeout.stop) {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    self.finishLocked(discard: false, continuation: continuation)
                }
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
        if let diskError = Self.criticalDiskSpaceError(at: request.outputURL) {
            throw diskError
        }

        resetLocked()
        captureGeneration += 1
        let generation = captureGeneration
        currentRequest = request
        contentFilter = request.contentFilter
        currentDisplayID = request.displayID
        sessionID = request.sessionID
        includesVideo = request.configuration.capturesVideo
        microphoneEnabled = request.configuration.microphone.isEnabled
        systemAudioEnabled = request.configuration.capturesSystemAudio
        liveWaveform = request.liveWaveform
        onAudioLevelWarning = request.onAudioLevelWarning
        onRuntimeEvent = request.onRuntimeEvent

        var audioTracks = 0
        if request.configuration.capturesSystemAudio { audioTracks += 1 }
        if request.configuration.microphone.isEnabled { audioTracks += 1 }
        audioTrackCount = audioTracks
        let writerURL = request.outputURL
        outputURL = writerURL
        try FileManager.default.createDirectory(
            at: writerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try installWriterLocked(url: writerURL, request: request)
        startContinuation = continuation
        captureBackend = Self.backendName(for: request.configuration)
        writeManifest(status: RecordingSessionManifest.inProgress)

        let usesStreamMicrophone = request.configuration.microphone.isEnabled
            && request.configuration.requiresScreenCapture
        if request.configuration.microphone.isEnabled, !usesStreamMicrophone {
            try microphone.start(
                deviceID: request.configuration.microphone.deviceID,
                onSample: { [weak self] sample in
                    self?.appendConvertedAudio(sample, to: self?.microphoneInput, source: .microphone)
                },
                onEvent: { [weak self] event in
                    self?.handleMicrophoneEventLocked(event)
                }
            )
        }

        if request.configuration.requiresScreenCapture {
            guard let filter = request.contentFilter else {
                throw RecordingError.noDisplay
            }
            try startStreamLocked(filter: filter, request: request, generation: generation)
        } else {
            handleStartResultLocked(nil, generation: generation)
        }
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
        writer.startSession(atSourceTime: .zero)
        didStartSession = true
        self.writer = writer
        outputURL = url
    }

    private func startStreamLocked(
        filter: SCContentFilter,
        request: RecordingEngineRequest,
        generation: UInt64
    ) throws {
        let configuration = streamConfiguration(filter: filter, request: request)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if request.configuration.capturesSystemAudio {
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
                resetLocked()
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
            } else if let request = currentRequest {
                recreateStreamLocked(reason: Log.detail(error), request: request, generation: generation)
            }
            return
        }
        isRecovering = false
        stallBeganAt = nil
        let now = ProcessInfo.processInfo.systemUptime
        microphoneHealth.lastReceived = now
        microphoneHealth.lastAppended = now
        systemAudioHealth.lastReceived = now
        systemAudioHealth.lastAppended = now
        emit(.recovered(source: "stream"))
    }

    private func cancelStartLocked() {
        guard startContinuation != nil else { return }
        captureGeneration += 1
        let continuation = startContinuation
        startContinuation = nil
        resetLocked()
        continuation?.resume(throwing: RecordingError.cancelled)
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
        captureGeneration += 1
        stopHealthMonitorLocked()
        finishResumed = false
        didFinalizeWriter = false
        let resume: @Sendable (Result<RecordingStopResult, RecordingError>) -> Void = { [weak self] result in
            self?.queue.async {
                guard let self, !self.finishResumed else { return }
                self.finishResumed = true
                switch result {
                case .success(let stopResult):
                    continuation?.resume(returning: stopResult)
                    discarded?(.success(stopResult))
                case .failure(let error):
                    continuation?.resume(throwing: error)
                    discarded?(.failure(error))
                }
            }
        }
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: RecordingError.cancelled)
        }
        microphone.stop()
        flushTranscodersLocked()
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
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.isStopping, self.writer != nil, !self.finishResumed else { return }
                completeWriter()
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
        guard !didFinalizeWriter else { return }
        didFinalizeWriter = true
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
            RecordingSessionManifest.remove(for: outputURL)
            for url in completedSegments {
                try? FileManager.default.removeItem(at: url)
                RecordingSessionManifest.remove(for: url)
            }
            resetLocked()
            resume(.failure(.cancelled))
            return
        }

        if writer.status == .failed {
            logWriterFailure("before finish")
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            preserveOutputIfNeeded(url: outputURL, reason: message)
            completePreservedOutput(
                currentURL: outputURL,
                includesVideo: includesVideo,
                audioTrackCount: audioTrackCount,
                diagnostics: diagnostics,
                resume: resume,
                fallbackError: .writerFailed(message)
            )
            return
        }

        if !didStartSession || (!didAppendMedia && completedSegments.isEmpty) {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            RecordingSessionManifest.remove(for: outputURL)
            resetLocked()
            resume(.failure(.emptyRecording))
            return
        }

        if includesVideo && !didAppendVideo && completedSegments.isEmpty {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            preserveOutputIfNeeded(url: outputURL, reason: "The recording did not capture any video frames.")
            resetLocked()
            resume(.failure(.writerFailed("The recording did not capture any video frames.")))
            return
        }

        if microphoneEnabled && !didAppendMicrophone {
            Log.recording.warning(
                "recording finished without microphone samples",
                telemetry: "Recording microphone missing"
            )
        }

        if let input = systemAudioInput, !didAppendSystemAudio {
            appendSilence(to: input, at: nextAudioPTS[.systemAudio] ?? .zero)
        }
        if let input = microphoneInput, !didAppendMicrophone {
            appendSilence(to: input, at: nextAudioPTS[.microphone] ?? .zero)
        }

        let includesVideo = self.includesVideo
        let audioTrackCount = self.audioTrackCount
        let didAppendMedia = self.didAppendMedia
        let segments = completedSegments
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
                    segments: segments,
                    diagnostics: diagnostics,
                    resume: resume
                )
            }
        }
        queue.asyncAfter(deadline: .now() + RecordingLifecycleTimeout.writerFinish) { [weak self] in
            guard let self, self.isStopping, !self.finishResumed else { return }
            self.preserveOutputIfNeeded(url: outputURL, reason: "Timed out while finishing the recording.")
            self.completePreservedOutput(
                currentURL: outputURL,
                includesVideo: includesVideo,
                audioTrackCount: audioTrackCount,
                diagnostics: diagnostics,
                resume: resume,
                fallbackError: .writerFailed("Timed out while finishing the recording.")
            )
        }
    }

    private func completeAfterWriterFinished(
        writer: AVAssetWriter,
        outputURL: URL,
        includesVideo: Bool,
        audioTrackCount: Int,
        didAppendMedia: Bool,
        segments: [URL],
        diagnostics: RecordingSessionDiagnostics,
        resume: @escaping @Sendable (Result<RecordingStopResult, RecordingError>) -> Void
    ) {
        guard writer.status == .completed, didAppendMedia || !segments.isEmpty else {
            logWriterFailure("after finish")
            let message = writer.error?.localizedDescription ?? RecordingError.emptyRecording.localizedDescription
            if didAppendMedia || FileManager.default.fileExists(atPath: outputURL.path) {
                preserveOutputIfNeeded(url: outputURL, reason: message)
                completePreservedOutput(
                    currentURL: outputURL,
                    includesVideo: includesVideo,
                    audioTrackCount: audioTrackCount,
                    diagnostics: diagnostics,
                    resume: resume,
                    fallbackError: .writerFailed(message)
                )
                return
            }
            try? FileManager.default.removeItem(at: outputURL)
            RecordingSessionManifest.remove(for: outputURL)
            resetLocked()
            resume(.failure(.writerFailed(message)))
            return
        }
        completePreservedOutput(
            currentURL: outputURL,
            includesVideo: includesVideo,
            audioTrackCount: audioTrackCount,
            diagnostics: diagnostics,
            resume: resume,
            fallbackError: nil
        )
    }

    private func completePreservedOutput(
        currentURL: URL,
        includesVideo: Bool,
        audioTrackCount: Int,
        diagnostics: RecordingSessionDiagnostics,
        resume: @escaping @Sendable (Result<RecordingStopResult, RecordingError>) -> Void,
        fallbackError: RecordingError?
    ) {
        let segments = completedSegments.filter { FileManager.default.fileExists(atPath: $0.path) }
        let currentExists = FileManager.default.fileExists(atPath: currentURL.path)
        var urls = segments
        if currentExists, !urls.contains(currentURL) {
            urls.append(currentURL)
        }
        resetLocked()
        guard !urls.isEmpty else {
            resume(.failure(fallbackError ?? .emptyRecording))
            return
        }
        Task {
            do {
                var resultURL = urls.last ?? currentURL
                if urls.count > 1 {
                    let concatenated = currentURL.deletingLastPathComponent()
                        .appendingPathComponent("\(currentURL.deletingPathExtension().lastPathComponent)-joined")
                        .appendingPathExtension(includesVideo || audioTrackCount >= 2 ? currentURL.pathExtension : "m4a")
                    try await RecordingAudioMixer.concatenate(
                        urls: urls,
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
                        Log.recording.error(
                            "recording audio mix failed error=\(Log.detail(error))",
                            telemetry: "Recording audio mix failed"
                        )
                    }
                }
                RecordingSessionManifest.remove(for: currentURL)
                for url in urls {
                    RecordingSessionManifest.remove(for: url)
                }
                resume(.success(RecordingStopResult(url: resultURL, diagnostics: diagnostics)))
            } catch {
                Log.recording.error(
                    "recording segment join failed error=\(Log.detail(error))",
                    telemetry: "Recording segment join failed"
                )
                let fallback = urls.last ?? currentURL
                RecordingSessionManifest.remove(for: currentURL)
                resume(.success(RecordingStopResult(url: fallback, diagnostics: diagnostics)))
            }
        }
    }

    private func resetLocked() {
        stopHealthMonitorLocked()
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
        isMicrophoneMuted = false
        liveWaveform = nil
        onAudioLevelWarning = nil
        onRuntimeEvent = nil
        currentRequest = nil
        contentFilter = nil
        currentDisplayID = nil
        captureStartedAt = nil
        microphoneHealth = RecordingTrackHealth()
        systemAudioHealth = RecordingTrackHealth()
        nextAudioPTS = [:]
        completedSegments = []
        segmentIndex = 0
        captureBackend = "none"
        isRecovering = false
        stallBeganAt = nil
        streamRecoveryAttempts = 0
        didWarnDiskSpace = false
        finishResumed = false
        didFinalizeWriter = false
        sessionManifest = nil
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
        if request.configuration.microphone.isEnabled {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = request.configuration.microphone.deviceID
        }
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
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
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
        guard !didStartSession, let writer, writer.status == .writing else { return }
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
            if writer?.status == .failed {
                rotateWriterLocked(reason: "video append failed")
            }
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

    private enum AudioMeterSource: Hashable {
        case systemAudio
        case microphone
    }

    private func appendConvertedAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        source: AudioMeterSource
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        switch source {
        case .systemAudio: systemAudioHealth.lastReceived = now
        case .microphone: microphoneHealth.lastReceived = now
        }
        guard !isStopping, !isPaused, let input else { return }
        if writer?.status == .failed {
            rotateWriterLocked(reason: "writer failed during audio append")
            return
        }
        guard writer?.status == .writing else { return }

        let timelineTime = writerPTS()
        let sampleDuration = RecordingAudioTranscoder.sampleDuration(sampleBuffer)
        var pts = timelineTime
        if let next = nextAudioPTS[source] {
            let gap = CMTimeSubtract(timelineTime, next)
            if gap.isNumeric, gap.seconds >= RecordingCaptureHealth.gapFillThreshold {
                appendSilence(to: input, from: next, to: timelineTime)
                pts = timelineTime
            } else {
                pts = next
            }
        }

        if source == .microphone, isMicrophoneMuted {
            appendSilence(to: input, from: pts, duration: sampleDuration)
            nextAudioPTS[source] = CMTimeAdd(pts, sampleDuration)
            microphoneHealth.lastAppended = now
            return
        }

        let transcoder = source == .systemAudio ? systemAudioTranscoder : microphoneTranscoder
        guard let converted = transcoder.transcode(sampleBuffer, presentationTime: pts) else {
            switch source {
            case .systemAudio: systemAudioHealth.conversionFailures += 1
            case .microphone: microphoneHealth.conversionFailures += 1
            }
            return
        }
        let tick: RecordingAudioMeterTick?
        switch source {
        case .systemAudio:
            tick = systemAudioMeter.append(converted)
        case .microphone:
            tick = microphoneMeter.append(converted)
        }
        if let level = tick?.warningLevel {
            switch source {
            case .systemAudio where !microphoneEnabled:
                onAudioLevelWarning?(RecordingAudioLevelWarning(track: .systemAudio, level: level))
            case .microphone where !systemAudioEnabled:
                onAudioLevelWarning?(RecordingAudioLevelWarning(track: .microphone, level: level))
            default:
                break
            }
        }
        ensureSessionStarted()
        guard input.isReadyForMoreMediaData else {
            switch source {
            case .systemAudio: systemAudioHealth.dropped += 1
            case .microphone: microphoneHealth.dropped += 1
            }
            logDroppedSample(source: source)
            return
        }
        if input.append(converted) {
            didAppendMedia = true
            if let tick {
                liveWaveform?.ingest(peak: tick.peak, at: ProcessInfo.processInfo.systemUptime)
            }
            let duration = CMTime(
                value: CMTimeValue(CMSampleBufferGetNumSamples(converted)),
                timescale: CMTimeScale(RecordingAudioTranscoder.sampleRate)
            )
            nextAudioPTS[source] = CMTimeAdd(pts, duration)
            switch source {
            case .systemAudio:
                if !didAppendSystemAudio {
                    Log.recording.notice("recording system audio sample appended")
                }
                didAppendSystemAudio = true
                systemAudioHealth.lastAppended = now
            case .microphone:
                if !didAppendMicrophone {
                    Log.recording.notice("recording microphone sample appended")
                }
                didAppendMicrophone = true
                microphoneHealth.lastAppended = now
            }
        } else {
            switch source {
            case .systemAudio: systemAudioHealth.failedAppends += 1
            case .microphone: microphoneHealth.failedAppends += 1
            }
            logAppendFailure(kind: source == .systemAudio ? "system audio" : "microphone")
            if writer?.status == .failed {
                rotateWriterLocked(reason: source == .systemAudio ? "system audio append failed" : "microphone append failed")
            }
        }
    }

    private func appendSilence(to input: AVAssetWriterInput, at presentationTime: CMTime) {
        appendSilence(to: input, from: presentationTime, duration: CMTime(value: 2_048, timescale: 48_000))
    }

    private func appendSilence(to input: AVAssetWriterInput, from start: CMTime, duration: CMTime) {
        guard duration.isNumeric, duration.seconds > 0 else { return }
        appendSilence(to: input, from: start, to: CMTimeAdd(start, duration))
    }

    private func appendSilence(to input: AVAssetWriterInput, from start: CMTime, to end: CMTime) {
        var pts = start
        let chunk = CMTime(seconds: 0.5, preferredTimescale: 48_000)
        while CMTimeCompare(pts, end) < 0 {
            let remaining = CMTimeSubtract(end, pts)
            let duration = CMTimeMinimum(remaining, chunk)
            let frames = AVAudioFrameCount(max(1, (duration.seconds * RecordingAudioTranscoder.sampleRate).rounded()))
            guard input.isReadyForMoreMediaData,
                  let sample = RecordingAudioTranscoder.makeSilentSampleBuffer(
                    frameCount: frames,
                    presentationTime: pts
                  ) else {
                break
            }
            ensureSessionStarted()
            if input.append(sample) {
                didAppendMedia = true
                pts = CMTimeAdd(pts, CMTime(value: CMTimeValue(frames), timescale: 48_000))
            } else {
                break
            }
        }
    }

    private func flushTranscodersLocked() {
        if let input = systemAudioInput, let pcm = systemAudioTranscoder.flush() {
            let pts = nextAudioPTS[.systemAudio] ?? writerPTS()
            if let sample = RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: pts) {
                _ = input.append(sample)
            }
        }
        if let input = microphoneInput, let pcm = microphoneTranscoder.flush() {
            let pts = nextAudioPTS[.microphone] ?? writerPTS()
            if let sample = RecordingAudioTranscoder.makeSampleBuffer(from: pcm, presentationTime: pts) {
                _ = input.append(sample)
            }
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

    private func handleMicrophoneEventLocked(_ event: MicrophoneCaptureEvent) {
        switch event {
        case .recovering(let message):
            isRecovering = true
            emit(.recovering(source: "microphone", message: message))
        case .recovered:
            isRecovering = false
            stallBeganAt = nil
            let now = ProcessInfo.processInfo.systemUptime
            microphoneHealth.lastReceived = now
            microphoneHealth.lastAppended = now
            emit(.recovered(source: "microphone"))
        case .failed(let error):
            emit(.failed(error: error, reason: "microphone"))
        }
    }

    private func recoverAfterInterruptionLocked(reason: String) {
        if microphoneEnabled, currentRequest?.configuration.requiresScreenCapture != true {
            microphone.recover()
        }
        if stream != nil {
            recoverStreamLocked(reason: reason)
        }
    }

    private func recoverStreamLocked(reason: String) {
        guard !isStopping, let request = currentRequest else { return }
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
        emit(.recovering(source: "stream", message: "Reconnecting capture…"))
        Log.recording.notice(
            "recording stream recovering reason=\(reason) attempt=\(streamRecoveryAttempts) session=\(sessionID.uuidString)"
        )
        let generation = captureGeneration
        guard currentDisplayID != nil, stream != nil else {
            recreateStreamLocked(reason: reason, request: request, generation: generation)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let filter = try await self.rebuildContentFilter()
                guard let stream = self.stream else { throw RecordingError.noDisplay }
                try await stream.updateContentFilter(filter)
                self.queue.async {
                    guard self.captureGeneration == generation, !self.isStopping else { return }
                    self.contentFilter = filter
                    self.isRecovering = false
                    self.stallBeganAt = nil
                    self.emit(.recovered(source: "stream"))
                }
            } catch {
                self.queue.async {
                    guard self.captureGeneration == generation, !self.isStopping else { return }
                    self.recreateStreamLocked(reason: reason, request: request, generation: generation)
                }
            }
        }
    }

    private func recreateStreamLocked(reason: String, request: RecordingEngineRequest, generation: UInt64) {
        let old = stream
        stream = nil
        old?.stopCapture { _ in }
        guard let filter = contentFilter ?? request.contentFilter else {
            emit(
                .failed(
                    error: .captureInterrupted("Capture stopped and no display is available. The recording so far was saved."),
                    reason: reason
                )
            )
            return
        }
        do {
            try startStreamLocked(filter: filter, request: request, generation: generation)
        } catch {
            emit(
                .failed(
                    error: .captureInterrupted("Capture stopped and could not be restored. The recording so far was saved."),
                    reason: reason
                )
            )
        }
    }

    private func rebuildContentFilter() async throws -> SCContentFilter {
        let content = try await RecordingPermission.shareableContent()
        let display: SCDisplay
        if let displayID = currentDisplayID,
           let match = content.displays.first(where: { $0.displayID == displayID }) {
            display = match
        } else if let first = content.displays.first {
            display = first
            currentDisplayID = first.displayID
        } else {
            throw RecordingError.noDisplay
        }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    private func startHealthMonitorLocked() {
        stopHealthMonitorLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + RecordingCaptureHealth.checkInterval,
            repeating: RecordingCaptureHealth.checkInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkHealthLocked()
        }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthMonitorLocked() {
        healthTimer?.cancel()
        healthTimer = nil
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
        guard now - started > RecordingCaptureHealth.startupGrace else { return }

        var stalled: [String] = []
        if microphoneEnabled {
            if now - microphoneHealth.lastReceived > RecordingCaptureHealth.stallTimeout {
                stalled.append("microphone")
            } else if now - microphoneHealth.lastAppended > RecordingCaptureHealth.stallTimeout {
                stalled.append("microphone write")
            }
        }
        if systemAudioEnabled {
            if now - systemAudioHealth.lastReceived > RecordingCaptureHealth.stallTimeout {
                stalled.append("system audio")
            } else if now - systemAudioHealth.lastAppended > RecordingCaptureHealth.stallTimeout {
                stalled.append("system audio write")
            }
        }
        if stalled.isEmpty {
            if isRecovering {
                isRecovering = false
                emit(.recovered(source: "capture"))
            }
            stallBeganAt = nil
            streamRecoveryAttempts = 0
            return
        }
        if stallBeganAt == nil {
            stallBeganAt = now
            isRecovering = true
            Log.recording.warning(
                "recording capture stalled tracks=\(stalled.joined(separator: ",")) session=\(sessionID.uuidString) backend=\(captureBackend) elapsed=\(now - started) droppedMic=\(microphoneHealth.dropped) droppedSystem=\(systemAudioHealth.dropped)"
            )
            emit(.recovering(source: "capture", message: "Recording lost the audio feed. Reconnecting…"))
            recoverAfterInterruptionLocked(reason: stalled.joined(separator: ","))
        }
        if now - (stallBeganAt ?? now) >= RecordingCaptureHealth.failureTimeout {
            emit(
                .failed(
                    error: .captureInterrupted("Recording stopped receiving audio. The recording so far was saved."),
                    reason: stalled.joined(separator: ",")
                )
            )
        }
    }

    private func rotateWriterLocked(reason: String) {
        guard !isStopping, let request = currentRequest, let currentURL = outputURL else { return }
        Log.recording.error(
            "recording rotating writer reason=\(reason) session=\(sessionID.uuidString) path=\(currentURL.lastPathComponent)"
        )
        preserveOutputIfNeeded(url: currentURL, reason: reason)
        if didAppendMedia {
            completedSegments.append(currentURL)
        }
        let oldWriter = writer
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pixelBufferAdaptor = nil
        writer = nil
        nextAudioPTS = [:]
        didStartSession = false
        segmentIndex += 1
        let nextURL = makeSegmentURL(from: currentURL)
        do {
            try installWriterLocked(url: nextURL, request: request)
            writeManifest(status: RecordingSessionManifest.inProgress)
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
        oldWriter?.finishWriting {
            Log.recording.notice("recording previous segment finished path=\(currentURL.lastPathComponent)")
        }
    }

    private func makeSegmentURL(from base: URL) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-seg\(segmentIndex)")
            .appendingPathExtension(base.pathExtension)
    }

    private func preserveOutputIfNeeded(url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let note = url.appendingPathExtension("error.txt")
        try? "\(reason)\nsession=\(sessionID.uuidString)\nbackend=\(captureBackend)\n"
            .write(to: note, atomically: true, encoding: .utf8)
        writeManifest(status: RecordingSessionManifest.failed)
        Log.recording.error(
            "recording preserving output path=\(url.lastPathComponent) reason=\(reason) session=\(sessionID.uuidString)"
        )
    }

    private func writeManifest(status: String) {
        guard let outputURL else { return }
        let manifest = RecordingSessionManifest(
            sessionID: sessionID.uuidString,
            startedAt: Date(),
            outputPath: outputURL.path,
            mode: currentRequest?.configuration.mode.rawValue ?? "unknown",
            backend: captureBackend,
            deviceID: currentRequest?.configuration.microphone.deviceID,
            status: status
        )
        sessionManifest = manifest
        RecordingSessionManifest.write(manifest)
    }

    private func emit(_ event: RecordingRuntimeEvent) {
        onRuntimeEvent?(event)
    }

    private static func backendName(for configuration: RecordingCaptureConfiguration) -> String {
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

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RecordingError.captureFailed("Recording timed out.")
            }
            guard let result = try await group.next() else {
                throw RecordingError.captureFailed("Recording timed out.")
            }
            group.cancelAll()
            return result
        }
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
            guard let self, stream === self.stream else { return }
            if let startContinuation = self.startContinuation {
                self.startContinuation = nil
                self.resetLocked()
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
            self.recoverStreamLocked(reason: Log.detail(error))
        }
    }
}
