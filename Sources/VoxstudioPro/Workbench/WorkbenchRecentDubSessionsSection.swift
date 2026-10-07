import AppKit
import SwiftUI

/// Recent Dub sessions block aligned with the Transcribe entry-page session menu.
struct WorkbenchRecentDubSessionsSection: View {
    @Bindable private var store = WorkbenchStore.shared

    @State private var searchText = ""
    @State private var statusFilter: WorkbenchSessionStatusFilter = .all

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.recentDubSessions.filter { session in
            guard statusFilter.matches(session.status) else { return false }
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
        WorkbenchRecentSessionFilterToolbar(searchText: $searchText, statusFilter: $statusFilter, showsVoiceInput: true)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? L10n.string("No recent dub sessions yet")
                    : L10n.string("No matching sessions")
            )
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? L10n.string("Generate a dub above to return to it here.")
                    : L10n.string("Try a different search phrase or clear the status filter.")
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
        WorkbenchRecentSessionsTable(
            sessions: filteredSessions,
            kindLabel: { $0.source == .media ? L10n.string("Transcript dub") : L10n.string("Dub") },
            metadata: { session in
                [
                    session.duration.map { L10n.format("Duration %@", formatDuration($0)) },
                    L10n.format("Created %@", session.createdAt.formatted(date: .numeric, time: .shortened)),
                ].compactMap { $0 }
            },
            tag: { $0.sessionTag },
            onOpen: { store.openSession($0.id) },
            actions: sessionMenuActions
        )
    }

    @ViewBuilder
    private func sessionMenuActions(_ session: WorkbenchSession) -> some View {
        Button(L10n.string("Open session")) { store.openSession(session.id) }
        if let dubID = session.dubID {
            Button(L10n.string("Edit dub")) { store.openDub(dubID) }
            Button(L10n.string("Regenerate")) { regenerate(dubID) }
                .disabled(!canRegenerate(dubID))
            if let outputURL = session.outputURL {
                Button(L10n.string("Reveal dub in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            }
            Divider()
            Button(L10n.string("Delete dub"), role: .destructive) {
                store.deleteDub(dubID)
            }
        }
    }

    private func canRegenerate(_ id: UUID) -> Bool {
        guard let job = store.dubs.first(where: { $0.id == id }) else { return false }
        guard !job.state.isActive else { return false }
        return (job.segments ?? []).contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func regenerate(_ id: UUID) {
        guard store.dubs.contains(where: { $0.id == id }) else { return }
        store.openDub(id)
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

}
