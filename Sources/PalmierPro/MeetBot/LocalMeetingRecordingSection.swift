import SwiftUI

struct LocalMeetingRecordingSection: View {
    @State private var presence = MeetingAppPresence()
    @Bindable private var recording = RecordingSessionController.shared

    private static let captureModes: [RecordingCaptureMode] = [.display, .window, .region, .audioOnly]

    private var guideSteps: [(number: String, title: String)] {
        [
            ("1", L10n.string("Open the meeting")),
            ("2", L10n.string("Choose what to capture")),
            ("3", L10n.string("Transcribe the recording")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("ON THIS MAC"), systemImage: "macwindow")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(AppTheme.Background.prominentColor, in: Capsule(style: .continuous))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Record the meeting locally"))
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string("Capture the meeting already open on this Mac. The file stays here and can be transcribed in VoxStudio. This records your screen or audio, separate from the remote notetaker."))
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            guide

            if presence.running.isEmpty {
                Text(L10n.string("No Zoom, Teams, or Webex app is open. Record the screen, a window, a region, or audio. Google Meet in a browser can be captured by choosing its window."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                modeGrid
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(presence.running) { app in
                        detectedAppRow(app)
                    }
                }
                otherWays
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(
                    AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
        .onAppear { presence.start() }
        .onDisappear { presence.stop() }
    }

    private var guide: some View {
        ViewThatFits(in: .horizontal) {
            guideRow(showsConnectors: true)
            guideRow(showsConnectors: false)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(Array(guideSteps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(step.number)
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Background.baseColor)
                            .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                            .background(AppTheme.Accent.primary, in: Circle())
                        Text(step.title)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                }
            }
        }
    }

    private func guideRow(showsConnectors: Bool) -> some View {
        HStack(alignment: .center, spacing: showsConnectors ? AppTheme.Spacing.sm : AppTheme.Spacing.md) {
            ForEach(Array(guideSteps.enumerated()), id: \.offset) { index, step in
                if showsConnectors, index > 0 {
                    Rectangle()
                        .fill(AppTheme.Border.subtleColor)
                        .frame(height: AppTheme.BorderWidth.thin)
                        .frame(maxWidth: AppTheme.zoomed(36))
                }
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(step.number)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Background.baseColor)
                        .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                        .background(AppTheme.Accent.primary, in: Circle())
                    Text(step.title)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                }
            }
            if showsConnectors {
                Spacer(minLength: 0)
            }
        }
    }

    private func detectedAppRow(_ app: DetectedMeetingApp) -> some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: app.definition.systemImage)
                .font(.system(size: AppTheme.IconSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(width: AppTheme.zoomed(44), height: AppTheme.zoomed(44))
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(app.definition.name)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Circle()
                        .fill(AppTheme.Status.successColor)
                        .frame(width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm)
                    Text(L10n.string("Meeting app is open"))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }

            Spacer(minLength: AppTheme.Spacing.md)

            Button {
                beginCapture(mode: .window, bundleIdentifier: app.bundleIdentifier)
            } label: {
                Label(recordButtonTitle, systemImage: "record.circle")
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .accessibilityLabel(L10n.format("Record %@", app.definition.name))
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var otherWays: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Other ways to record"))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ViewThatFits(in: .horizontal) {
                modeChipRow
                modeGrid
            }
        }
    }

    private var modeChipRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(Self.captureModes) { mode in
                modeChip(mode)
            }
            Spacer(minLength: 0)
        }
    }

    private func modeChip(_ mode: RecordingCaptureMode) -> some View {
        Button {
            beginCapture(mode: mode, bundleIdentifier: nil)
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .help(mode.detail)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.detail)
    }

    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: AppTheme.zoomed(168)), spacing: AppTheme.Spacing.md)],
            spacing: AppTheme.Spacing.md
        ) {
            ForEach(Self.captureModes) { mode in
                modeCard(mode)
            }
        }
    }

    private func modeCard(_ mode: RecordingCaptureMode) -> some View {
        Button {
            beginCapture(mode: mode, bundleIdentifier: nil)
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: AppTheme.IconSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .frame(width: AppTheme.zoomed(36), height: AppTheme.zoomed(36))
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
                Text(mode.title)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(mode.detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: AppTheme.zoomed(132), alignment: .topLeading)
            .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.detail)
    }

    private var recordButtonTitle: String {
        recording.phase.isCapturing
            ? L10n.string("Show recording")
            : L10n.string("Record this window")
    }

    private func beginCapture(mode: RecordingCaptureMode, bundleIdentifier: String?) {
        if recording.phase.isCapturing {
            recording.showRecordingSetup()
            return
        }
        guard recording.phase == .idle else {
            WorkbenchStore.shared.showRecordImport()
            return
        }
        WorkbenchStore.shared.showLocalRecording(
            LocalRecordingRequest(
                mode: mode,
                applicationBundleIdentifier: bundleIdentifier,
                startImmediately: true
            )
        )
    }
}
