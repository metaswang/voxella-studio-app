import SwiftUI

@MainActor
struct MeetBotView: View {
    @State private var store = MeetBotStore()
    @State private var showAccessPrompt = false

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                header

                if store.access == .allowed {
                    manualJoinCard
                    calendarCard
                    meetingsCard
                } else if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, AppTheme.Spacing.xxl)
                } else {
                    accessCard
                }
            }
            .frame(maxWidth: AppTheme.Workbench.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.vertical, AppTheme.Spacing.xxl)
        }
        .background(AppTheme.Background.baseColor)
        .task {
            await store.load()
            showAccessPrompt = store.access != .allowed
        }
        .onChange(of: store.access) { _, access in
            if access == .allowed {
                showAccessPrompt = false
            } else if !store.isLoading {
                showAccessPrompt = true
            }
        }
        .sheet(isPresented: $showAccessPrompt) {
            FeatureAccessPrompt(
                feature: .meetBot,
                access: store.access,
                onRetry: { retryAccess() }
            )
            .frame(minWidth: AppTheme.Settings.contentMaxWidth)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(L10n.string("Meet Bot"), systemImage: "calendar.badge.clock")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.primary)
            Text(L10n.string("Never miss the conversation"))
                .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Send a visible VoxStudio notetaker to a meeting, then receive a searchable transcript and summary."))
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualJoinCard: some View {
        MeetBotCard {
            sectionHeader(
                title: L10n.string("Send a bot to a meeting"),
                subtitle: L10n.string("Paste a Google Meet, Microsoft Teams, or Zoom link. The bot joins as a visible participant.")
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                providerPill("Google Meet")
                providerPill("Teams")
                providerPill("Zoom")
            }

            TextField(L10n.string("Meeting link"), text: $store.meetingURL)
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("Meeting title (optional)"), text: $store.meetingTitle)
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("Bot display name"), text: $store.botName)
                .textFieldStyle(.roundedBorder)

            Toggle(L10n.string("Record meeting screen"), isOn: $store.recordScreen)
                .toggleStyle(.switch)

            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    Task { await store.manualJoin() }
                } label: {
                    Label(
                        store.isJoining ? L10n.string("Sending…") : L10n.string("Send Meet Bot"),
                        systemImage: "paperplane.fill"
                    )
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(store.isJoining || store.meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let result = store.joinResult {
                    Label(
                        L10n.string("Bot queued") + " · " + result.provider.rawValue.capitalized,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.successColor)
                }
            }

            if let error = store.errorMessage {
                errorText(error)
            }
        }
    }

    private var calendarCard: some View {
        MeetBotCard {
            sectionHeader(
                title: L10n.string("Google Calendar"),
                subtitle: L10n.string("Connect Google Calendar in read-only mode to discover upcoming meetings you choose or enable.")
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(store.calendarStatus?.connected == true ? AppTheme.Status.successColor : AppTheme.Status.warningColor)
                    .frame(width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm)
                Text(store.calendarStatus?.connected == true
                    ? L10n.string("Connected")
                    : L10n.string("Not connected"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if let email = store.calendarStatus?.googleEmail {
                    Text(email)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
                Button(L10n.string("Open Calendar Settings")) {
                    SettingsWindowController.shared.show(tab: .calendar)
                }
                .buttonStyle(.capsule(.secondary, size: .small))
            }

            Text(L10n.string("Calendar access is limited to read-only event metadata. It does not grant access to meeting audio, video, chat, screen sharing, or Drive recordings."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            if let lastError = store.calendarStatus?.lastError, !lastError.isEmpty {
                errorText(lastError)
            }
        }
    }

    private var meetingsCard: some View {
        MeetBotCard {
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.lg) {
                sectionHeader(
                    title: L10n.string("Upcoming meetings"),
                    subtitle: L10n.string("Choose a meeting to enable, disable, or retry the bot workflow.")
                )
                Spacer(minLength: 0)
                TextField(L10n.string("Search meetings"), text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: AppTheme.ComponentSize.projectSearchWidth)
            }

            if store.filteredMeetings.isEmpty {
                Text(store.calendarStatus?.connected == true
                    ? L10n.string("No meetings found yet.")
                    : L10n.string("Connect Google Calendar to discover upcoming meetings."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AppTheme.Spacing.xl)
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(store.filteredMeetings) { meeting in
                        meetingRow(meeting)
                    }
                }
            }

            if let error = store.errorMessage {
                errorText(error)
            }
        }
    }

    private var accessCard: some View {
        MeetBotCard {
            FeatureAccessPrompt(
                feature: .meetBot,
                access: store.access,
                onRetry: { retryAccess() }
            )
        }
    }

    private func meetingRow(_ meeting: VoxellaGoogleCalendarMeeting) -> some View {
        let enabled = meeting.selectionOverride != "disabled" && meeting.status != "not_selected"
        return HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(meeting.title?.isEmpty == false ? meeting.title! : L10n.string("Google Meet"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let start = MeetBotPresentation.date(meeting.startsAt) {
                    Text(start)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                if let url = meeting.meetingURL, !url.isEmpty {
                    Text(url)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Text(MeetBotPresentation.status(meeting.status))
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(meeting.status == "failed" ? AppTheme.Status.errorColor : AppTheme.Text.tertiaryColor)
                if let lastError = meeting.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button(enabled ? L10n.string("Disable") : L10n.string("Enable")) {
                    Task { await store.setMeeting(meeting, enabled: !enabled) }
                }
                .buttonStyle(.capsule(.secondary, size: .small))
                .disabled(store.updatingMeetingID != nil)

                Button(L10n.string("Retry bot")) {
                    Task { await store.retryMeeting(meeting) }
                }
                .buttonStyle(.capsule(.prominent, size: .small))
                .disabled(store.updatingMeetingID != nil)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(subtitle)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(AppTheme.Background.raisedColor)
            .clipShape(Capsule(style: .continuous))
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Status.errorColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func retryAccess() {
        Task { @MainActor in
            await store.load()
        }
    }
}

private struct MeetBotCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.xlXxl)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
    }
}

@MainActor
private enum MeetBotPresentation {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ value: String?) -> String? {
        guard let value,
              let date = formatter.date(from: value) ?? fallbackFormatter.date(from: value)
        else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func status(_ value: String) -> String {
        switch value {
        case "not_selected": L10n.string("Not enabled")
        case "scheduled": L10n.string("Scheduled")
        case "waiting_for_meeting": L10n.string("Waiting to join")
        case "waiting_for_recording", "downloading", "processing": L10n.string("Processing")
        case "joining": L10n.string("Bot starting")
        case "joined": L10n.string("Joined")
        case "completed": L10n.string("Completed")
        case "no_recording": L10n.string("No recording needed")
        case "failed": L10n.string("Failed")
        case "cancelled": L10n.string("Cancelled")
        default: value
        }
    }
}
