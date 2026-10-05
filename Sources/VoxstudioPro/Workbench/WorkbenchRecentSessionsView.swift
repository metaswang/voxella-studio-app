import AppKit
import SwiftUI

struct RecentSessionsView: View {
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var account = AccountService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("voxella.recentSessions.libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var deletionRequest: RecentSessionDeletionRequest?

    private var layout: LibraryLayout {
        get { LibraryLayout(rawValue: layoutRaw) ?? .grid }
        nonmutating set { layoutRaw = newValue.rawValue }
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: AppTheme.Workbench.recentSessionCardMinWidth,
                maximum: AppTheme.Workbench.recentSessionCardMaxWidth
            ),
            spacing: AppTheme.Spacing.xl,
            alignment: .top
        )]
    }

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
        .sessionDeletionAlert(item: $deletionRequest, onFinished: endSelection)
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
                .buttonStyle(LibrarySelectionActionButtonStyle())
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
                .buttonStyle(LibrarySelectionActionButtonStyle(tone: .destructive))
                .disabled(selectedSessionIDs.isEmpty)
                .help(L10n.string("Delete selected sessions"))

                Button(L10n.string("Done"), action: endSelection)
                    .buttonStyle(LibrarySelectionActionButtonStyle(tone: .accent))
            } else {
                Spacer()
                Button {
                    withAnimation(selectionAnimation) { isSelecting = true }
                } label: {
                    Label(L10n.string("Select"), systemImage: "checkmark.circle")
                }
                .buttonStyle(LibrarySelectionActionButtonStyle())
                .disabled(visibleSessionIDs.isEmpty || store.isHydrating)
                .help(L10n.string("Select sessions"))
            }
            LibraryLayoutPicker(layout: Binding(
                get: { layout },
                set: { layout = $0 }
            ), accessibilityLabel: L10n.string("Session layout"))
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
        } else if layout == .grid {
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xl) {
                ForEach(filteredSessions) { session in
                    sessionItem(session)
                }
            }
        } else {
            LazyVStack(spacing: AppTheme.Spacing.mdLg) {
                ForEach(filteredSessions) { session in
                    sessionItem(session)
                }
            }
        }
    }

    private func sessionItem(_ session: WorkbenchSession) -> some View {
        Group {
            if layout == .grid {
                SessionGridCard(
                    session: session,
                    isSelecting: isSelecting,
                    isSelected: selectedSessionIDs.contains(session.id),
                    isDeleting: store.isDeletingSession(session),
                    onOpen: { store.openSession(session.id) },
                    onDelete: { delete([session]) },
                    onToggleSelection: { toggleSelection(session.id) }
                )
            } else {
                SessionListRow(
                    session: session,
                    onOpen: { store.openSession(session.id) },
                    onDelete: { delete([session]) },
                    allowsDelete: true,
                    isSelecting: isSelecting,
                    isSelected: selectedSessionIDs.contains(session.id),
                    isDeleting: store.isDeletingSession(session),
                    onToggleSelection: { toggleSelection(session.id) }
                )
            }
        }
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
                    delete([session])
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
        delete(sessions)
    }

    private func delete(_ sessions: [WorkbenchSession]) {
        deletionRequest = RecentSessionDeletionRequest.prepare(sessions: sessions)
        if deletionRequest == nil { endSelection() }
    }

    private func endSelection() {
        withAnimation(selectionAnimation) {
            isSelecting = false
            selectedSessionIDs.removeAll()
        }
    }
}
