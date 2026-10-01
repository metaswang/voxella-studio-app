import AVFoundation
import CoreMedia
import Foundation
import os

enum MicrophoneCaptureEvent: Sendable {
    case recovering(String)
    case recovered
    case failed(RecordingError)
}

final class MicrophoneCaptureEngine: @unchecked Sendable {
    private let outputQueue: DispatchQueue
    private let captureQueue = DispatchQueue(label: "com.voxella.studio.recording.microphone")
    private let audioEngine = AVAudioEngine()
    private var onSample: ((MicrophoneCapturedSample) -> Void)?
    private var onEvent: ((MicrophoneCaptureEvent) -> Void)?
    private var didInstallEngineTap = false
    private var didLogTapFailure = false
    private var isStoppingCapture = false
    private var consecutiveRestartFailures = 0
    private var restartTimestamps: [TimeInterval] = []
    private var stableSampleCount = 0
    private let pendingTapLock = OSAllocatedUnfairLock(initialState: 0)
    private let droppedTapBuffers = OSAllocatedUnfairLock(initialState: 0)
    private let dropLogScheduled = OSAllocatedUnfairLock(initialState: false)
    private var observers: [NSObjectProtocol] = []
    private var captureSession: AVCaptureSession?
    private var sessionOutput: AVCaptureAudioDataOutput?
    private var sessionSink: CaptureSessionSink?
    private var sessionInput: AVCaptureDeviceInput?
    private var boundDeviceUID: String?
    private var usesCaptureSession = false
    private var isRestarting = false
    private var captureToken: UInt64 = 0
    private var sessionID = UUID()

    private let maxPendingTapBuffers = 24
    private let maxConsecutiveRestartFailures = 5
    private let maxRestartsInWindow = 8
    private let restartWindow: TimeInterval = 30

    init(outputQueue: DispatchQueue) {
        self.outputQueue = outputQueue
    }

    func start(
        sessionID: UUID,
        generation: UInt64,
        deviceID: String?,
        onSample: @escaping (MicrophoneCapturedSample) -> Void,
        onEvent: @escaping (MicrophoneCaptureEvent) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        captureQueue.async { [weak self] in
            guard let self else {
                completion(.failure(RecordingError.captureFailed("The selected microphone is unavailable.")))
                return
            }
            self.stopLocked()
            self.isStoppingCapture = false
            self.sessionID = sessionID
            self.captureToken = generation
            self.onSample = onSample
            self.onEvent = onEvent
            self.boundDeviceUID = deviceID
            do {
                if let deviceID, !deviceID.isEmpty {
                    try self.startCaptureSession(deviceID: deviceID)
                } else {
                    try self.startAudioEngine()
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func recover() {
        captureQueue.async { [weak self] in
            self?.restartCapture(reason: "health stall")
        }
    }

    func stop() {
        isStoppingCapture = true
        captureQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    func fence(generation: UInt64) {
        isStoppingCapture = true
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureToken = generation
            self.onSample = nil
            self.onEvent = nil
        }
    }

    private func stopLocked() {
        removeObservers()
        removeEngineTapIfNeeded()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        sessionOutput?.setSampleBufferDelegate(nil, queue: nil)
        sessionOutput = nil
        sessionSink = nil
        sessionInput = nil
        captureSession = nil
        usesCaptureSession = false
        onSample = nil
        onEvent = nil
        didLogTapFailure = false
        consecutiveRestartFailures = 0
        restartTimestamps = []
        stableSampleCount = 0
        pendingTapLock.withLock { $0 = 0 }
        droppedTapBuffers.withLock { $0 = 0 }
        dropLogScheduled.withLock { $0 = false }
        boundDeviceUID = nil
        isRestarting = false
        captureToken += 1
        isStoppingCapture = true
    }

    private func startAudioEngine() throws {
        isStoppingCapture = false
        usesCaptureSession = false
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        try installEngineTap(on: input)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            removeEngineTapIfNeeded()
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            throw RecordingError.captureFailed("The selected microphone did not start.")
        }
        observeEngineConfigurationChanges()
        let deviceDescription = boundDeviceUID ?? "default"
        Log.recording.notice(
            "recording microphone started backend=engine device=\(deviceDescription) rate=\(format.sampleRate) channels=\(format.channelCount) bound=false"
        )
    }

    private func removeEngineTapIfNeeded() {
        guard didInstallEngineTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        didInstallEngineTap = false
    }

    private func installEngineTap(on input: AVAudioInputNode) throws {
        removeEngineTapIfNeeded()
        let generation = captureToken
        let sessionID = self.sessionID
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, when in
            guard let self, !self.isStoppingCapture else { return }
            let shouldDrop = self.pendingTapLock.withLock { count -> Bool in
                if count >= self.maxPendingTapBuffers {
                    return true
                }
                count += 1
                return false
            }
            if shouldDrop {
                self.droppedTapBuffers.withLock { $0 += 1 }
                self.scheduleDropLogIfNeeded()
                return
            }
            guard let copied = Self.copyPCMBuffer(buffer) else {
                self.pendingTapLock.withLock { $0 = max(0, $0 - 1) }
                self.logTapFailure("copy")
                return
            }
            let presentationTime: CMTime
            if when.isHostTimeValid {
                presentationTime = CMClockMakeHostTimeFromSystemUnits(when.hostTime)
            } else {
                presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
            }
            let handler = self.onSample
            self.outputQueue.async { [weak self] in
                guard let self else { return }
                self.pendingTapLock.withLock { $0 = max(0, $0 - 1) }
                guard generation == self.captureToken, !self.isStoppingCapture else { return }
                self.handleEngineBuffer(
                    copied,
                    presentationTime: presentationTime,
                    sessionID: sessionID,
                    generation: generation,
                    handler: handler
                )
            }
        }
        didInstallEngineTap = true
    }

    private func handleEngineBuffer(
        _ buffer: AVAudioPCMBuffer,
        presentationTime: CMTime,
        sessionID: UUID,
        generation: UInt64,
        handler: ((MicrophoneCapturedSample) -> Void)?
    ) {
        guard generation == captureToken, !isStoppingCapture else { return }
        guard let sample = RecordingAudioTranscoder.makeSampleBuffer(
            from: buffer,
            presentationTime: presentationTime
        ) else {
            logTapFailure("sample buffer")
            return
        }
        noteStableAudio(generation: generation)
        handler?(
            MicrophoneCapturedSample(
                sessionID: sessionID,
                backendGeneration: generation,
                sampleBuffer: sample,
                capturePTS: presentationTime
            )
        )
    }

    private func observeEngineConfigurationChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async {
                self?.restartCapture(reason: "configuration change")
            }
        }
        observers.append(observer)
    }

    private func startCaptureSession(deviceID: String) throws {
        isStoppingCapture = false
        usesCaptureSession = true
        boundDeviceUID = deviceID
        try rebuildCaptureSessionLocked(deviceID: deviceID)
        Log.recording.notice(
            "recording microphone started backend=session device=\(deviceID) name=\(sessionInput?.device.localizedName ?? "unknown")"
        )
    }

    private func rebuildCaptureSessionLocked(deviceID: String) throws {
        removeObservers()
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        sessionOutput?.setSampleBufferDelegate(nil, queue: nil)
        sessionOutput = nil
        sessionSink = nil
        sessionInput = nil
        captureSession = nil

        guard let device = RecordingAudioDeviceEnumerator.captureDevice(uniqueID: deviceID) else {
            throw RecordingError.microphoneUnavailable
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.captureFailed("Could not open the selected microphone.")
        }
        guard session.canAddInput(input) else {
            throw RecordingError.microphoneUnavailable
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let generation = captureToken
        let sessionID = self.sessionID
        let handler = onSample
        let sink = CaptureSessionSink { [weak self] sample in
            guard let self, generation == self.captureToken, !self.isStoppingCapture else { return }
            self.noteStableAudio(generation: generation)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            handler?(
                MicrophoneCapturedSample(
                    sessionID: sessionID,
                    backendGeneration: generation,
                    sampleBuffer: sample,
                    capturePTS: pts.isNumeric ? pts : CMClockGetTime(CMClockGetHostTimeClock())
                )
            )
        }
        output.setSampleBufferDelegate(sink, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw RecordingError.microphoneUnavailable
        }
        session.addOutput(output)

        captureSession = session
        sessionOutput = output
        sessionSink = sink
        sessionInput = input
        session.startRunning()
        guard session.isRunning else {
            sessionOutput?.setSampleBufferDelegate(nil, queue: nil)
            sessionOutput = nil
            sessionSink = nil
            sessionInput = nil
            captureSession = nil
            throw RecordingError.captureFailed("The selected microphone did not start.")
        }
        observeCaptureSession()
    }

    private func observeCaptureSession() {
        let center = NotificationCenter.default
        let session = captureSession
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.captureQueue.async {
                guard let self, !self.isRestarting, !self.isStoppingCapture else { return }
                self.restartCapture(
                    reason: "session runtime error \(error.map(Log.detail) ?? "unknown")"
                )
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionDidStopRunning,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async {
                guard let self, !self.isRestarting, !self.isStoppingCapture else { return }
                self.restartCapture(reason: "session stopped running")
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async {
                guard let self, !self.isRestarting, !self.isStoppingCapture else { return }
                self.emit(.recovering("The microphone was interrupted. Reconnecting…"))
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async {
                guard let self, !self.isRestarting, !self.isStoppingCapture else { return }
                self.restartCapture(reason: "session interruption ended")
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.captureQueue.async {
                guard let self,
                      !self.isRestarting,
                      !self.isStoppingCapture,
                      device.uniqueID == self.boundDeviceUID else { return }
                self.emit(.recovering("The selected microphone disconnected. Waiting for it to return…"))
            }
        })
        observers.append(center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.captureQueue.async {
                guard let self,
                      !self.isRestarting,
                      !self.isStoppingCapture,
                      device.uniqueID == self.boundDeviceUID else { return }
                self.restartCapture(reason: "microphone reconnected")
            }
        })
    }

    private func restartCapture(reason: String) {
        guard !isStoppingCapture, !isRestarting, onSample != nil else { return }
        guard canAttemptRestart() else {
            Log.recording.error(
                "recording microphone engine stopped after \(reason)",
                telemetry: "Recording microphone configuration change"
            )
            emit(.failed(.captureInterrupted("The microphone stopped and could not be restored. The recording so far was saved.")))
            return
        }
        recordRestartAttempt()
        emit(.recovering("Reconnecting the microphone…"))
        Log.recording.notice("recording microphone restarting reason=\(reason)")
        isRestarting = true
        restartCaptureWithBackoff(attempt: 0, reason: reason, token: captureToken)
    }

    private func restartCaptureWithBackoff(attempt: Int, reason: String, token: UInt64) {
        guard !isStoppingCapture, onSample != nil, token == captureToken else { return }
        do {
            if usesCaptureSession {
                guard let deviceID = boundDeviceUID else {
                    throw RecordingError.microphoneUnavailable
                }
                try rebuildCaptureSessionLocked(deviceID: deviceID)
            } else {
                try restartAudioEngineLocked()
            }
            consecutiveRestartFailures = 0
            stableSampleCount = 0
            isRestarting = false
            Log.recording.notice("recording microphone engine restarted after \(reason)")
            emit(.recovering("Waiting for microphone audio…"))
        } catch {
            if attempt >= 6 {
                consecutiveRestartFailures += 1
                isRestarting = false
                Log.recording.error(
                    "recording microphone engine restart failed error=\(Log.detail(error))",
                    telemetry: "Recording microphone configuration change"
                )
                if !canAttemptRestart() {
                    emit(.failed(.captureInterrupted("The microphone stopped and could not be restored. The recording so far was saved.")))
                }
                return
            }
            let delay = min(0.05 * pow(2, Double(attempt)), 1.0)
            captureQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restartCaptureWithBackoff(attempt: attempt + 1, reason: reason, token: token)
            }
        }
    }

    private func restartAudioEngineLocked() throws {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.microphoneUnavailable
        }
        try installEngineTap(on: audioEngine.inputNode)
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func canAttemptRestart() -> Bool {
        if consecutiveRestartFailures >= maxConsecutiveRestartFailures {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        restartTimestamps = restartTimestamps.filter { now - $0 < restartWindow }
        return restartTimestamps.count < maxRestartsInWindow
    }

    private func recordRestartAttempt() {
        restartTimestamps.append(ProcessInfo.processInfo.systemUptime)
    }

    private func noteStableAudio(generation: UInt64) {
        captureQueue.async { [weak self] in
            guard let self, generation == self.captureToken, !self.isStoppingCapture else { return }
            self.stableSampleCount += 1
            if self.stableSampleCount == RecordingCaptureHealth.recoveredSampleCount {
                self.consecutiveRestartFailures = 0
                self.restartTimestamps.removeAll()
                self.emit(.recovered)
            }
        }
    }

    private func emit(_ event: MicrophoneCaptureEvent) {
        let handler = onEvent
        outputQueue.async {
            handler?(event)
        }
    }

    private func logTapFailure(_ reason: String) {
        guard !didLogTapFailure else { return }
        didLogTapFailure = true
        Log.recording.error(
            "recording microphone tap failed reason=\(reason)",
            telemetry: "Recording microphone tap failed"
        )
    }

    private func scheduleDropLogIfNeeded() {
        let shouldLog = dropLogScheduled.withLock { scheduled -> Bool in
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard shouldLog else { return }
        captureQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.dropLogScheduled.withLock { $0 = false }
            let count = self.droppedTapBuffers.withLock { $0 }
            Log.recording.warning(
                "recording microphone tap dropped buffers count=\(count)",
                telemetry: "Recording microphone tap backpressure"
            )
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            let bytes = Int(source[index].mDataByteSize)
            destination[index].mDataByteSize = source[index].mDataByteSize
            guard bytes > 0, let srcData = source[index].mData, let dstData = destination[index].mData else { continue }
            memcpy(dstData, srcData, bytes)
        }
        return copy
    }
}

private final class CaptureSessionSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onSample: (CMSampleBuffer) -> Void

    init(onSample: @escaping (CMSampleBuffer) -> Void) {
        self.onSample = onSample
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample(sampleBuffer)
    }
}
