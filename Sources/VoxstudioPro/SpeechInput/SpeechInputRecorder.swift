import AVFoundation
import AppKit
import Foundation
import Observation

private actor SpeechInputRecorder {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func start() throws {
        cancel()
        switch RecordingPermission.microphoneStatus() {
        case .authorized:
            break
        case .restricted:
            throw VoiceLibraryError.microphoneRestricted
        case .denied, .notDetermined:
            throw VoiceLibraryError.microphoneDenied
        }
        let URL = FileIO.temporaryFileURL(pathExtension: "wav")
        outputURL = URL
        let recorder = try AVAudioRecorder(url: URL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else { throw VoiceLibraryError.recordingFailed }
        self.recorder = recorder
        outputURL = URL
    }

    func peak() -> Float {
        recorder?.updateMeters()
        guard let recorder else { return 0 }
        return pow(10, recorder.peakPower(forChannel: 0) / 20)
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    func discardRecordedAudio() {
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}

@Observable
@MainActor
final class SpeechInputRecorderController {
    let waveform = RecordingLiveWaveformStore()
    private(set) var isRecording = false
    private(set) var isTransitioning = false
    private(set) var duration = 0.0
    private(set) var recordedURL: URL?
    private(set) var errorMessage: String?
    private(set) var needsMicrophoneSettings = false

    private let recorder = SpeechInputRecorder()
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?

    func start() {
        guard !isRecording, !isTransitioning else { return }
        let previous = operationTask
        let current = UUID()
        generation = current
        isTransitioning = true
        recordedURL = nil
        errorMessage = nil
        needsMicrophoneSettings = false
        operationTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == current, !Task.isCancelled else { return }
            defer { if generation == current { isTransitioning = false } }
            do {
                try await requestMicrophonePermission()
                try Task.checkCancellation()
                try await recorder.start()
                guard generation == current, !Task.isCancelled else {
                    await recorder.cancel()
                    return
                }
                startedAt = Date()
                duration = 0
                isRecording = true
                waveform.reset()
                startTimer()
            } catch {
                await recorder.cancel()
                guard generation == current, !Task.isCancelled else { return }
                needsMicrophoneSettings = (error as? VoiceLibraryError)?.requiresMicrophonePermissionSettings ?? false
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        Task { _ = await stopAndWait() }
    }

    func stopAndWait() async -> URL? {
        guard isRecording, !isTransitioning else { return nil }
        timerTask?.cancel()
        timerTask = nil
        isTransitioning = true
        let previous = operationTask
        let current = generation
        await previous?.value
        guard generation == current, !Task.isCancelled else { return nil }
        let result = await recorder.stop()
        guard generation == current, !Task.isCancelled else { return nil }
        isRecording = false
        isTransitioning = false
        recordedURL = result
        if result == nil { errorMessage = VoiceLibraryError.recordingFailed.localizedDescription }
        return result
    }

    func cancel() {
        generation = UUID()
        let previous = operationTask
        previous?.cancel()
        timerTask?.cancel()
        timerTask = nil
        let recorder = recorder
        operationTask = Task {
            await previous?.value
            await recorder.cancel()
        }
        isRecording = false
        isTransitioning = false
        duration = 0
        recordedURL = nil
    }

    func openMicrophoneSettings() {
        guard let URL = RecordingPermission.microphoneSettingsURL else { return }
        guard NSWorkspace.shared.open(URL) else {
            Log.recording.warning("could not open microphone permission settings")
            return
        }
    }

    func discardRecordedAudio(after recognition: Task<Void, Never>? = nil) {
        recordedURL = nil
        let previous = operationTask
        let recorder = recorder
        operationTask = Task {
            await previous?.value
            await recognition?.value
            await recorder.discardRecordedAudio()
        }
    }

    private func requestMicrophonePermission() async throws {
        do {
            try await RecordingPermission.requestMicrophone()
        } catch let error as RecordingError {
            switch error {
            case .microphoneDenied:
                throw VoiceLibraryError.microphoneDenied
            case .microphoneRestricted:
                throw VoiceLibraryError.microphoneRestricted
            default:
                throw error
            }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, let startedAt else { return }
                guard !Task.isCancelled else { return }
                let peak = await recorder.peak()
                guard !Task.isCancelled, isRecording else { return }
                waveform.ingest(peak: peak, at: ProcessInfo.processInfo.systemUptime)
                duration = Date().timeIntervalSince(startedAt)
            }
        }
    }
}
