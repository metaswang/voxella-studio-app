import SwiftUI

struct RecordingVideoSettingsView: View {
    @Binding var settings: RecordingVideoSettings
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Picker(L10n.string("Resolution"), selection: $settings.resolution) {
                ForEach(RecordingResolution.allCases) { Text(L10n.string(key: $0.title)).tag($0) }
            }
            Picker(L10n.string("Frame rate"), selection: $settings.frameRate) {
                ForEach(RecordingVideoSettings.frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
            }
            Picker(L10n.string("Quality"), selection: $settings.quality) {
                ForEach(RecordingQuality.allCases) { Text(L10n.string(key: $0.title)).tag($0) }
            }
            Toggle(L10n.string("Record cursor"), isOn: $settings.showsCursor).toggleStyle(.checkbox)
        }
        .font(.system(size: AppTheme.FontSize.sm))
    }
}

struct RecordingRegionSetupResult {
    var selection: RecordingRegionSelection
    var configuration: RecordingCaptureConfiguration
}

@Observable @MainActor
final class RecordingRegionSetupState {
    var configuration: RecordingCaptureConfiguration
    var rect: CGRect = .null
    let devices: [RecordingAudioDevice]
    var resize: ((CGSize) -> Void)?
    var redraw: (() -> Void)?
    var start: (() -> Void)?
    var cancel: (() -> Void)?
    init(configuration: RecordingCaptureConfiguration, devices: [RecordingAudioDevice]) {
        self.configuration = configuration
        self.devices = devices
    }
}

struct RecordingRegionSetupView: View {
    @Bindable var state: RecordingRegionSetupState
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                Label(L10n.string("Selected area"), systemImage: "rectangle.dashed")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Spacer()
                TextField(L10n.string("Width"), value: dimension(width: true), format: .number.precision(.fractionLength(0)))
                    .frame(width: 70)
                    .accessibilityLabel(L10n.string("Width"))
                Text("×")
                TextField(L10n.string("Height"), value: dimension(width: false), format: .number.precision(.fractionLength(0)))
                    .frame(width: 70)
                    .accessibilityLabel(L10n.string("Height"))
                Text(L10n.string("points")).foregroundStyle(AppTheme.Text.mutedColor)
                Button(L10n.string("Reselect")) { state.redraw?() }
                Button(L10n.string("Cancel")) { state.cancel?() }.keyboardShortcut(.cancelAction)
            }
            RecordingVideoSettingsView(settings: $state.configuration.video)
            HStack(spacing: AppTheme.Spacing.lg) {
                Toggle(L10n.string("System audio"), isOn: $state.configuration.capturesSystemAudio).toggleStyle(.checkbox)
                Picker(L10n.string("Microphone"), selection: $state.configuration.microphone) {
                    Text(L10n.string("Off")).tag(RecordingMicrophoneSource.off)
                    Text(L10n.string("System Default")).tag(RecordingMicrophoneSource.systemDefault)
                    ForEach(state.devices) { Text($0.name).tag(RecordingMicrophoneSource.device(id: $0.id)) }
                }
                Spacer()
                Button { state.start?() } label: { Label(L10n.string("Start recording"), systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.rect.isNull || state.rect.width < AppTheme.Workbench.recordingRegionMinSize || state.rect.height < AppTheme.Workbench.recordingRegionMinSize)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: AppTheme.FontSize.sm))
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }
    private func dimension(width: Bool) -> Binding<Double> {
        Binding(get: { state.rect.isNull ? 0 : (width ? state.rect.width : state.rect.height) }, set: { value in
            guard value.isFinite, !state.rect.isNull else { return }
            state.resize?(CGSize(width: width ? value : state.rect.width, height: width ? state.rect.height : value))
        })
    }
}
