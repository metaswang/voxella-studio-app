import AppKit
import SwiftUI

/// Recent transcription sessions block aligned with web
/// `WorkbenchRecentSessionsSection` on the Transcription entry page.
struct WorkbenchRecentTranscriptSessionsSection: View {
    @Bindable private var store = WorkbenchStore.shared

    var modeTitle: String = "Import Files"
    var onChooseMedia: (() -> Void)?

    @State private var deletionRequest: RecentSessionDeletionRequest?
    @State private var searchText = ""
    @State private var statusFilter: WorkbenchSessionStatusFilter = .all

    private var uploadSessions: [WorkbenchSession] {
        store.sessions.filter { $0.source == .media }
    }

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return uploadSessions.filter { session in
            guard statusFilter.matches(session.status) else { return false }
            guard !query.isEmpty else { return true }
            let filename = session.sourceURL?.lastPathComponent ?? ""
            return session.title.localizedCaseInsensitiveContains(query)
                || filename.localizedCaseInsensitiveContains(query)
                || session.transcript?.text.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.format("Continue recent %@ sessions", L10n.string(key: modeTitle)))
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text(L10n.format("Reopen a recent %@ session to continue editing, translation, summary, or export.", L10n.string(key: modeTitle)))
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
        .sessionDeletionAlert(item: $deletionRequest)
    }

    private var filterToolbar: some View {
        WorkbenchRecentSessionFilterToolbar(searchText: $searchText, statusFilter: $statusFilter)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? String(format: L10n.string("No recent %@ sessions yet"), modeTitle)
                    : L10n.string("No matching sessions")
            )
            .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? L10n.string("Create a session from this page, then reopen it here to continue editing, translation, summary, or export.")
                    : L10n.string("Try a different search phrase or clear the status filter.")
            )
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            if searchText.isEmpty && statusFilter == .all, let onChooseMedia {
                Button(L10n.string("Choose media"), action: onChooseMedia)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, AppTheme.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xxl)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }

    private var sessionsTable: some View {
        WorkbenchRecentSessionsTable(
            sessions: filteredSessions,
            kindLabel: { L10n.string(key: $0.sessionType.label) },
            metadata: { session in
                [
                    session.sourceURL?.lastPathComponent,
                    session.duration.map { L10n.format("Duration %@", formatDuration($0)) },
                    L10n.format("Created %@", session.createdAt.formatted(date: .numeric, time: .shortened)),
                ].compactMap { $0 }
            },
            tag: { _ in nil },
            onOpen: { store.openSession($0.id) },
            actions: sessionActions
        )
    }

    @ViewBuilder
    private func sessionActions(_ session: WorkbenchSession) -> some View {
        Button(L10n.string("Open session")) { store.openSession(session.id) }
        if let transcriptionID = session.transcriptionID {
            Button(L10n.string("Re-transcribe and rebuild subtitles")) {
                retranscribe(transcriptionID)
            }
            .disabled(session.status.showsProcessing || session.status.showsQueued)
            Button(session.hasDub ? L10n.string("Redub") : L10n.string("Create dub")) {
                createDub(for: transcriptionID)
            }
            .disabled(session.transcript == nil)
        }
        if let sourceURL = session.sourceURL {
            Button(L10n.string("Reveal source in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            }
        }
        Divider()
        Button(L10n.string("Delete"), role: .destructive) { delete(session) }
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
        // Match web-ish duration display with millisecond-ish precision when short.
        let millis = Int(((seconds - Double(total)) * 1000).rounded(.down))
        return String(format: "%02d:%02d.%03d", minutes, secs, max(0, millis))
    }

    private func retranscribe(_ transcriptionID: UUID) {
        guard let job = store.transcriptions.first(where: { $0.id == transcriptionID }) else { return }
        store.retranscribe(transcriptionID, options: job.processingOptions)
    }

    private func createDub(for transcriptionID: UUID) {
        Task { @MainActor in
            _ = await store.createDubAfterAccess(for: transcriptionID)
        }
    }

    private func delete(_ session: WorkbenchSession) {
        deletionRequest = RecentSessionDeletionRequest.prepare(sessions: [session])
    }

}
