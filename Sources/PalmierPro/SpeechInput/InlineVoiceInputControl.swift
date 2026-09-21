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
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { coordinator?.dismiss() }
        }
        .onDisappear {
            coordinator?.shutdown()
            coordinator = nil
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
                        Text(L10n.string(coordinator.recognition.isRecognizing ? "Transcribing…" : "Preparing microphone…"))
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
        HStack(spacing: AppTheme.Spacing.xs) {
            if let coordinator {
                if coordinator.recorder.isRecording {
                    RecordingLiveWaveformView(
                        store: coordinator.recorder.waveform,
                        isPaused: coordinator.isBusy
                    )
                    .frame(width: AppTheme.SpeechInput.inlineRecordingWaveformWidth)

                    Text(Duration.seconds(coordinator.recorder.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .monospacedDigit()
                } else if coordinator.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(L10n.string("Preparing voice input"))
                }
            }

            voiceButton
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
        let original = text
        input.beginInline { spoken in
            guard text == original else { return false }
            let insertion = multiline ? spoken : spoken.split(whereSeparator: \.isNewline).joined(separator: " ")
            let separator = original.isEmpty || original.last?.isWhitespace == true ? "" : (multiline ? "\n" : " ")
            text = original + separator + insertion
            return true
        }
    }
}
