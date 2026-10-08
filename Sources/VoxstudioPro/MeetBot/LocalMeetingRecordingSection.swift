import AppKit
import SwiftUI

struct LocalMeetingRecordingSection: View {
    @State private var presence = MeetingAppPresence()
    @Bindable private var recording = RecordingSessionController.shared

    private static let captureModes: [RecordingCaptureMode] = [.application, .window, .display, .region, .audioOnly]
    private var isBusy: Bool { recording.isRequestingStart || (recording.phase.isActive && !recording.phase.isCapturing) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("ON THIS MAC"), systemImage: "macwindow")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Accent.primary)

            Text(L10n.string("Record the meeting locally"))
                .font(.system(size: AppTheme.FontSize.title2, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Choose an open meeting app to record its windows and audio. Save the file on this Mac, then transcribe it in VoxStudio."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.lg) {
                Label(L10n.string("App audio on"), systemImage: "speaker.wave.2")
                Label(L10n.string(recording.configuration.microphone.isEnabled ? "Microphone on" : "Microphone off"),
                      systemImage: recording.configuration.microphone.isEnabled ? "mic" : "mic.slash")
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)

            if presence.running.isEmpty {
                Text(L10n.string("No supported meeting app is open. Open one, or choose an app or window below. For a browser meeting, choose its window."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(presence.running) { app in detectedAppRow(app) }
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Other ways to record"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.zoomed(125)), spacing: AppTheme.Spacing.sm)], spacing: AppTheme.Spacing.sm) {
                    ForEach(Self.captureModes) { mode in
                        Button { beginCapture(mode: mode) } label: {
                            Label(mode.title, systemImage: mode.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.capsule(.secondary, size: .small))
                        .help(mode.detail)
                        .accessibilityHint(mode.detail)
                        .disabled(isBusy)
                    }
                }
                Text(L10n.string("Open apps are detected locally. This does not indicate that a call is in progress."))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate), lineWidth: AppTheme.BorderWidth.thin)
        }
        .onAppear { presence.start() }
        .onDisappear { presence.stop() }
    }

    private func detectedAppRow(_ app: DetectedMeetingApp) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if let icon = NSRunningApplication(processIdentifier: app.processID)?.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: AppTheme.zoomed(36), height: AppTheme.zoomed(36))
            } else {
                Image(systemName: app.definition.systemImage)
                    .frame(width: AppTheme.zoomed(36), height: AppTheme.zoomed(36))
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(app.name).font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Label(L10n.string(isRecording(app) ? "Recording" : "Meeting app is open"), systemImage: "circle.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(isRecording(app) ? AppTheme.Status.errorColor : AppTheme.Status.successColor)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Button { beginCapture(mode: .application, app: app) } label: {
                Label(L10n.string(recording.phase.isCapturing ? "Show recording" : "Record this app"), systemImage: "record.circle")
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .accessibilityLabel(recording.phase.isCapturing ? L10n.string("Show recording") : L10n.format("Record %@", app.name))
            .disabled(isBusy)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func isRecording(_ app: DetectedMeetingApp) -> Bool {
        recording.phase.isCapturing && recording.activeApplicationSelection?.applications.contains {
            $0.processID == app.processID && $0.bundleIdentifier == app.bundleIdentifier
        } == true
    }

    private func beginCapture(mode: RecordingCaptureMode, app: DetectedMeetingApp? = nil) {
        if recording.phase.isCapturing {
            recording.showRecordingSetup()
            return
        }
        guard recording.phase == .idle, !recording.isRequestingStart else { return }
        WorkbenchStore.shared.showLocalRecording(LocalRecordingRequest(
            mode: mode, applicationBundleIdentifier: app?.bundleIdentifier,
            startImmediately: true, applicationProcessID: app?.processID, purpose: .meeting, sessionProjectID: WorkbenchStore.shared.sessionCreationProjectID
        ))
    }
}
