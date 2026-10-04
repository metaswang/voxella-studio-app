import SwiftUI

struct VideoEditorHomeView: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var registry = ProjectRegistry.shared

    @AppStorage("voxella.videoEditor.libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @State private var searchQuery = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSelecting = false
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var projectsPendingDeletion: [ProjectEntry] = []
    @State private var deletingProjectIDs: Set<UUID> = []
    @State private var deletionMessage: String?
    @FocusState private var isSearchFocused: Bool

    private var layout: LibraryLayout {
        get { LibraryLayout(rawValue: layoutRaw) ?? .grid }
        nonmutating set { layoutRaw = newValue.rawValue }
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: AppTheme.VideoEditorHome.posterMinWidth),
                spacing: AppTheme.Spacing.xl,
                alignment: .top
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    if let project = suspendedProject, !isSelecting {
                        resumeBanner(project)
                    }
                    library
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.top, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.xxl)
                .frame(maxWidth: AppTheme.Workbench.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .appScrollEdgeEffect(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.baseColor)
        .alert(L10n.string(projectsPendingDeletion.count == 1 ? "Delete Project?" : "Delete Selected Projects?"), isPresented: Binding(
            get: { !projectsPendingDeletion.isEmpty },
            set: { if !$0 { projectsPendingDeletion = [] } }
        )) {
            Button("Cancel", role: .cancel) { projectsPendingDeletion = [] }
            Button("Delete", role: .destructive) { deletePendingProjects() }
        } message: {
            Text(deletionPrompt)
        }
        .alert(L10n.string("Project Couldn’t Be Deleted"), isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage.map(L10n.display) ?? "")
        }
        .onChange(of: Set(filteredEntries.map(\.id))) { _, ids in
            selectedProjectIDs.formIntersection(ids)
        }
        .onChange(of: registry.entries.isEmpty) { _, isEmpty in
            if isEmpty { endSelection() }
        }
        .onExitCommand {
            if isSelecting { endSelection() }
        }
    }

    private var visibleProjectIDs: Set<UUID> {
        Set(filteredEntries.map(\.id)).subtracting(deletingProjectIDs)
    }

    private var allVisibleSelected: Bool {
        !visibleProjectIDs.isEmpty && visibleProjectIDs.isSubset(of: selectedProjectIDs)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.transition)
    }

    private var toolbar: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Projects")
                        .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.md)

                Button("Open…") {
                    AppState.shared.openProjectFromPanel()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .help(L10n.string("Open a .voxella or legacy .palmier project"))

                Button {
                    AppState.shared.createProjectInteractively()
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .help(L10n.string("Create a new timeline project"))
            }

            HStack(spacing: AppTheme.Spacing.md) {
                searchField
                Spacer(minLength: 0)
                if !isSelecting {
                    Button {
                        withAnimation(selectionAnimation) { isSelecting = true }
                    } label: {
                        Label(L10n.string("Select"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(LibrarySelectionActionButtonStyle())
                    .disabled(visibleProjectIDs.isEmpty || !deletingProjectIDs.isEmpty)
                    .help(L10n.string("Select projects"))
                }
                layoutPicker
            }
            if isSelecting { selectionToolbar }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.md)
        .frame(maxWidth: AppTheme.Workbench.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var selectionToolbar: some View {
        HStack(spacing: AppTheme.Spacing.mdLg) {
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
                    selectedProjectIDs = allVisibleSelected ? [] : visibleProjectIDs
                }
            } label: {
                Text(L10n.string(allVisibleSelected ? "Deselect All" : "Select All"))
            }
            .buttonStyle(LibrarySelectionActionButtonStyle())
            .disabled(visibleProjectIDs.isEmpty || !deletingProjectIDs.isEmpty)
            .help(L10n.string(allVisibleSelected ? "Deselect All" : "Select all visible projects"))

            Spacer(minLength: AppTheme.Spacing.md)

            Button(role: .destructive) {
                projectsPendingDeletion = filteredEntries.filter { selectedProjectIDs.contains($0.id) }
            } label: {
                Label(
                    selectedProjectIDs.isEmpty
                        ? L10n.string("Delete")
                        : L10n.format("Delete %@", selectedProjectIDs.count),
                    systemImage: "trash"
                )
            }
            .buttonStyle(LibrarySelectionActionButtonStyle(tone: .destructive))
            .disabled(selectedProjectIDs.isEmpty || !deletingProjectIDs.isEmpty)
            .help(L10n.string("Delete selected projects"))

            Button(L10n.string("Done"), action: endSelection)
                .buttonStyle(LibrarySelectionActionButtonStyle(tone: .accent))
                .disabled(!deletingProjectIDs.isEmpty)
        }
        .frame(minHeight: AppTheme.zoomed(32))
    }

    private var selectionLabel: String {
        switch selectedProjectIDs.count {
        case 0: L10n.string("Select projects")
        case 1: L10n.string("1 project selected")
        default: L10n.format("%@ projects selected", selectedProjectIDs.count)
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField(L10n.string("Search projects"), text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand {
                    searchQuery = ""
                    isSearchFocused = false
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.system(size: AppTheme.FontSize.smMd))
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .frame(width: AppTheme.VideoEditorHome.searchWidth)
        .frame(height: AppTheme.Workbench.recentSessionControlHeight)
        .background(
            AppTheme.Background.raisedColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var layoutPicker: some View {
        LibraryLayoutPicker(layout: Binding(
            get: { layout },
            set: { layout = $0 }
        ), accessibilityLabel: L10n.string("Project layout"))
    }

    @ViewBuilder
    private var library: some View {
        let entries = filteredEntries
        if entries.isEmpty, isSearching {
            emptySearchState
        } else if layout == .grid {
            projectGrid(entries: entries)
        } else {
            projectList(entries: entries)
        }
    }

    private func projectGrid(entries: [ProjectEntry]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xl) {
            if !isSearching && !isSelecting {
                NewTimelinePoster(action: { AppState.shared.createProjectInteractively() })
            }
            ForEach(entries) { entry in
                VideoProjectPoster(
                    entry: entry,
                    isInProgress: isSuspended(entry),
                    isDeleting: deletingProjectIDs.contains(entry.id),
                    isSelecting: isSelecting,
                    isSelected: selectedProjectIDs.contains(entry.id),
                    onToggleSelection: { toggleSelection(entry.id) },
                    onOpen: open,
                    onRemove: remove,
                    onDelete: { requestDeletion(entry) }
                )
            }
        }
    }

    private func projectList(entries: [ProjectEntry]) -> some View {
        LazyVStack(spacing: AppTheme.Spacing.mdLg) {
            if !isSearching && !isSelecting {
                NewTimelineListRow(action: { AppState.shared.createProjectInteractively() })
            }
            ForEach(entries) { entry in
                VideoProjectListRow(
                    entry: entry,
                    isInProgress: isSuspended(entry),
                    isDeleting: deletingProjectIDs.contains(entry.id),
                    isSelecting: isSelecting,
                    isSelected: selectedProjectIDs.contains(entry.id),
                    onToggleSelection: { toggleSelection(entry.id) },
                    onOpen: open,
                    onRemove: remove,
                    onDelete: { requestDeletion(entry) }
                )
            }
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Text("No matching projects")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Text("Try a different name, or clear the search to see recents.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xxl)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(
                    AppTheme.Border.subtleColor,
                    style: StrokeStyle(
                        lineWidth: AppTheme.BorderWidth.thin,
                        dash: AppTheme.VideoEditorHome.posterDash
                    )
                )
        )
    }

    @ViewBuilder
    private func resumePoster(for project: VideoProject) -> some View {
        let poster = RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        Group {
            if let url = project.fileURL {
                ProjectPackageThumbnail(
                    url: url,
                    freshness: resumeFreshness(for: url),
                    maxPixelSize: AppTheme.VideoEditorHome.posterThumbnailMaxPixelSize,
                    placeholderSize: AppTheme.FontSize.xl
                )
            } else {
                AppTheme.Background.placeholderColor
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.light))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
            }
        }
        .aspectRatio(AppTheme.VideoEditorHome.posterAspect, contentMode: .fit)
        .frame(width: AppTheme.VideoEditorHome.resumePosterWidth)
        .clipShape(poster)
        .overlay {
            poster.strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
    }

    private func resumeFreshness(for url: URL) -> Date {
        registry.entries.first {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }?.lastOpenedDate ?? .distantPast
    }

    private func resumeBanner(_ project: VideoProject) -> some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            resumePoster(for: project)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Continue editing")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Text(project.displayName ?? Project.defaultProjectName)
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .lineLimit(1)
                Text("The timeline is paused. Reopen it to pick up where you left off.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: AppTheme.Spacing.md)

            Button("Continue") {
                appState.resumeEditor()
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
        }
        .padding(AppTheme.Spacing.lg)
        .background(
            AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var subtitle: String {
        let count = registry.entries.count
        if count == 0 {
            return L10n.string("Create a timeline or open an existing project.")
        }
        if isSearching {
            let matches = filteredEntries.count
            return matches == 1
                ? L10n.string("1 match")
                : L10n.format("%@ matches", matches)
        }
        return count == 1
            ? L10n.string("1 recent project")
            : L10n.format("%@ recent projects", count)
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredEntries: [ProjectEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return registry.sortedEntries }
        return registry.sortedEntries.filter { $0.name.localizedStandardContains(query) }
    }

    private var suspendedProject: VideoProject? {
        guard appState.editorPresentation == .suspended else { return nil }
        return appState.activeProject
    }

    private func isSuspended(_ entry: ProjectEntry) -> Bool {
        guard let url = suspendedProject?.fileURL else { return false }
        return entry.url.standardizedFileURL == url.standardizedFileURL
    }

    private func open(_ url: URL) {
        AppState.shared.openProject(at: url)
    }

    private func remove(_ url: URL) {
        registry.remove(url)
    }

    private func toggleSelection(_ id: UUID) {
        guard deletingProjectIDs.isEmpty else { return }
        withAnimation(selectionAnimation) {
            if selectedProjectIDs.contains(id) {
                selectedProjectIDs.remove(id)
            } else {
                selectedProjectIDs.insert(id)
            }
        }
    }

    private func endSelection() {
        guard deletingProjectIDs.isEmpty else { return }
        withAnimation(selectionAnimation) {
            isSelecting = false
            selectedProjectIDs.removeAll()
        }
    }

    private var deletionPrompt: String {
        if projectsPendingDeletion.count == 1 {
            return L10n.format(
                "“%@” will be moved to the Trash. You can restore it from Finder.",
                projectsPendingDeletion[0].name
            )
        }
        return L10n.format(
            "The %@ selected projects will be moved to the Trash. You can restore them from Finder.",
            projectsPendingDeletion.count
        )
    }

    private func requestDeletion(_ entry: ProjectEntry) {
        guard deletingProjectIDs.isEmpty else { return }
        projectsPendingDeletion = [entry]
    }

    private func deletePendingProjects() {
        // Capture the confirmed projects before clearing the alert or changing selection.
        let entries = projectsPendingDeletion
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        projectsPendingDeletion = []
        deletingProjectIDs.formUnion(ids)
        Task { @MainActor in
            do {
                let result = try await appState.deleteProjects(withIDs: ids)
                deletingProjectIDs.subtract(ids)
                selectedProjectIDs.subtract(result.deletedIDs)
                if !result.failedNames.isEmpty {
                    selectedProjectIDs.formUnion(ids.intersection(visibleProjectIDs))
                    deletionMessage = L10n.format("Couldn’t move %@ to the Trash.", result.failedNames.formatted())
                } else {
                    endSelection()
                }
            } catch {
                deletingProjectIDs.subtract(ids)
                selectedProjectIDs.formUnion(ids.intersection(visibleProjectIDs))
                deletionMessage = error.localizedDescription
            }
        }
    }

}

private struct NewTimelinePoster: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(AppTheme.Background.surfaceColor)
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .frame(
                            width: AppTheme.VideoEditorHome.newBadgeSize,
                            height: AppTheme.VideoEditorHome.newBadgeSize
                        )
                        .background(
                            AppTheme.Background.raisedColor,
                            in: Circle()
                        )
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    AppTheme.Border.subtleColor,
                                    lineWidth: AppTheme.BorderWidth.thin
                                )
                        }
                }
                .aspectRatio(AppTheme.VideoEditorHome.posterAspect, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            isHovered ? AppTheme.Accent.primary : AppTheme.Border.primaryColor,
                            style: StrokeStyle(
                                lineWidth: isHovered ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin,
                                dash: AppTheme.VideoEditorHome.posterDash
                            )
                        )
                }
                .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("New Project")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Blank timeline")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
                .help(L10n.string("Create a new timeline project"))
        .accessibilityLabel("New Project")
    }
}

private struct VideoProjectPoster: View {
    let entry: ProjectEntry
    let isInProgress: Bool
    let isDeleting: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard !isDeleting else { return }
            if isSelecting {
                onToggleSelection()
            } else if entry.isAccessible {
                onOpen(entry.url)
            }
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ZStack {
                    ProjectPackageThumbnail(
                        url: entry.url,
                        freshness: entry.lastOpenedDate,
                        maxPixelSize: AppTheme.VideoEditorHome.posterThumbnailMaxPixelSize,
                        placeholderSize: AppTheme.FontSize.title1
                    )
                    .aspectRatio(AppTheme.VideoEditorHome.posterAspect, contentMode: .fit)

                    if !entry.isAccessible {
                        AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.high)
                        VStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                            Text("File missing")
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        }
                        .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
                    } else if isHovered && !isSelecting {
                        AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.VideoEditorHome.hoverOpenOverlay)
                        Text("Open")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.MediaOverlay.primaryColor)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.vertical, AppTheme.Spacing.smMd)
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isInProgress {
                        Text("In progress")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Background.baseColor)
                            .padding(.horizontal, AppTheme.Spacing.smMd)
                            .padding(.vertical, AppTheme.Spacing.xs)
                            .background(AppTheme.Accent.primary, in: Capsule())
                            .padding(AppTheme.Spacing.smMd)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            isSelecting && isSelected
                                ? AppTheme.Accent.link
                                : (isHovered || isInProgress ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor),
                            lineWidth: isSelecting && isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Group {
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            } else {
                                LibrarySelectionIndicator(isSelected: isSelected)
                            }
                        }
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        .background(AppTheme.Background.surfaceColor, in: Circle())
                        .padding(AppTheme.Spacing.smMd)
                    }
                }
                .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(entry.name)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(
                            entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor
                        )
                        .lineLimit(1)
                    Text(L10n.format("Opened %@", ProjectRecency.string(for: entry.lastOpenedDate)))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if !isSelecting && (isHovered || isDeleting) {
                VideoProjectDeleteButton(
                    projectName: entry.name,
                    isDeleting: isDeleting,
                    action: onDelete
                )
                .padding(AppTheme.Spacing.smMd)
            }
        }
        .opacity(entry.isAccessible ? 1 : AppTheme.Opacity.strong)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .contextMenu {
            if !isSelecting && !isDeleting {
                ProjectEntryContextActions(
                    entry: entry,
                    onOpen: onOpen,
                    onRemove: onRemove,
                    onDelete: onDelete
                )
            }
        }
        .disabled(isDeleting)
        .help(isSelecting
            ? L10n.string(isSelected ? "Deselect project" : "Select project")
            : (entry.isAccessible ? L10n.format("Open %@", entry.name) : L10n.format("%@ is missing", entry.name)))
        .accessibilityLabel(entry.name)
        .accessibilityValue(isSelecting ? L10n.string(isSelected ? "Selected" : "Not selected") : "")
        .accessibilityAddTraits(isSelecting && isSelected ? [.isSelected] : [])
    }
}

private struct NewTimelineListRow: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.lgXl) {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(
                        width: AppTheme.Workbench.recentSessionThumbnailWidth,
                        height: AppTheme.Workbench.recentSessionThumbnailHeight
                    )
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(
                                AppTheme.Border.primaryColor,
                                style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: AppTheme.VideoEditorHome.posterDash)
                            )
                    }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("New Project")
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                    Text("Start a blank timeline")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.lgXl)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ProjectListCardChrome(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .help(L10n.string("Create a new timeline project"))
        .accessibilityLabel("New Project")
    }
}

private struct VideoProjectListRow: View {
    let entry: ProjectEntry
    let isInProgress: Bool
    let isDeleting: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !isDeleting else { return }
            if isSelecting {
                onToggleSelection()
            } else if entry.isAccessible {
                onOpen(entry.url)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.lg) {
                if isSelecting {
                    LibrarySelectionIndicator(isSelected: isSelected)
                }
                projectContent
            }
            .padding(AppTheme.Spacing.lgXl)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelecting
            ? L10n.string(isSelected ? "Deselect project" : "Select project")
            : (entry.isAccessible ? L10n.format("Open %@", entry.name) : L10n.format("%@ is missing", entry.name)))
        .accessibilityLabel(entry.name)
        .accessibilityValue(isSelecting ? L10n.string(isSelected ? "Selected" : "Not selected") : "")
        .accessibilityAddTraits(isSelecting && isSelected ? [.isSelected] : [])
        .modifier(ProjectListCardChrome(isHovered: isHovered, isSelected: isSelecting && isSelected))
        .overlay(alignment: .trailing) {
            if !isSelecting && !isDeleting && isHovered {
                VideoProjectDeleteButton(projectName: entry.name, isDeleting: false, action: onDelete)
                    .padding(.trailing, AppTheme.Spacing.lgXl)
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.transition), value: isSelecting)
        .animation(reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.hover), value: isSelected)
        .contextMenu {
            if !isSelecting && !isDeleting {
                ProjectEntryContextActions(entry: entry, onOpen: onOpen, onRemove: onRemove, onDelete: onDelete)
            }
        }
        .disabled(isDeleting)
        .opacity(isDeleting ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
    }

    private var projectContent: some View {
        HStack(spacing: AppTheme.Spacing.lgXl) {
            ProjectPackageThumbnail(
                url: entry.url,
                freshness: entry.lastOpenedDate,
                maxPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize,
                placeholderSize: AppTheme.FontSize.lg
            )
            .frame(
                width: AppTheme.Workbench.recentSessionThumbnailWidth,
                height: AppTheme.Workbench.recentSessionThumbnailHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    .lineLimit(1)
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Text(L10n.format("Opened %@", ProjectRecency.string(for: entry.lastOpenedDate)))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(locationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isInProgress {
                Text("In progress")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.smMd)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(AppTheme.Background.raisedColor, in: Capsule())
            } else if !entry.isAccessible {
                Text("Missing")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            if isDeleting {
                ProgressView().controlSize(.small)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            } else if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                    .opacity(isHovered ? 0 : 1)
            }
        }
    }

    private var locationLabel: String {
        entry.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct ProjectListCardChrome: ViewModifier {
    let isHovered: Bool
    var isSelected = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .fill(isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                                .fill(AppTheme.Accent.link.opacity(AppTheme.Opacity.faint))
                        }
                    }
                    .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .strokeBorder(
                        isSelected ? AppTheme.Accent.link.opacity(AppTheme.Opacity.strong)
                            : (isHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor),
                        lineWidth: isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                    )
            }
    }
}

private struct VideoProjectDeleteButton: View {
    let projectName: String
    let isDeleting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isDeleting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.Status.errorColor)
        .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
        .background(AppTheme.Background.prominentColor, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.md)
        .disabled(isDeleting)
        .help(L10n.format("Move %@ to the Trash", projectName))
        .accessibilityLabel(
            isDeleting
                ? L10n.format("Moving %@ to the Trash", projectName)
                : L10n.format("Move %@ to the Trash", projectName)
        )
    }
}
