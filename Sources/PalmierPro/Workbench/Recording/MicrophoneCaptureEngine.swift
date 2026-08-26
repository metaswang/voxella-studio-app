import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneCaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let outputQueue: DispatchQueue
    private var session: AVCaptureSession?
    private var onSample: ((CMSampleBuffer) -> Void)?
    var isMuted = false

    init(outputQueue: DispatchQueue) {
        self.outputQueue = outputQueue
    }

    func start(deviceID: String?, onSample: @escaping (CMSampleBuffer) -> Void) throws {
        stop()
        self.onSample = onSample
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let device = RecordingAudioDeviceEnumerator.device(id: deviceID) else {
            throw RecordingError.captureFailed("The selected microphone is unavailable.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecordingError.captureFailed("Could not open the selected microphone.")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw RecordingError.captureFailed("Could not capture from the selected microphone.")
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        self.session = session
    }

    func stop() {
        session?.stopRunning()
        session = nil
        onSample = nil
        isMuted = false
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isMuted else { return }
        onSample?(sampleBuffer)
    }
}
