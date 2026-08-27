import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneCaptureEngine: @unchecked Sendable {
    private let outputQueue: DispatchQueue
    private let audioEngine = AVAudioEngine()
    private var onSample: ((CMSampleBuffer) -> Void)?
    private var didInstallEngineTap = false

    init(outputQueue: DispatchQueue) {
        self.outputQueue = outputQueue
    }

    func start(deviceID: String?, onSample: @escaping (CMSampleBuffer) -> Void) throws {
        stop()
        self.onSample = onSample
        try startAudioEngine(deviceID: deviceID)
    }

    func stop() {
        if didInstallEngineTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallEngineTap = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        onSample = nil
    }

    private func startAudioEngine(deviceID: String?) throws {
        let input = audioEngine.inputNode
        if let deviceID {
            guard let audioDeviceID = RecordingAudioDeviceEnumerator.audioDeviceID(forUID: deviceID) else {
                throw RecordingError.captureFailed("The selected microphone is unavailable.")
            }
            do {
                try input.auAudioUnit.setDeviceID(audioDeviceID)
            } catch {
                throw RecordingError.captureFailed("Could not open the selected microphone.")
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
            guard let sample = RecordingAudioTranscoder.makeSampleBuffer(
                from: buffer,
                presentationTime: presentationTime
            ) else { return }
            self.outputQueue.async {
                self.onSample?(sample)
            }
        }
        didInstallEngineTap = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            didInstallEngineTap = false
            throw RecordingError.captureFailed("The selected microphone did not start.")
        }
        Log.recording.notice(
            "recording microphone started device=\(deviceID ?? "default") rate=\(format.sampleRate) channels=\(format.channelCount)"
        )
    }
}
