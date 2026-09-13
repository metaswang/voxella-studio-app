import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class VoiceInputCoordinator {
    static let shared = VoiceInputCoordinator()

    let recorder: SpeechInputRecorderController
    let recognition: SpeechInputController
    var draft = ""
    private(set) var errorMessage: String?
    private(set) var focusGeneration = 0
    private(set) var editorMaximumHeight = AppTheme.SpeechInput.scriptMaxHeight

    private var automaticallyInserts = false
    private var onInsert: ((String) -> Bool)?
    var insertsIntoField: Bool { onInsert != nil }

    private var panelController: VoiceInputPanelController?
    private var sessionID = UUID()
    private var recordedURL: URL?
    private var suspendedRecordingURL: URL?
    private var isSleeping = false
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        recorder: SpeechInputRecorderController = SpeechInputRecorderController(),
        recognition: SpeechInputController = SpeechInputController(purpose: .quickInput),
        onInsert: ((String) -> Bool)? = nil
    ) {
        self.recorder = recorder
        self.recognition = recognition
        self.onInsert = onInsert
        installLifecycleObservers()
    }

    var isBusy: Bool { recorder.isTransitioning || recognition.isRecognizing }
    var canSubmit: Bool { !isBusy && !recorder.isRecording && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func present() {
        if lifecycleObservers.isEmpty { installLifecycleObservers() }
        onInsert = nil
        automaticallyInserts = false
        errorMessage = nil
        panel().present()
        focusGeneration &+= 1
    }

    func beginInline(onInsert: @escaping (String) -> Bool) {
        guard !isBusy, !recorder.isRecording else { return }
        if lifecycleObservers.isEmpty { installLifecycleObservers() }
        self.onInsert = onInsert
        automaticallyInserts = true
        draft = ""
        errorMessage = nil
        toggleRecording()
    }

    func dismiss() {
        sessionID = UUID()
        errorMessage = nil
        if recorder.isRecording || recorder.isTransitioning {
            recorder.cancel()
        }
        let pendingRecognition = recognition.cancel()
        recorder.discardRecordedAudio(after: pendingRecognition)
        onInsert = nil
        automaticallyInserts = false
        suspendedRecordingURL = nil
        recordedURL = nil
        panelController?.dismiss()
    }

    func shutdown() {
        dismiss()
        for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
        lifecycleObservers = []
    }

    func toggleRecording() {
        guard !recognition.isRecognizing else { return }
        errorMessage = nil
        if recorder.isRecording {
            stopAndRecognize()
        } else if !recorder.isTransitioning {
            recognition.cancel()
            recordedURL = nil
            suspendedRecordingURL = nil
            recorder.start()
        }
    }

    func retryRecognition() {
        guard let recordedURL, !isBusy, !recorder.isRecording else { return }
        errorMessage = nil
        startRecognition(from: recordedURL, session: sessionID)
    }

    @discardableResult
    func submit(pasteboard: NSPasteboard = .general) -> Bool {
        guard canSubmit else { return false }
        if let onInsert {
            guard onInsert(draft) else {
                errorMessage = "The input changed. Copy the recognized text before recording again."
                return false
            }
            draft = ""
            dismiss()
            return true
        }
        pasteboard.clearContents()
        guard pasteboard.setString(draft, forType: .string) else {
            errorMessage = "Couldn’t copy voice input to the clipboard."
            return false
        }
        draft = ""
        dismiss()
        return true
    }

    func updateEditorMaximumHeight(_ height: CGFloat) {
        editorMaximumHeight = max(AppTheme.SpeechInput.quickInputEditorMinimumHeight, height)
    }

    func resizePanel(to height: CGFloat) {
        panelController?.resize(to: height)
    }

    private func stopAndRecognize() {
        let activeSession = sessionID
        Task { [weak self] in
            guard let self, let url = await recorder.stopAndWait() else { return }
            guard sessionID == activeSession, !Task.isCancelled else { return }
            recordedURL = url
            startRecognition(from: url, session: activeSession)
        }
    }

    private func startRecognition(from url: URL, session: UUID) {
        recognition.start(sourceURL: url) { [weak self] result in
            guard let self, self.sessionID == session else { return }
            let separator = self.draft.isEmpty || self.draft.hasSuffix("\n") ? "" : "\n"
            self.draft += separator + result.text
            self.focusGeneration &+= 1
            if self.automaticallyInserts { self.submit() }
        }
    }

    private func panel() -> VoiceInputPanelController {
        if let panelController { return panelController }
        let controller = VoiceInputPanelController(coordinator: self)
        panelController = controller
        return controller
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append((center, center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pauseForSleep() }
        }))
        lifecycleObservers.append((center, center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        }))
    }

    private func pauseForSleep() {
        guard recorder.isRecording else { return }
        isSleeping = true
        let activeSession = sessionID
        Task { [weak self] in
            guard let self, let url = await recorder.stopAndWait(), sessionID == activeSession else { return }
            suspendedRecordingURL = url
            recordedURL = url
            if !isSleeping { resumeAfterWake() }
        }
    }

    private func resumeAfterWake() {
        isSleeping = false
        guard let url = suspendedRecordingURL else { return }
        suspendedRecordingURL = nil
        startRecognition(from: url, session: sessionID)
    }
}

