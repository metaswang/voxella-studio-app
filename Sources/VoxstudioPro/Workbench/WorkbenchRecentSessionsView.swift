import AppKit
import SwiftUI

struct RecentSessionsView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var account = AccountService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var deletionRequest: RecentSessionDeletionRequest?

    private var filteredSessions: [WorkbenchSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.sessions }
        return store.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query)
                || session.transcript?.text.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var visibleSessionIDs: Set<UUID> {
        Set(filteredSessions.filter { !store.isDeletingSession($0) }.map(\.id))
    }

    private var allVisibleSelected: Bool {
        !visibleSessionIDs.isEmpty && visibleSessionIDs.isSubset(of: selectedSessionIDs)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.transition)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            header
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.top, AppTheme.Spacing.xxl)

            ScrollView {
                sessionsContent
                    .padding(.horizontal, AppTheme.Spacing.xxl)
                    .padding(.bottom, AppTheme.Spacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
        .alert(item: $deletionRequest) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text(request.deleteButtonTitle)) {
                    // Use the confirmed snapshot, not a selection that may change while the alert is open.
                    for session in request.sessions {
                        store.deleteSession(session.id)
                    }
                    endSelection()
                },
                secondaryButton: .cancel()
            )
        }
        .onChange(of: visibleSessionIDs) { _, ids in
            selectedSessionIDs.formIntersection(ids)
        }
        .onChange(of: store.sessions.isEmpty) { _, isEmpty in
            if isEmpty { endSelection() }
        }
        .onExitCommand {
            if isSelecting { endSelection() }
        }
        .task(id: account.isSignedIn) {
            if account.isSignedIn {
                await store.refreshRemoteSessions()
            } else {
                store.clearRemoteSessions()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Recent sessions"))
                        .font(.system(size: AppTheme.FontSize.title2, weight: .semibold))
                    Text(L10n.string("Every completed workflow opens in the same session workspace."))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: AppTheme.Spacing.xl)
                TextField(L10n.string("Search sessions"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: AppTheme.Workbench.searchWidth)
            }

            selectionToolbar
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: AppTheme.Spacing.mdLg) {
            if isSelecting {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Accent.link)
                        .accessibilityHidden(true)
                    Text(selectionLabel)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .monospacedDigit()
                }
                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))

                Button {
                    withAnimation(selectionAnimation) {
                        if allVisibleSelected {
                            selectedSessionIDs.removeAll()
                        } else {
                            selectedSessionIDs = visibleSessionIDs
                        }
                    }
                } label: {
                    Text(L10n.string(allVisibleSelected ? "Deselect All" : "Select All"))
                }
                .buttonStyle(RecentSessionActionButtonStyle())
                .disabled(visibleSessionIDs.isEmpty)
                .help(L10n.string(allVisibleSelected ? "Deselect All" : "Select all visible sessions"))

                Spacer(minLength: AppTheme.Spacing.md)

                Button(role: .destructive, action: prepareSelectedDeletion) {
                    Label(
                        selectedSessionIDs.isEmpty
                            ? L10n.string("Delete")
                            : L10n.format("Delete %@", selectedSessionIDs.count),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(RecentSessionActionButtonStyle(tone: .destructive))
                .disabled(selectedSessionIDs.isEmpty)
                .help(L10n.string("Delete selected sessions"))

                Button(L10n.string("Done"), action: endSelection)
                    .buttonStyle(RecentSessionActionButtonStyle(tone: .accent))
            } else {
                Spacer()
                Button {
                    withAnimation(selectionAnimation) { isSelecting = true }
                } label: {
                    Label(L10n.string("Select"), systemImage: "checkmark.circle")
                }
                .buttonStyle(RecentSessionActionButtonStyle())
                .disabled(visibleSessionIDs.isEmpty || store.isHydrating)
                .help(L10n.string("Select sessions"))
            }
        }
        .frame(minHeight: AppTheme.zoomed(32))
        .animation(selectionAnimation, value: isSelecting)
    }

    private var selectionLabel: String {
        switch selectedSessionIDs.count {
        case 0: L10n.string("Select sessions")
        case 1: L10n.string("1 session selected")
        default: L10n.format("%@ sessions selected", selectedSessionIDs.count)
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        if store.isHydrating {
            loadingState("Loading saved sessions…")
        } else if filteredSessions.isEmpty && store.isLoadingRemoteSessions {
            loadingState("Loading VoxStudio Cloud sessions…")
        } else if filteredSessions.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? L10n.string("No sessions yet") : L10n.string("No matching sessions"),
                systemImage: "clock",
                description: Text(searchText.isEmpty
                    ? L10n.string("Transcribe media or create a dub to start a session.")
                    : L10n.string("Try a different session name or transcript phrase."))
            )
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        } else {
            LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                ForEach(filteredSessions) { session in
                    SessionListRow(
                        session: session,
                        onOpen: { store.openSession(session.id) },
                        onDelete: { deletionRequest = RecentSessionDeletionRequest(sessions: [session]) },
                        allowsDelete: true,
                        isSelecting: isSelecting,
                        isSelected: selectedSessionIDs.contains(session.id),
                        isDeleting: store.isDeletingSession(session),
                        onToggleSelection: { toggleSelection(session.id) }
                    )
                    .contextMenu {
                        if let sourceURL = session.sourceURL {
                            Button(L10n.string("Reveal source in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                            }
                        }
                        if let outputURL = session.outputURL {
                            Button(L10n.string("Reveal dub in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                            }
                        }
                        if !isSelecting && !store.isDeletingSession(session) {
                            Divider()
                            Button(L10n.string("Delete"), role: .destructive) {
                                deletionRequest = RecentSessionDeletionRequest(sessions: [session])
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadingState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text(L10n.string(message))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
    }

    private func toggleSelection(_ id: UUID) {
        withAnimation(selectionAnimation) {
            if selectedSessionIDs.contains(id) {
                selectedSessionIDs.remove(id)
            } else {
                selectedSessionIDs.insert(id)
            }
        }
    }

    private func prepareSelectedDeletion() {
        let sessions = filteredSessions.filter {
            selectedSessionIDs.contains($0.id) && !store.isDeletingSession($0)
        }
        guard !sessions.isEmpty else { return }
        deletionRequest = RecentSessionDeletionRequest(sessions: sessions)
    }

    private func endSelection() {
        withAnimation(selectionAnimation) {
            isSelecting = false
            selectedSessionIDs.removeAll()
        }
    }
}

private struct RecentSessionDeletionRequest: Identifiable {
    let id = UUID()
    let sessions: [WorkbenchSession]

    @MainActor var title: String {
        sessions.count == 1
            ? L10n.string("Delete session?")
            : L10n.format("Delete %@ sessions?", sessions.count)
    }

    @MainActor var message: String {
        sessions.count == 1
            ? L10n.format("\"%@\" and its saved workflow data will be removed.", sessions[0].title)
            : L10n.format("The %@ selected sessions and their saved workflow data will be removed.", sessions.count)
    }

    @MainActor var deleteButtonTitle: String {
        sessions.count == 1 ? L10n.string("Delete") : L10n.format("Delete %@", sessions.count)
    }
}

private struct RecentSessionActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, tone: tone)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let tone: Tone
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var tint: Color {
            switch tone {
            case .neutral: AppTheme.Text.secondaryColor
            case .accent: AppTheme.Accent.link
            case .destructive: AppTheme.Status.errorColor
            }
        }

        var body: some View {
            configuration.label
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(isEnabled ? tint : AppTheme.Text.mutedColor)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .frame(height: AppTheme.zoomed(32))
                .background {
                    Capsule()
                        .fill(tone == .neutral || !isEnabled
                            ? AppTheme.Background.raisedColor
                            : tint.opacity(AppTheme.Opacity.soft))
                        .overlay {
                            Capsule().fill(tint.opacity(isHovered && isEnabled ? AppTheme.Opacity.faint : 0))
                        }
                }
                .overlay {
                    Capsule().strokeBorder(
                        tone == .neutral || !isEnabled
                            ? AppTheme.Border.subtleColor
                            : tint.opacity(AppTheme.Opacity.moderate),
                        lineWidth: AppTheme.BorderWidth.thin
                    )
                }
                .opacity(isEnabled ? 1 : AppTheme.Opacity.strong)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: configuration.isPressed)
        }
    }
}
