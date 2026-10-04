import SwiftUI

struct InlineVoiceInputControl: View {
    enum Presentation {
        /// The full inline control used by script and search fields.
        case standard
        /// A compact accessory for embedding inside a composer row.
        case embedded
    }

    @Binding var text: String
    var multiline = true
    var presentation: Presentation = .standard
    var onActivityChanged: ((Bool) -> Void)? = nil
    var canInsert: (() -> Bool)? = nil
    var showsEmbeddedRecovery = false
    private var voiceActive: Bool {
        coordinator.map { $0.isBusy || $0.recorder.isRecording } ?? false
    }
    @Environment(\.isEnabled) private var isEnabled
    @State private var coordinator: VoiceInputCoordinator?

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardContent
            case .embedded:
                embeddedContent
            }
        }
        .onChange(of: voiceActive) { _, active in onActivityChanged?(active) }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { coordinator?.dismiss() }
        }
        .onDisappear {
            coordinator?.shutdown()
            coordinator = nil
            onActivityChanged?(false)
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let coordinator, !coordinator.draft.isEmpty || !coordinator.recognition.partialText.isEmpty {
                Text(coordinator.draft.isEmpty ? coordinator.recognition.partialText : coordinator.draft)
                    .textSelection(.enabled)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if let coordinator {
                    if coordinator.recorder.isRecording {
                        RecordingLiveWaveformView(store: coordinator.recorder.waveform, isPaused: coordinator.isBusy)
                            .frame(maxWidth: AppTheme.SpeechInput.quickInputRecordingWaveformWidth)
                        Text(Duration.seconds(coordinator.recorder.duration).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    } else if coordinator.isBusy {
                        ProgressView().controlSize(.small)
                        if case .recognizing(_, let message) = coordinator.recognition.state {
                            Text(L10n.display(message))
                        } else {
                            Text(L10n.string("Preparing microphone…"))
                        }
                    }
                    if coordinator.isBusy || coordinator.recorder.isRecording {
                        Button("Cancel") { coordinator.dismiss() }
                            .buttonStyle(.borderless)
                    }
                }
                Button(action: toggleRecording) {
                    Image(systemName: coordinator?.recorder.isRecording == true ? "stop.fill" : "mic.fill")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(coordinator?.recorder.isRecording == true ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                }
                .buttonStyle(.borderless)
                .disabled(coordinator?.isBusy == true)
                .help(L10n.string(coordinator?.recorder.isRecording == true ? "Stop and transcribe" : "Voice input"))
                .accessibilityLabel(L10n.string(coordinator?.recorder.isRecording == true ? "Stop and transcribe" : "Voice input"))
            }
            .font(.system(size: AppTheme.FontSize.xs))
            if let coordinator {
                if let message = coordinator.recorder.errorMessage ?? coordinator.errorMessage {
                    error(message)
                    if coordinator.recorder.needsMicrophoneSettings {
                        Button("Open System Settings", action: coordinator.recorder.openMicrophoneSettings)
                            .buttonStyle(.link)
                    }
                }
                if case .failed(let message) = coordinator.recognition.state {
                    error(message)
                    Button("Retry", action: coordinator.retryRecognition).buttonStyle(.link)
                }
            }
        }
    }

    private var embeddedContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if let coordinator {
                    if coordinator.recorder.isRecording {
                        RecordingLiveWaveformView(store: coordinator.recorder.waveform, isPaused: coordinator.isBusy)
                            .frame(maxWidth: AppTheme.SpeechInput.inlineRecordingWaveformWidth)
                        Text(Duration.seconds(coordinator.recorder.duration).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    } else if coordinator.isBusy {
                        ProgressView().controlSize(.mini)
                        Text(embeddedStatus).lineLimit(1).help(embeddedStatus)
                    }
                    if coordinator.isBusy || coordinator.recorder.isRecording {
                        Button { coordinator.dismiss() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help(L10n.string("Cancel voice input"))
                            .accessibilityLabel(L10n.string("Cancel voice input"))
                    }
                }
                voiceButton
            }
            if showsEmbeddedRecovery, let coordinator {
                if let message = coordinator.recorder.errorMessage ?? coordinator.errorMessage {
                    error(message)
                    if coordinator.recorder.needsMicrophoneSettings {
                        Button("Open System Settings", action: coordinator.recorder.openMicrophoneSettings).buttonStyle(.link)
                    }
                }
                if case .failed(let message) = coordinator.recognition.state {
                    error(message)
                    Button("Retry", action: coordinator.retryRecognition).buttonStyle(.link)
                }
                if !coordinator.draft.isEmpty && !voiceActive {
                    Text(coordinator.draft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .frame(minHeight: AppTheme.IconSize.lg)
    }

    private var voiceButton: some View {
        Button(action: toggleRecording) {
            Image(systemName: coordinator?.recorder.isRecording == true ? "stop.fill" : "mic.fill")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(
                    coordinator?.recorder.isRecording == true
                        ? AppTheme.Status.errorColor
                        : AppTheme.Text.secondaryColor
                )
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
        }
        .buttonStyle(.borderless)
        .disabled(coordinator?.isBusy == true)
        .help(L10n.string(coordinator?.recorder.isRecording == true ? "Stop and transcribe" : "Voice input"))
        .accessibilityLabel(L10n.string(coordinator?.recorder.isRecording == true ? "Stop and transcribe" : "Voice input"))
    }

    private var embeddedStatus: String {
        if let coordinator,
           case .recognizing(_, let message) = coordinator.recognition.state {
            return L10n.display(message)
        }
        return L10n.string("Preparing voice input")
    }

    private func error(_ message: String) -> some View {
        Text(L10n.display(message))
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Status.errorColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleRecording() {
        let input = coordinator ?? VoiceInputCoordinator()
        coordinator = input
        if input.recorder.isRecording {
            input.toggleRecording()
            return
        }
        onActivityChanged?(true)
        let original = text
        input.beginInline { spoken in
            guard let updated = VoiceInputDraftInsertion.result(original: original, current: text,
                spoken: spoken, multiline: multiline, contextIsCurrent: canInsert?() != false) else { return false }
            text = updated
            return true
        }
    }
}
