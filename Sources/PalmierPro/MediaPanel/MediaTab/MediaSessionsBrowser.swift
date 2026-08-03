import SwiftUI

/// Media-panel Sessions browser: local Workbench sessions for drag onto the timeline.
struct MediaSessionsBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var workbench = WorkbenchStore.shared

    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case completed
        case processing
        case ready
        case needsAttention

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: L10n.key("All")
            case .completed: L10n.key("Completed")
            case .processing: L10n.key("Processing")
            case .ready: L10n.key("Ready")
            case .needsAttention: L10n.key("Needs Attention")
            }
        }

        func matches(_ state: WorkbenchJobState) -> Bool {
            switch self {
            case .all: true
            case .completed: state == .completed
            case .processing: state == .running || state == .cancelling
            case .ready: state == .ready
            case .needsAttention: state == .failed || state == .cancelled
            }
        }
    }

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return workbench.sessions
            .filter { session in
                guard statusFilter.matches(session.state) else { return false }
                guard !query.isEmpty else { return true }
                let filename = session.sourceURL?.lastPathComponent ?? ""
                return session.title.localizedCaseInsensitiveContains(query)
                    || filename.localizedCaseInsensitiveContains(query)
                    || session.transcript?.text.localizedCaseInsensitiveContains(query) == true
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterToolbar
            if filteredSessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var filterToolbar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField(L10n.string("Search"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: Layout.panelHeaderHeight)
            .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            Menu {
                ForEach(StatusFilter.allCases) { filter in
                    Button {
                        statusFilter = filter
                    } label: {
                        if statusFilter == filter {
                            Label(L10n.string(key: filter.label), systemImage: "checkmark")
                        } else {
                            Text(L10n.string(key: filter.label))
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(
                        statusFilter == .all
                            ? AppTheme.Text.secondaryColor
                            : AppTheme.Accent.primary
                    )
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .background(
                        statusFilter == .all
                            ? AppTheme.Background.raisedColor
                            : AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
            }
            .menuStyle(.borderlessButton)
            .help(L10n.string("Filter sessions"))
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty && statusFilter == .all
                ? L10n.string("No sessions yet")
                : L10n.string("No matching sessions"),
            systemImage: "waveform.badge.mic",
            description: Text(
                searchText.isEmpty && statusFilter == .all
                    ? L10n.string("Transcribe media or create a dub to start a session.")
                    : L10n.string("Try a different search or clear the filter.")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(filteredSessions) { session in
                    sessionRow(session)
                }
            }
            .padding(AppTheme.Spacing.sm)
        }
    }

    private func sessionRow(_ session: WorkbenchSession) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                Text(session.title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.xs)
                Text(session.createdAt, style: .relative)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(sessionChips(session), id: \.title) { chip in
                    sessionChip(chip)
                }
            }
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .draggable(editor.sessionDragPayload(sessionID: session.id))
        .onTapGesture {
            Task { await editor.insertSessionMedia(session) }
        }
        .contextMenu {
            Button(L10n.string("Add to Timeline")) {
                Task { await editor.insertSessionMedia(session) }
            }
            if let sourceTrack = session.subtitleTrack {
                Button(L10n.string("Add Source Subtitles")) {
                    editor.insertSessionSubtitleTrack(
                        session,
                        track: sourceTrack,
                        scope: .source,
                        startFrame: editor.currentFrame
                    )
                }
            }
            ForEach(session.translationTracks) { translation in
                Button(L10n.string("Add \(translation.compactLanguageLabel) Subtitles")) {
                    editor.insertSessionSubtitleTrack(
                        session,
                        track: translation.track,
                        scope: .translation(languageCode: translation.languageCode),
                        startFrame: editor.currentFrame
                    )
                }
            }
            if session.outputURL != nil {
                Button(L10n.string("Add Dub Audio")) {
                    Task { await editor.insertSessionOutputMedia(session) }
                }
            }
        }
        .help(L10n.string("Drag onto the timeline to place media and source subtitles together"))
    }

    private struct SessionChip: Hashable {
        let title: String
        let icon: String
    }

    private func sessionChips(_ session: WorkbenchSession) -> [SessionChip] {
        var chips: [SessionChip] = []
        if let sourceURL = session.sourceURL,
           let type = ClipType(fileExtension: sourceURL.pathExtension.lowercased()) {
            chips.append(SessionChip(title: type.trackLabel, icon: type.sfSymbolName))
        }
        if session.subtitleTrack != nil {
            chips.append(SessionChip(title: "Source", icon: "captions.bubble"))
        }
        for translation in session.translationTracks {
            chips.append(SessionChip(
                title: translation.compactLanguageLabel,
                icon: "character.book.closed"
            ))
        }
        if session.outputURL != nil {
            chips.append(SessionChip(title: "Dub", icon: "waveform.badge.mic"))
        }
        chips.append(SessionChip(title: session.state.label, icon: "circle.fill"))
        return chips
    }

    private func sessionChip(_ chip: SessionChip) -> some View {
        Label(L10n.string(key: chip.title), systemImage: chip.icon)
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Accent.primary)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
            )
    }
}
