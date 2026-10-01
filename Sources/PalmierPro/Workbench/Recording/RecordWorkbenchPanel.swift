import SwiftUI

struct RecordWorkbenchPanel: View {
    @Bindable var session: RecordingSessionController
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            header

            if session.phase.isCapturing {
                recordingStatus
            }

            modePicker
            if session.configuration.mode == .mobileDevice { mobileSource }
            if session.configuration.capturesVideo && session.configuration.mode != .mobileDevice {
                RecordingVideoSettingsView(settings: $session.configuration.video)
                    .disabled(session.phase.isActive || session.isRequestingStart)
            }
            audioSources
            actionRow
            messages
        }
        .onAppear {
            session.refreshDevices()
            session.refreshPermissionState()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label(L10n.string("RECORD"), systemImage: "waveform")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Accent.link)

                Text(session.phase.isCapturing ? (session.isPaused ? L10n.string("Paused") : L10n.string("Recording")) : L10n.string("Capture audio or screen"))
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            }

            Spacer(minLength: AppTheme.Spacing.md)

            RecordingInfoButton(
                title: L10n.string("About recording"),
                message: L10n.string("Record audio, a display, selected apps, a window, a region, or a USB iPhone/iPad. Review and trim video before transcription.")
            )
        }
    }

    private var modePicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.zoomed(150)), spacing: AppTheme.Spacing.smMd)], spacing: AppTheme.Spacing.smMd) {
            ForEach(RecordingCaptureMode.allCases) { mode in
                Button {
                    session.setCaptureMode(mode)
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Label(mode.title, systemImage: mode.systemImage)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        Spacer(minLength: AppTheme.zoomed(28))
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.mdLg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        session.configuration.mode == mode
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                            : AppTheme.Background.baseColor.opacity(AppTheme.Opacity.soft),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(
                                session.configuration.mode == mode
                                    ? AppTheme.Accent.primary
                                    : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    RecordingInfoButton(title: mode.title, message: mode.detail)
                        .padding(.trailing, AppTheme.Spacing.md)
                }
                .disabled(session.phase.isActive || session.isRequestingStart)
            }
        }
    }

    private var audioSources: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            sourceCard(
                title: L10n.string("Microphone"),
                systemImage: "mic",
                info: L10n.string("Choose a microphone or turn microphone capture off.")
            ) {
                Picker(L10n.string("Microphone"), selection: $session.configuration.microphone) {
                    Text(L10n.string("Off")).tag(RecordingMicrophoneSource.off)
                    ForEach(session.devices) { device in
                        Text(device.name).tag(RecordingMicrophoneSource.device(id: device.id))
                    }
                }
                .labelsHidden()
                .frame(width: AppTheme.Workbench.recordingDevicePickerWidth, alignment: .leading)
                .disabled(session.phase.isActive || session.isRequestingStart)
            }

            sourceCard(
                title: L10n.string(session.configuration.mode == .mobileDevice ? "Device audio" : session.configuration.mode == .application ? "App audio" : "System audio"),
                systemImage: "speaker.wave.2",
                info: session.configuration.mode == .mobileDevice
                    ? L10n.string("Captures sound from your connected iPhone or iPad. Turn this off when device audio is unavailable, such as during a call.")
                    : session.configuration.mode == .application
                    ? L10n.string("Captures sound from the selected apps, including when using headphones. Other apps are excluded.")
                    : L10n.string("Captures audio playing through this Mac. Requires Screen Recording permission. Keep this enabled when recording a display, window, or region without a microphone.")
            ) {
                Toggle(L10n.string("Capture"), isOn: Binding(
                    get: { session.configuration.capturesPrimaryAudio },
                    set: { value in
                        if session.configuration.mode == .mobileDevice { session.configuration.capturesDeviceAudio = value }
                        else { session.configuration.capturesSystemAudio = value }
                    }))
                    .toggleStyle(.checkbox)
                    .disabled(session.phase.isActive || session.isRequestingStart)
            }
        }
    }

    private var mobileSource: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Picker(L10n.string("Mobile Device"), selection: $session.configuration.mobileDeviceID) {
                    Text(L10n.string("Choose a device")).tag(String?.none)
                    ForEach(session.mobileDevices) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(L10n.string("Quality preset"), selection: $session.configuration.mobilePreset) {
                    ForEach(session.supportedMobilePresets) { Text(L10n.string(key: $0.title)).tag($0) }
                }
                Button(L10n.string("Refresh")) { session.refreshMobileDevices() }
                Button(L10n.string("Preview device")) { session.previewMobileDevice() }
                    .disabled(session.configuration.mobileDeviceID == nil)
            }
            .disabled(session.phase.isActive || session.isRequestingStart)
            if session.mobileDevices.isEmpty {
                Label(L10n.string("Connect your iPhone or iPad via USB, unlock it, and trust this Mac."), systemImage: "iphone.slash")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if session.phase.isCapturing {
                Button(L10n.string("Show device preview")) { session.showMobilePreview() }
            }
        }
    }

    private func sourceCard<Content: View>(
        title: String,
        systemImage: String,
        info: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                RecordingInfoButton(title: title, message: info)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lgXl)
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.soft), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            RecordingLiveIndicator(isPaused: session.isPaused)

            Text(RecordingTimeFormat.clock(session.elapsed))
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(session.isPaused ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor)

            RecordingLiveWaveformView(store: session.liveWaveform, isPaused: session.isPaused)
                .frame(maxWidth: .infinity)

            if session.configuration.microphone.isEnabled {
                Button {
                    session.toggleMicrophoneMuted()
                } label: {
                    Image(systemName: session.isMicrophoneMuted ? "mic.slash" : "mic")
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                }
                .buttonStyle(.borderless)
                .help(session.isMicrophoneMuted ? L10n.string("Unmute microphone") : L10n.string("Mute microphone"))
                .accessibilityLabel(session.isMicrophoneMuted ? L10n.string("Unmute microphone") : L10n.string("Mute microphone"))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(
            session.isPaused
                ? AppTheme.Status.warningColor.opacity(AppTheme.Opacity.subtle)
                : AppTheme.Status.errorColor.opacity(AppTheme.Opacity.subtle),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(
                    (session.isPaused ? AppTheme.Status.warningColor : AppTheme.Status.errorColor)
                        .opacity(AppTheme.Opacity.medium),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.isPaused ? L10n.string("Paused") : L10n.string("Recording"))
    }

    private var actionRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if session.phase.isCapturing {
                Button {
                    session.togglePause()
                } label: {
                    Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                }
                .buttonStyle(.bordered)
                .help(session.isPaused ? L10n.string("Resume recording") : L10n.string("Pause recording"))
                .accessibilityLabel(session.isPaused ? L10n.string("Resume recording") : L10n.string("Pause recording"))

                Button {
                    session.stop()
                } label: {
                    Label(L10n.string("Stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    session.discard()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                }
                .buttonStyle(.bordered)
                .help(L10n.string("Discard recording"))
                .accessibilityLabel(L10n.string("Discard recording"))
            } else if session.phase == .reviewing || session.phase == .trimming {
                Button(L10n.string("Show recording")) { session.showRecordingSetup() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    session.requestStart()
                } label: {
                    Label(startLabel, systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canStart || session.phase.isActive)
            }

            Spacer(minLength: AppTheme.Spacing.md)

            if !session.phase.isCapturing {
                RecordingInfoButton(
                    title: "Processing limit",
                    message: RecordingDurationLimit.recordingHint(hasFeatureAccess: account.hasFeatureAccess)
                )
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let message = session.errorMessage ?? session.permissionMessage {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.display(message))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(session.errorMessage == nil ? AppTheme.Text.secondaryColor : AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                if session.permissionSettingsURL != nil {
                    Button(L10n.string("Open System Settings")) {
                        session.openPermissionSettings()
                    }
                    .buttonStyle(.link)
                }
            }
        }

        if let warning = session.liveAudioWarning ?? session.lastDiagnostics?.warningMessage {
            Label(L10n.display(warning), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let url = session.savedRecordingURL {
            Button(L10n.string("Show recording in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        }
        if !session.configuration.hasCaptureSource && !session.phase.isActive {
            Label(L10n.string("Select an audio source"), systemImage: "waveform.badge.exclamationmark")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
        }
    }

    private var startLabel: String {
        switch session.phase {
        case .preparing: L10n.string("Preparing…")
        case .picking: L10n.string("Choose source…")
        case .finishing: L10n.string("Finishing…")
        case .reviewing: L10n.string("Review recording")
        case .trimming: L10n.string("Trimming recording…")
        default: L10n.string("Start recording")
        }
    }
}

private struct RecordingInfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: AppTheme.FontSize.mdLg))
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.Text.mutedColor)
        .contentShape(Circle())
        .help(L10n.string(key: title))
        .accessibilityLabel(L10n.string(key: title))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Text(L10n.string(key: message))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppTheme.Spacing.lgXl)
            .frame(width: AppTheme.Workbench.recordingInfoPopoverWidth, alignment: .leading)
        }
    }
}

private struct RecordingLiveIndicator: View {
    let isPaused: Bool
    @State private var isExpanded = false

    var body: some View {
        Circle()
            .fill(isPaused ? AppTheme.Status.warningColor : AppTheme.Status.errorColor)
            .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            .scaleEffect(isPaused ? 1 : (isExpanded ? 1.2 : 0.85))
            .animation(
                .easeInOut(duration: AppTheme.Anim.pulse).repeatForever(autoreverses: true),
                value: isExpanded
            )
            .onAppear {
                isExpanded = !isPaused
            }
            .onChange(of: isPaused) { _, paused in
                isExpanded = !paused
            }
    }
}
