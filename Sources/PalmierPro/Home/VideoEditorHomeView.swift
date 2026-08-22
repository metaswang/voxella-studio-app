import SwiftUI

struct VideoEditorHomeView: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var registry = ProjectRegistry.shared

    @AppStorage("voxella.videoEditor.libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @State private var searchQuery = ""
    @State private var projectPendingDeletion: ProjectEntry?
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
                    if let project = suspendedProject {
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
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.baseColor)
        .alert("Delete Project?", isPresented: Binding(
            get: { projectPendingDeletion != nil },
            set: { if !$0 { projectPendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
            Button("Delete", role: .destructive) { deletePendingProject() }
        } message: {
            Text("“\(projectPendingDeletion?.name ?? "This project")” will be moved to the Trash. You can restore it from Finder.")
        }
        .alert("Project Couldn’t Be Deleted", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
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
                .help("Open a .voxella or legacy .palmier project")

                Button {
                    AppState.shared.createProjectInteractively()
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .help("Create a new timeline project")
            }

            HStack(spacing: AppTheme.Spacing.md) {
                searchField
                Spacer(minLength: 0)
                layoutPicker
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.md)
        .frame(maxWidth: AppTheme.Workbench.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search projects", text: $searchQuery)
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
        Picker("Layout", selection: Binding(
            get: { layout },
            set: { layout = $0 }
        )) {
            Image(systemName: "square.grid.2x2")
                .tag(LibraryLayout.grid)
                .help("Grid")
            Image(systemName: "list.bullet")
                .tag(LibraryLayout.list)
                .help("List")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: AppTheme.VideoEditorHome.layoutPickerWidth)
        .help("Project layout")
        .accessibilityLabel("Project layout")
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
            if !isSearching {
                NewTimelinePoster(action: { AppState.shared.createProjectInteractively() })
            }
            ForEach(entries) { entry in
                VideoProjectPoster(
                    entry: entry,
                    isInProgress: isSuspended(entry),
                    isDeleting: deletingProjectIDs.contains(entry.id),
                    onOpen: open,
                    onRemove: remove,
                    onDelete: { requestDeletion(entry) }
                )
            }
        }
    }

    private func projectList(entries: [ProjectEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.md) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Opened")
                    .frame(width: AppTheme.VideoEditorHome.listOpenedColumnWidth, alignment: .leading)
                Text("Location")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .tracking(AppTheme.Tracking.wide)
            .textCase(.uppercase)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.prominent))

            Divider()

            if !isSearching {
                NewTimelineListRow(action: { AppState.shared.createProjectInteractively() })
                if !entries.isEmpty {
                    Divider()
                }
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VideoProjectListRow(
                        entry: entry,
                        isInProgress: isSuspended(entry),
                        isDeleting: deletingProjectIDs.contains(entry.id),
                        onOpen: open,
                        onRemove: remove,
                        onDelete: { requestDeletion(entry) }
                    )
                    if index < entries.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .background(
            AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
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
            return "Create a timeline or open an existing project."
        }
        if isSearching {
            let matches = filteredEntries.count
            return matches == 1 ? "1 match" : "\(matches) matches"
        }
        return count == 1 ? "1 recent project" : "\(count) recent projects"
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

    private func requestDeletion(_ entry: ProjectEntry) {
        if let open = openProject(matching: entry) {
            deletionMessage = "Close \(open.name) before deleting."
            return
        }
        projectPendingDeletion = entry
    }

    private func deletePendingProject() {
        guard let entry = projectPendingDeletion else { return }
        projectPendingDeletion = nil
        deletingProjectIDs.insert(entry.id)
        Task { @MainActor in
            defer { deletingProjectIDs.remove(entry.id) }
            do {
                let result = try await AppState.shared.deleteProjects(withIDs: [entry.id])
                if let failed = result.failedNames.first {
                    deletionMessage = "Couldn’t move \(failed) to the Trash."
                } else if result.deletedIDs.isEmpty {
                    deletionMessage = "“\(entry.name)” is no longer in Recent Projects."
                }
            } catch {
                deletionMessage = error.localizedDescription
            }
        }
    }

    private func openProject(matching entry: ProjectEntry) -> ProjectEntry? {
        let paths = Set(AppState.shared.openProjects.compactMap { $0.fileURL?.standardizedFileURL.path })
        return paths.contains(entry.url.standardizedFileURL.path) ? entry : nil
    }
}

private enum LibraryLayout: String, Hashable {
    case grid
    case list
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
        .help("Create a new timeline project")
        .accessibilityLabel("New Project")
    }
}

private struct VideoProjectPoster: View {
    let entry: ProjectEntry
    let isInProgress: Bool
    let isDeleting: Bool
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard entry.isAccessible, !isDeleting else { return }
            onOpen(entry.url)
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
                    } else if isHovered {
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
                            isHovered || isInProgress
                                ? AppTheme.Border.primaryColor
                                : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
                .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(entry.name)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(
                            entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor
                        )
                        .lineLimit(1)
                    Text("Opened \(ProjectRecency.string(for: entry.lastOpenedDate))")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovered || isDeleting {
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
            ProjectEntryContextActions(
                entry: entry,
                onOpen: onOpen,
                onRemove: onRemove,
                onDelete: onDelete
            )
        }
        .help(entry.isAccessible ? "Open \(entry.name)" : "\(entry.name) is missing")
        .accessibilityLabel(entry.name)
    }
}

private struct NewTimelineListRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
                .frame(
                    width: AppTheme.VideoEditorHome.listPosterWidth,
                    height: AppTheme.VideoEditorHome.listPosterHeight
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .strokeBorder(
                            AppTheme.Border.primaryColor,
                            style: StrokeStyle(
                                lineWidth: AppTheme.BorderWidth.thin,
                                dash: AppTheme.VideoEditorHome.posterDash
                            )
                        )
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("New Project")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    Text("Start a blank timeline")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: AppTheme.VideoEditorHome.listOpenedColumnWidth)

                Color.clear
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .frame(minHeight: AppTheme.VideoEditorHome.listRowMinHeight)
            .background(isHovered ? AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.strong) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .help("Create a new timeline project")
        .accessibilityLabel("New Project")
    }
}

private struct VideoProjectListRow: View {
    let entry: ProjectEntry
    let isInProgress: Bool
    let isDeleting: Bool
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard entry.isAccessible, !isDeleting else { return }
            onOpen(entry.url)
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                ProjectPackageThumbnail(
                    url: entry.url,
                    freshness: entry.lastOpenedDate,
                    maxPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize,
                    placeholderSize: AppTheme.FontSize.lg
                )
                .frame(
                    width: AppTheme.VideoEditorHome.listPosterWidth,
                    height: AppTheme.VideoEditorHome.listPosterHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                }

                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(entry.name)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(
                            entry.isAccessible ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor
                        )
                        .lineLimit(1)
                    if isInProgress {
                        Text("In progress")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(
                                AppTheme.Background.raisedColor,
                                in: Capsule()
                            )
                    }
                    if !entry.isAccessible {
                        Text("Missing")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Status.errorColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(ProjectRecency.string(for: entry.lastOpenedDate))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                    .frame(width: AppTheme.VideoEditorHome.listOpenedColumnWidth, alignment: .leading)

                Text(locationLabel)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .frame(minHeight: AppTheme.VideoEditorHome.listRowMinHeight)
            .background(isHovered ? AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.strong) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isHovered || isDeleting {
                VideoProjectDeleteButton(
                    projectName: entry.name,
                    isDeleting: isDeleting,
                    action: onDelete
                )
                .padding(.trailing, AppTheme.Spacing.smMd)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .contextMenu {
            ProjectEntryContextActions(
                entry: entry,
                onOpen: onOpen,
                onRemove: onRemove,
                onDelete: onDelete
            )
        }
        .help(entry.isAccessible ? "Open \(entry.name)" : "\(entry.name) is missing")
        .accessibilityLabel(entry.name)
    }

    private var locationLabel: String {
        entry.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
        .help("Move \(projectName) to the Trash")
        .accessibilityLabel(
            isDeleting
                ? "Moving \(projectName) to the Trash"
                : "Move \(projectName) to the Trash"
        )
    }
}
