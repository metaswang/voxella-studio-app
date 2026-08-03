import AppKit
import SwiftUI

/// Recent Dub sessions block aligned with the Transcribe entry-page session menu.
struct WorkbenchRecentDubSessionsSection: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared

    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all

    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case ready
        case processing
        case completed
        case needsAttention

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All statuses"
            case .ready: "Ready"
            case .processing: "Processing"
            case .completed: "Completed"
            case .needsAttention: "Needs attention"
            }
        }

        func matches(_ state: WorkbenchJobState) -> Bool {
            switch self {
            case .all: true
            case .ready: state == .ready
            case .processing: state == .running || state == .cancelling
            case .completed: state == .completed
            case .needsAttention: state == .failed || state == .cancelled
            }
        }
    }

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.recentDubSessions.filter { session in
            guard statusFilter.matches(session.state) else { return false }
            guard !query.isEmpty else { return true }
            return session.title.localizedCaseInsensitiveContains(query)
                || session.dubTranscript?.text.localizedCaseInsensitiveContains(query) == true
                || session.dubSegments.contains {
                    $0.text.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Recent dub sessions")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                Text("Open a previous dub to edit the script, change its voice, or generate another revision.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            filterToolbar

            if filteredSessions.isEmpty {
                emptyState
            } else {
                sessionsTable
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .frame(height: AppTheme.Workbench.recentSessionControlHeight)
            .frame(maxWidth: .infinity)
            .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            Menu {
                ForEach(StatusFilter.allCases) { filter in
                    Button {
                        statusFilter = filter
                    } label: {
                        if statusFilter == filter {
                            Label(filter.label, systemImage: "checkmark")
                        } else {
                            Text(filter.label)
                        }
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .frame(height: AppTheme.Workbench.recentSessionControlHeight)
                    .background(
                        statusFilter == .all
                            ? AppTheme.Background.raisedColor
                            : AppTheme.Accent.link.opacity(AppTheme.Opacity.soft),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(
                                statusFilter == .all
                                    ? AppTheme.Border.subtleColor
                                    : AppTheme.Accent.link.opacity(AppTheme.Opacity.moderate),
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
                    .foregroundStyle(
                        statusFilter == .all
                            ? AppTheme.Text.secondaryColor
                            : AppTheme.Accent.link
                    )
            }
            .menuStyle(.borderlessButton)
            .help(statusFilter == .all ? "Filter sessions" : "Filter: \(statusFilter.label)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? "No recent dub sessions yet"
                    : "No matching sessions"
            )
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? "Generate a dub above to return to it here."
                    : "Try a different search phrase or clear the status filter."
            )
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Workbench.recentSessionEmptyTextMaxWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xxl)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(
                    AppTheme.Border.subtleColor,
                    style: StrokeStyle(
                        lineWidth: AppTheme.BorderWidth.thin,
                        dash: [AppTheme.Spacing.sm, AppTheme.Spacing.xs]
                    )
                )
        )
    }

    private var sessionsTable: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.zero) {
                Text("SESSION")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("UPDATED")
                    .frame(width: AppTheme.Workbench.recentSessionUpdatedColumnWidth, alignment: .leading)
                Text("TAGS")
                    .frame(width: AppTheme.Workbench.recentSessionTagColumnWidth, alignment: .leading)
                Color.clear.frame(width: AppTheme.Workbench.recentSessionMenuWidth)
            }
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.prominent))

            Divider()

            LazyVStack(spacing: AppTheme.Spacing.zero) {
                ForEach(filteredSessions) { session in
                    recentSessionRow(session)
                    if session.id != filteredSessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    private func recentSessionRow(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.zero) {
            Button {
                store.openSession(session.id)
            } label: {
                HStack(alignment: .center, spacing: AppTheme.Spacing.zero) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                        sourceBadge
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(session.title)
                                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.bold))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .lineLimit(1)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Text(session.source == .media ? "Transcript dub" : "Dub")
                                    .foregroundStyle(AppTheme.Accent.link)
                                metaDot
                                if let duration = session.duration {
                                    Text("Duration \(formatDuration(duration))")
                                    metaDot
                                }
                                Text("Created \(session.createdAt.formatted(date: .numeric, time: .shortened))")
                            }
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        Spacer(minLength: AppTheme.Spacing.zero)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(relativeUpdated(session.modifiedAt))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.Workbench.recentSessionUpdatedColumnWidth, alignment: .leading)

                    Text(session.sessionTag ?? "–")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .frame(width: AppTheme.Workbench.recentSessionTagColumnWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            sessionMenu(session)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
        .contextMenu {
            sessionMenuActions(session)
        }
    }

    private func sessionMenu(_ session: WorkbenchSession) -> some View {
        Menu {
            sessionMenuActions(session)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(
                    width: AppTheme.Workbench.recentSessionMenuWidth,
                    height: AppTheme.Workbench.recentSessionMenuWidth
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Session options")
    }

    @ViewBuilder
    private func sessionMenuActions(_ session: WorkbenchSession) -> some View {
        Button("Open session") { store.openSession(session.id) }
        if let dubID = session.dubID {
            Button("Edit dub") { store.openDub(dubID) }
            Button("Regenerate") { regenerate(dubID) }
                .disabled(!canRegenerate(dubID))
            if let outputURL = session.outputURL {
                Button("Reveal dub in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            }
            Divider()
            Button("Delete dub", role: .destructive) {
                store.deleteDub(dubID)
            }
        }
    }

    private var sourceBadge: some View {
        Image(systemName: "waveform.and.mic")
            .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Accent.link)
            .frame(
                width: AppTheme.Workbench.sessionIconSize,
                height: AppTheme.Workbench.sessionIconSize
            )
            .background(
                AppTheme.Accent.link.opacity(AppTheme.Opacity.soft),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            )
    }

    private var metaDot: some View {
        Text("·")
            .opacity(AppTheme.Opacity.medium)
    }

    private func canRegenerate(_ id: UUID) -> Bool {
        guard let job = store.dubs.first(where: { $0.id == id }) else { return false }
        guard job.state != .running, job.state != .cancelling else { return false }
        return (job.segments ?? []).contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func regenerate(_ id: UUID) {
        guard let job = store.dubs.first(where: { $0.id == id }) else { return }
        guard models.hasRequiredDubModels(modelID: job.model.modelID) else {
            models.presentManager()
            return
        }
        store.openDub(id)
        store.runDub(id)
    }

    private func relativeUpdated(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
