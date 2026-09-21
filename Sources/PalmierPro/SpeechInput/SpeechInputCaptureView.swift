import SwiftUI

struct SpeechInputCaptureView: View {
    @Bindable var recorder: SpeechInputRecorderController
    var isDisabled = false
    var title = "Voice input"
    var detail = "Record speech with the microphone."

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            captureRow
            if let message = recorder.errorMessage {
                Label(L10n.display(message), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                if recorder.needsMicrophoneSettings {
                    Button("Open System Settings") { recorder.openMicrophoneSettings() }
                        .buttonStyle(.link)
                }
            }
        }
        .onDisappear {
            if recorder.isRecording || recorder.isTransitioning { recorder.cancel() }
        }
    }

    private var captureRow: some View {
        HStack(spacing: AppTheme.Spacing.mdLg) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .frame(width: AppTheme.IconSize.xl, height: AppTheme.IconSize.xl)
                    .padding(AppTheme.Spacing.sm)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .background(
                        recorder.isRecording ? AppTheme.Status.errorColor : AppTheme.Background.raisedColor,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || recorder.isTransitioning)
            .accessibilityLabel(L10n.string(recorder.isRecording ? "Stop recording" : "Start recording"))
            .help(L10n.string(recorder.isRecording ? "Stop recording" : "Start recording"))

            if recorder.isRecording {
                RecordingLiveWaveformView(store: recorder.waveform, isPaused: recorder.isTransitioning)
                Text(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string(recorder.isTransitioning ? "Preparing microphone…" : title))
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    Text(L10n.string(key: detail))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }
}
