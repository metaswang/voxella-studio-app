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
    @State private var showsSettings = false

    private var hasSelection: Bool {
        !state.rect.isNull && state.rect.width >= AppTheme.Workbench.recordingRegionMinSize
            && state.rect.height >= AppTheme.Workbench.recordingRegionMinSize
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "viewfinder")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.link)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(L10n.string("Selected area"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    Text(hasSelection
                        ? "\(Int(state.rect.width)) × \(Int(state.rect.height)) \(L10n.string("points"))"
                        : L10n.string("Drag to select an area"))
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Picker(L10n.string("Frame rate"), selection: $state.configuration.video.frameRate) {
                    ForEach(RecordingVideoSettings.frameRates, id: \.self) { rate in
                        Text("\(rate) FPS").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: AppTheme.zoomed(190))
                Button { state.redraw?() } label: {
                    Image(systemName: "selection.pin.in.out")
                }
                .help(L10n.string("Reselect"))
                .accessibilityLabel(L10n.string("Reselect"))
                Button { showsSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help(L10n.string("Recording settings"))
                .accessibilityLabel(L10n.string("Recording settings"))
                .popover(isPresented: $showsSettings, arrowEdge: .top) { advancedSettings }
                Button { state.cancel?() } label: { Image(systemName: "xmark") }
                    .help(L10n.string("Cancel"))
                    .accessibilityLabel(L10n.string("Cancel"))
                    .keyboardShortcut(.cancelAction)
            }
            Divider().opacity(0.5)
            HStack(spacing: AppTheme.Spacing.md) {
                Toggle(L10n.string("System audio"), isOn: $state.configuration.capturesSystemAudio)
                    .toggleStyle(.checkbox)
                Image(systemName: state.configuration.microphone == .off ? "mic.slash" : "mic")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker(L10n.string("Microphone"), selection: $state.configuration.microphone) {
                    Text(L10n.string("Off")).tag(RecordingMicrophoneSource.off)
                    Text(L10n.string("System Default")).tag(RecordingMicrophoneSource.systemDefault)
                    ForEach(state.devices) { Text($0.name).tag(RecordingMicrophoneSource.device(id: $0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: AppTheme.zoomed(185))
                Spacer(minLength: AppTheme.Spacing.sm)
                Button { state.start?() } label: {
                    Label(L10n.string("Start recording"), systemImage: "record.circle.fill")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!hasSelection)
                .keyboardShortcut(.defaultAction)
                .help(L10n.string("Press Return to start recording"))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: AppTheme.FontSize.sm))
        .padding(AppTheme.Spacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor.opacity(0.6), lineWidth: AppTheme.BorderWidth.hairline)
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Recording settings"))
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Selected area"))
                Spacer()
                TextField(L10n.string("Width"), value: dimension(width: true), format: .number.precision(.fractionLength(0)))
                    .frame(width: AppTheme.zoomed(64))
                    .accessibilityLabel(L10n.string("Width"))
                Text("×").foregroundStyle(.secondary)
                TextField(L10n.string("Height"), value: dimension(width: false), format: .number.precision(.fractionLength(0)))
                    .frame(width: AppTheme.zoomed(64))
                    .accessibilityLabel(L10n.string("Height"))
            }
            .disabled(!hasSelection)
            Picker(L10n.string("Resolution"), selection: $state.configuration.video.resolution) {
                ForEach(RecordingResolution.allCases) { Text(L10n.string(key: $0.title)).tag($0) }
            }
            Picker(L10n.string("Quality"), selection: $state.configuration.video.quality) {
                ForEach(RecordingQuality.allCases) { Text(L10n.string(key: $0.title)).tag($0) }
            }
            Toggle(L10n.string("Record cursor"), isOn: $state.configuration.video.showsCursor)
                .toggleStyle(.checkbox)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: AppTheme.FontSize.sm))
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.zoomed(330))
        .appLocalization()
        .appZoomEnvironment()
    }

    private func dimension(width: Bool) -> Binding<Double> {
        Binding(get: { state.rect.isNull ? 0 : (width ? state.rect.width : state.rect.height) }, set: { value in
            guard value.isFinite, !state.rect.isNull else { return }
            state.resize?(CGSize(width: width ? value : state.rect.width, height: width ? state.rect.height : value))
        })
    }
}
