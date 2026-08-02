import SwiftUI

/// Recent transcription sessions block aligned with web
/// `WorkbenchRecentSessionsSection` on the Transcription entry page.
struct WorkbenchRecentTranscriptSessionsSection: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared

    var modeTitle: String = "Import Files"
    var onChooseMedia: (() -> Void)?

    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all

    enum StatusFilter: String, CaseIterable, Identifiable {
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

    private var uploadSessions: [WorkbenchSession] {
        store.sessions.filter { $0.source == .media }
    }

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return uploadSessions.filter { session in
            guard statusFilter.matches(session.state) else { return false }
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
                Text("Continue recent \(modeTitle) sessions")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text("Reopen a recent \(modeTitle) session to continue editing, translation, summary, or export.")
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
            .frame(height: 44)
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
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .frame(height: 44)
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
                                    : AppTheme.Accent.link.opacity(0.45),
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
                    ? "No recent \(modeTitle) sessions yet"
                    : "No matching sessions"
            )
            .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
            Text(
                searchText.isEmpty && statusFilter == .all
                    ? "Create a session from this page, then reopen it here to continue editing, translation, summary, or export."
                    : "Try a different search phrase or clear the status filter."
            )
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            if searchText.isEmpty && statusFilter == .all, let onChooseMedia {
                Button("Choose media", action: onChooseMedia)
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("SESSION")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("UPDATED")
                    .frame(width: 132, alignment: .leading)
                Text("TAGS")
                    .frame(width: 160, alignment: .leading)
                Color.clear.frame(width: 36)
            }
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor.opacity(0.85))

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(filteredSessions) { session in
                    recentSessionRow(session)
                    if session.id != filteredSessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(AppTheme.Background.baseColor.opacity(0.35), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    private func recentSessionRow(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                store.openSession(session.id)
            } label: {
                HStack(alignment: .center, spacing: 0) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                        sourceBadge
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.system(size: AppTheme.FontSize.md, weight: .bold))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text("Import")
                                    .foregroundStyle(AppTheme.Accent.link)
                                metaDot
                                if let filename = session.sourceURL?.lastPathComponent {
                                    Text(filename)
                                        .lineLimit(1)
                                }
                                if let duration = session.duration {
                                    metaDot
                                    Text("Duration \(formatDuration(duration))")
                                }
                                metaDot
                                Text("Created \(session.createdAt.formatted(date: .numeric, time: .shortened))")
                            }
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(relativeUpdated(session.modifiedAt))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: 132, alignment: .leading)

                    Text("-")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .frame(width: 160, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Open session") { store.openSession(session.id) }
                if let transcriptionID = session.transcriptionID {
                    Button("Transcribe again") {
                        retranscribe(transcriptionID)
                    }
                    .disabled(session.state == .running || session.state == .cancelling)
                    Button(session.hasDub ? "Redub" : "Create dub") {
                        createDub(for: transcriptionID)
                    }
                    .disabled(session.transcript == nil)
                }
                if let sourceURL = session.sourceURL {
                    Button("Reveal source in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    delete(session)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Session options")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
        .contextMenu {
            Button("Open session") { store.openSession(session.id) }
            if let transcriptionID = session.transcriptionID {
                Button("Transcribe again") { retranscribe(transcriptionID) }
                Button(session.hasDub ? "Redub" : "Create dub") { createDub(for: transcriptionID) }
                    .disabled(session.transcript == nil)
            }
            if let sourceURL = session.sourceURL {
                Button("Reveal source in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                }
            }
            Divider()
            Button("Delete", role: .destructive) { delete(session) }
        }
    }

    private var sourceBadge: some View {
        Image(systemName: "square.and.arrow.down")
            .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
            .foregroundStyle(AppTheme.Accent.link)
            .frame(width: AppTheme.Workbench.sessionIconSize, height: AppTheme.Workbench.sessionIconSize)
            .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private var metaDot: some View {
        Text("·")
            .opacity(0.4)
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
        // Match web-ish duration display with millisecond-ish precision when short.
        let millis = Int(((seconds - Double(total)) * 1000).rounded(.down))
        return String(format: "%02d:%02d.%03d", minutes, secs, max(0, millis))
    }

    private func retranscribe(_ transcriptionID: UUID) {
        guard let job = store.transcriptions.first(where: { $0.id == transcriptionID }) else { return }
        guard models.hasRequiredTranscriptionModels(
            languageCode: job.languageCode,
            speakerCount: job.speakerCount.count
        ) else {
            models.presentManager()
            return
        }
        store.selectedTranscriptionID = transcriptionID
        store.route = .transcribe
        store.runTranscription(transcriptionID)
    }

    private func createDub(for transcriptionID: UUID) {
        _ = store.createDub(for: transcriptionID)
    }

    private func delete(_ session: WorkbenchSession) {
        store.deleteSession(session.id)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
