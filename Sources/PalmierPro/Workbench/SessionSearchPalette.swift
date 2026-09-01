import SwiftUI

struct SessionSearchPalette: View {
    @Bindable var controller: SessionSearchController
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var account = AccountService.shared
    @FocusState private var focusedField: FocusField?
    @State private var hoveredRowID: String?

    private enum FocusField: Hashable {
        case query
    }

    private enum QuickAction: String, CaseIterable, Identifiable {
        case transcribe
        case record
        case netVideo
        case dub
        case videoEditor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcribe: "Transcribe media"
            case .record: "Record"
            case .netVideo: "Net video"
            case .dub: "Create a dub"
            case .videoEditor: "Edit a video"
            }
        }

        var detail: String {
            switch self {
            case .transcribe: "Import audio or video and create a transcript"
            case .record: "Capture your screen, window, region, or microphone"
            case .netVideo: "Paste a supported video link and transcribe it"
            case .dub: "Create an AI voiceover from a script"
            case .videoEditor: "Open the full timeline editor"
            }
        }

        var systemImage: String {
            switch self {
            case .transcribe: "text.bubble"
            case .record: "record.circle"
            case .netVideo: "play.rectangle"
            case .dub: "waveform.and.mic"
            case .videoEditor: "timeline.selection"
            }
        }

        var searchableText: String { "\(title) \(detail)" }

        func matches(_ query: String) -> Bool {
            searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedQuery: String {
        controller.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isQueryEmpty: Bool { trimmedQuery.isEmpty }

    private var recentSessions: ArraySlice<WorkbenchSession> {
        store.sessions.prefix(AppTheme.Workbench.searchPaletteRecentLimit)
    }

    private var matchingQuickActions: [QuickAction] {
        guard !isQueryEmpty else { return Array(QuickAction.allCases) }
        return QuickAction.allCases.filter { $0.matches(trimmedQuery) }
    }

    private var searchResults: [SessionSearchController.Result] {
        controller.l0Results + controller.l1Results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if isQueryEmpty {
                        recentSessionsSection
                    } else {
                        sessionResultsSection
                    }

                    if !matchingQuickActions.isEmpty {
                        quickActionsSection
                    }

                    if isQueryEmpty || "general settings".localizedCaseInsensitiveContains(trimmedQuery) {
                        settingsSection
                    }

                    if !isQueryEmpty,
                       !controller.isLoadingL0,
                       !controller.isLoadingL1,
                       searchResults.isEmpty,
                       matchingQuickActions.isEmpty {
                        emptySearchState
                    }

                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Status.errorColor)
                            .padding(.horizontal, AppTheme.Spacing.smMd)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(
            width: AppTheme.Workbench.searchPaletteWidth,
            height: AppTheme.Workbench.searchPaletteHeight
        )
        .background(AppTheme.Background.surfaceColor)
        .onAppear { focusedField = .query }
        .task {
            await Task.yield()
            focusedField = .query
            if account.isSignedIn {
                await store.refreshRemoteSessions()
            }
        }
        .task(id: controller.query) {
            await controller.search()
        }
        .task(id: controller.query) {
            await controller.searchTranscriptAfterPause()
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.mutedColor)

            SessionSearchField(
                text: $controller.query,
                isFocused: queryFocusBinding,
                placeholder: "Search sessions or run an action"
            )
            .frame(maxWidth: .infinity)
            .focused($focusedField, equals: .query)

            if !controller.query.isEmpty {
                Button {
                    controller.query = ""
                    focusedField = .query
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.mdLg))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            keycap("⌘K")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: AppTheme.Workbench.searchPaletteFieldHeight)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader("Recent sessions")

            if recentSessions.isEmpty {
                Text("No recent sessions yet")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.smMd)
            } else {
                ForEach(recentSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private var sessionResultsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader("Sessions")

            if searchResults.isEmpty {
                if controller.isLoadingL0 || controller.isLoadingL1 {
                    searchProgress
                }
            } else {
                if controller.isLoadingL0 || controller.isLoadingL1 {
                    searchProgress
                }
                ForEach(searchResults) { result in
                    resultRow(result)
                }
            }
        }
    }

    private var searchProgress: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            ProgressView()
                .controlSize(.small)
            Text(controller.isLoadingSemantic ? "Improving results…" : "Searching sessions…")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader("Quick actions")

            ForEach(matchingQuickActions) { action in
                paletteRow(id: "action-\(action.id)", systemImage: action.systemImage) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(action.title)
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(action.detail)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: AppTheme.Spacing.zero)
                } action: {
                    perform(action)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader("Settings")

            paletteRow(id: "settings-general", systemImage: "gearshape") {
                Text("General")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.zero)
                keycap("⌘,")
            } action: {
                dismiss()
                SettingsWindowController.shared.show(tab: .general)
            }
        }
    }

    private var emptySearchState: some View {
        Text("No matching sessions or actions")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.smMd)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
    }

    private func sessionRow(_ session: WorkbenchSession) -> some View {
        paletteRow(id: "session-\(session.id.uuidString)", systemImage: nil) {
            session.sessionType.navGlyph.view(size: AppTheme.IconSize.sm)
                .foregroundStyle(AppTheme.Accent.link)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(session.title)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(sessionMetadata(for: session))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.zero)
            Image(systemName: "chevron.right")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
        } action: {
            dismiss()
            store.openSession(session.id)
        }
    }

    private func resultRow(_ result: SessionSearchController.Result) -> some View {
        paletteRow(id: "result-\(result.id.uuidString)", systemImage: result.isTranscript ? "text.quote" : "doc.text") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(result.title)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if let snippet = result.snippet, !snippet.isEmpty {
                    Text(highlighted(snippet))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                } else if let summary = result.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: AppTheme.Spacing.zero)
            if let updatedAt = result.updatedAt {
                Text(updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        } action: {
            controller.open(result)
            dismiss()
        }
    }

    @ViewBuilder
    private func paletteRow<Content: View>(
        id: String,
        systemImage: String?,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.link)
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                }
                content()
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.searchPaletteRowHeight, alignment: .leading)
            .background(
                hoveredRowID == id ? AppTheme.Background.raisedColor : AppTheme.Background.clearColor,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRowID = $0 ? id : nil }
    }

    private func keycap(_ value: String) -> some View {
        Text(value)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium, design: .rounded))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.Background.prominentColor, in: Capsule())
    }

    private var queryFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField == .query },
            set: { focusedField = $0 ? .query : nil }
        )
    }

    private func sessionMetadata(for session: WorkbenchSession) -> String {
        let date = session.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        if session.sessionType.showsRecentListLabel {
            return "\(session.sessionType.label) · \(date)"
        }
        return date
    }

    private func perform(_ action: QuickAction) {
        dismiss()
        switch action {
        case .transcribe:
            Task { @MainActor in
                let urls = await WorkbenchFilePicker.pickMediaFiles()
                if !urls.isEmpty {
                    store.stageMediaImport(urls)
                }
            }
        case .record:
            store.showRecordImport()
        case .netVideo:
            store.showNetVideoImport()
        case .dub:
            store.addDub()
        case .videoEditor:
            store.route = .videoEditor
        }
    }

    private func highlighted(_ value: String) -> AttributedString {
        var result = AttributedString(value)
        guard !trimmedQuery.isEmpty,
              let range = result.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return result
        }
        result[range].backgroundColor = AppTheme.Accent.link.opacity(AppTheme.Opacity.moderate)
        return result
    }
}
