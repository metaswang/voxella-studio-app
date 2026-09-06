import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneCaptureEngine: @unchecked Sendable {
    private let outputQueue: DispatchQueue
    private let audioEngine = AVAudioEngine()
    private let tapTranscoder = RecordingAudioTranscoder()
    private var onSample: ((CMSampleBuffer) -> Void)?
    private var didInstallEngineTap = false
    private var didLogTapFailure = false
    private var isStoppingCapture = false
    private var configurationRestarts = 0
    private var configurationObserver: NSObjectProtocol?
    private var captureSession: AVCaptureSession?
    private var sessionOutput: AVCaptureAudioDataOutput?
    private var sessionSink: CaptureSessionSink?

    init(outputQueue: DispatchQueue) {
        self.outputQueue = outputQueue
    }

    func start(deviceID: String?, onSample: @escaping (CMSampleBuffer) -> Void) throws {
        stop()
        isStoppingCapture = false
        self.onSample = onSample
        if RecordingAudioDeviceEnumerator.prefersDefaultAudioEngine(explicitUID: deviceID) {
            try startAudioEngine()
        } else {
            guard let deviceID else {
                throw RecordingError.captureFailed("The selected microphone is unavailable.")
            }
            try startCaptureSession(deviceID: deviceID)
        }
    }

    func stop() {
        isStoppingCapture = true
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        removeEngineTapIfNeeded()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        sessionOutput?.setSampleBufferDelegate(nil, queue: nil)
        sessionOutput = nil
        sessionSink = nil
        captureSession = nil
        tapTranscoder.reset()
        onSample = nil
        didLogTapFailure = false
        configurationRestarts = 0
    }

    private func startAudioEngine() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        tapTranscoder.reset()
        try installEngineTap(on: input)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            removeEngineTapIfNeeded()
            throw RecordingError.captureFailed("The selected microphone did not start.")
        }
        observeEngineConfigurationChanges()
        Log.recording.notice(
            "recording microphone started backend=engine device=default rate=\(format.sampleRate) channels=\(format.channelCount)"
        )
    }

    private func removeEngineTapIfNeeded() {
        guard didInstallEngineTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        didInstallEngineTap = false
    }

    private func installEngineTap(on input: AVAudioInputNode) throws {
        removeEngineTapIfNeeded()
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.tapTranscoder.resample(buffer) else {
                self.logTapFailure("resample")
                return
            }
            let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
            guard let sample = RecordingAudioTranscoder.makeSampleBuffer(
                from: converted,
                presentationTime: presentationTime
            ) else {
                self.logTapFailure("sample buffer")
                return
            }
            self.outputQueue.async {
                self.onSample?(sample)
            }
        }
        didInstallEngineTap = true
    }

    private func observeEngineConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleEngineConfigurationChange() {
        outputQueue.async { [weak self] in
            guard let self, !self.isStoppingCapture, self.onSample != nil else { return }
            guard self.configurationRestarts < 2 else {
                Log.recording.error(
                    "recording microphone engine stopped after configuration change",
                    telemetry: "Recording microphone configuration change"
                )
                return
            }
            self.configurationRestarts += 1
            do {
                try self.installEngineTap(on: self.audioEngine.inputNode)
                if !self.audioEngine.isRunning {
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                }
                Log.recording.notice("recording microphone engine restarted after configuration change")
            } catch {
                Log.recording.error(
                    "recording microphone engine restart failed error=\(Log.detail(error))",
                    telemetry: "Recording microphone configuration change"
                )
            }
        }
    }

    private func startCaptureSession(deviceID: String) throws {
        guard let device = RecordingAudioDeviceEnumerator.captureDevice(uniqueID: deviceID) else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.captureFailed("Could not open the selected microphone.")
        }
        guard session.canAddInput(input) else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let sink = CaptureSessionSink { [weak self] sample in
            self?.onSample?(sample)
        }
        output.setSampleBufferDelegate(sink, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        session.addOutput(output)

        captureSession = session
        sessionOutput = output
        sessionSink = sink
        session.startRunning()
        guard session.isRunning else {
            sessionOutput?.setSampleBufferDelegate(nil, queue: nil)
            sessionOutput = nil
            sessionSink = nil
            captureSession = nil
            throw RecordingError.captureFailed("The selected microphone did not start.")
        }
        Log.recording.notice(
            "recording microphone started backend=session device=\(deviceID) name=\(device.localizedName)"
        )
    }

    private func logTapFailure(_ reason: String) {
        guard !didLogTapFailure else { return }
        didLogTapFailure = true
        Log.recording.error(
            "recording microphone tap failed reason=\(reason)",
            telemetry: "Recording microphone tap failed"
        )
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
