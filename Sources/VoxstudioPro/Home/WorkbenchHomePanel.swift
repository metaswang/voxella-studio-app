import SwiftUI

struct WorkbenchHomePanel: View {
    let onOpenSearch: () -> Void
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var projects = WorkbenchProjectsStore.shared
    @AppStorage("voxella.workbench.home.projectsExpanded") private var projectsExpanded = true
    @AppStorage("voxella.workbench.home.recentExpanded") private var recentExpanded = true
    @AppStorage("voxella.workbench.home.expandedProjectIDs") private var expandedProjectIDs = "[]"
    @State private var projectEditor: HomeProjectEditorRequest?
    @State private var errorMessage: String?

    private var openProjects: Set<UUID> {
        Set((try? JSONDecoder().decode([UUID].self, from: Data(expandedProjectIDs.utf8))) ?? [])
    }

    var body: some View {
        let sessions = store.sessions
        VStack(spacing: 0) {
            HomeNewSessionButton(onOpenSearch: onOpenSearch)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.top, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.md)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HomeDisclosureHeader(
                        title: "Projects", isExpanded: $projectsExpanded,
                        onAdd: { projectEditor = HomeProjectEditorRequest() },
                        alwaysShowsAdd: projects.projects.isEmpty
                    )
                    if projectsExpanded {
                        if let error = projects.loadError {
                            Text(L10n.string("Projects could not be loaded. The existing file was kept."))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .padding(AppTheme.Spacing.sm)
                                .help(error)
                        } else if projects.projects.isEmpty {
                            Button { projectEditor = HomeProjectEditorRequest() } label: {
                                Label(L10n.string("New project"), systemImage: "folder.badge.plus")
                                    .font(.system(size: AppTheme.FontSize.sm))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.homeRowHeight, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(projects.projects) { project in
                            projectRows(project, sessions: sessions)
                        }
                    }

                    HomeDisclosureHeader(title: "Recents", isExpanded: $recentExpanded, showsNewSession: true)
                        .padding(.top, AppTheme.Spacing.lg)
                    if recentExpanded {
                        if sessions.isEmpty {
                            Text(L10n.string("No sessions yet"))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .padding(AppTheme.Spacing.sm)
                        }
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.surfaceColor)
        .sheet(item: $projectEditor) { request in
            HomeProjectEditorSheet(request: request, projects: projects) { id in
                setProject(id, expanded: true)
                projectsExpanded = true
            }
            .appZoomEnvironment(presentationBoundary: true)
        }
        .alert(L10n.string("Projects"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage.map(L10n.display) ?? "")
        }
        .onChange(of: sessions.map(WorkbenchProjectSessionReference.init(session:)), initial: true) { _, _ in
            perform { try projects.synchronizeIdentities(with: sessions) }
        }
    }

    private func projectRows(_ project: WorkbenchSessionProject, sessions: [WorkbenchSession]) -> some View {
        let expanded = openProjects.contains(project.id)
        let members = projects.sessions(in: project, from: sessions)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HomeProjectFolderRow(project: project, isExpanded: expanded) {
                setProject(project.id, expanded: !expanded)
            }
            .contextMenu {
                Button(L10n.string("Rename")) {
                    projectEditor = HomeProjectEditorRequest(projectID: project.id, name: project.name)
                }
                Button(L10n.string("Remove project")) {
                    perform { try projects.remove(project.id) }
                }
            }
            .dropDestination(for: String.self) { values, _ in
                let ids = values.compactMap { value -> UUID? in
                    guard value.hasPrefix("voxstudio-session:") else { return nil }
                    return UUID(uuidString: String(value.dropFirst("voxstudio-session:".count)))
                }
                let dragged = sessions.filter { ids.contains($0.id) }
                guard !dragged.isEmpty else { return false }
                perform {
                    for session in dragged { try projects.move(session, to: project.id) }
                    setProject(project.id, expanded: true)
                }
                return true
            }

            if expanded {
                ForEach(members) { session in sessionRow(session) }
                    .padding(.leading, AppTheme.Workbench.homeSessionIndent)
                if members.isEmpty {
                    Text(L10n.string("No sessions yet"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.leading, AppTheme.Workbench.homeSessionIndent + AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.sm)
                }
            }
        }
    }

    private func sessionRow(_ session: WorkbenchSession) -> some View {
        HomeSessionRow(session: session, isSelected: store.selectedSessionID == session.id) {
            store.openSession(session.id)
        }
        .draggable("voxstudio-session:\(session.id.uuidString)")
        .contextMenu {
            Menu(L10n.string("Move to project")) {
                ForEach(projects.projects) { project in
                    Button(project.name) {
                        perform {
                            try projects.move(session, to: project.id)
                            setProject(project.id, expanded: true)
                            projectsExpanded = true
                        }
                    }
                }
                Divider()
                Button(L10n.string("New project")) {
                    projectEditor = HomeProjectEditorRequest(session: session)
                }
            }
            if projects.project(for: session) != nil {
                Button(L10n.string("Remove from project")) {
                    perform { try projects.move(session, to: nil) }
                }
            }
        }
    }

    private func setProject(_ id: UUID, expanded: Bool) {
        var ids = openProjects
        if expanded { ids.insert(id) } else { ids.remove(id) }
        ids.formIntersection(projects.projects.map(\.id))
        if let data = try? JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }),
           let value = String(data: data, encoding: .utf8) { expandedProjectIDs = value }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

private struct HomeNewSessionButton: View {
    let onOpenSearch: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HomeNewSessionMenu(showsTitle: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpenSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .frame(width: AppTheme.zoomed(32), height: AppTheme.Workbench.homeRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .help(L10n.string("Search tasks (⌘K)"))
            .accessibilityLabel(L10n.string("Search tasks"))
            .accessibilityIdentifier("home.search")
        }
        .foregroundStyle(AppTheme.Text.primaryColor)
    }
}

/// All Home entry points share the same options and navigation actions.
/// Hover only reveals the disclosure arrow; the options open on click.
private struct HomeNewSessionMenu: View {
    var showsTitle = false
    var projectID: UUID? = nil
    @State private var isHovering = false
    @State private var isPresented = false
    @Bindable private var store = WorkbenchStore.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if showsTitle {
                Button {
                    isPresented = false
                    store.sessionCreationProjectID = nil
                    store.selectedSessionID = nil
                    store.route = .dashboard
                } label: {
                    Label(L10n.string("New session"), systemImage: "square.and.pencil")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Button { isPresented.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .frame(width: AppTheme.zoomed(24), height: AppTheme.Workbench.homeRowHeight)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isPresented ? 1 : 0)
                .accessibilityLabel(L10n.string("New session menu"))
                Spacer(minLength: 0)
            } else {
                Button { isPresented.toggle() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .frame(width: AppTheme.zoomed(24), height: AppTheme.zoomed(28))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("New session"))
                .accessibilityLabel(L10n.string("New session menu"))
            }
        }
        .padding(.horizontal, showsTitle ? AppTheme.Spacing.sm : 0)
        .frame(minHeight: showsTitle ? AppTheme.Workbench.homeRowHeight : AppTheme.zoomed(28))
        .contentShape(Rectangle())
        .background(
            showsTitle && (isHovering || isPresented) ? AppTheme.Background.prominentColor : .clear,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
        )
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HomeNewSessionOptions(projectID: projectID) { isPresented = false }
                .appZoomEnvironment(presentationBoundary: true)
        }
        .accessibilityIdentifier(showsTitle ? "home.newSession" : "home.newSession.menu")
    }
}

private struct HomeNewSessionOptions: View {
    let projectID: UUID?
    let dismiss: () -> Void
    @Bindable private var store = WorkbenchStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            option("Record audio", icon: "mic") { record(.audioOnly) }
            option("Record screen", icon: "display") { record(.display) }
            option("Record meeting", icon: "person.2") { store.route = .meetBot }
            Divider().padding(.vertical, AppTheme.Spacing.xxs)
            option("Import media", icon: "square.and.arrow.down") {
                Task {
                    let urls = await WorkbenchFilePicker.pickMediaFiles()
                    if !urls.isEmpty { store.stageMediaImport(urls, projectID: projectID) }
                }
            }
            option("YouTube link", icon: "play.rectangle") { store.showNetVideoImport() }
            Divider().padding(.vertical, AppTheme.Spacing.xxs)
            option("Voiceover", icon: "waveform.and.mic") {
                Task { @MainActor in await store.startNewDubDraftAfterAccess(projectID: projectID) }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .frame(width: AppTheme.zoomed(220))
    }

    private func option(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HomeNewSessionOption(title: title, icon: icon) {
            dismiss()
            store.sessionCreationProjectID = projectID
            action()
        }
    }

    private func record(_ mode: RecordingCaptureMode) {
        store.showLocalRecording(LocalRecordingRequest(
            mode: mode, applicationBundleIdentifier: nil, startImmediately: false, purpose: .recording, sessionProjectID: projectID
        ))
    }
}

private struct HomeNewSessionOption: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: icon).frame(width: AppTheme.IconSize.smMd)
                Text(L10n.string(title))
                Spacer(minLength: 0)
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Workbench.homeRowHeight)
            .contentShape(Rectangle())
            .background(isHovering ? AppTheme.Background.prominentColor : .clear, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct HomeDisclosureHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var onAdd: (() -> Void)? = nil
    var alwaysShowsAdd = false
    var showsNewSession = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(L10n.string(title))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: AppTheme.zoomed(32))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsNewSession {
                HomeNewSessionMenu()
                    .opacity(isHovering ? 1 : 0)
            }
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus").frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || alwaysShowsAdd ? 1 : 0)
                .help(L10n.string("New project"))
                .accessibilityLabel(L10n.string("New project"))
            }
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .opacity(!isExpanded || isHovering ? 1 : 0)
            .accessibilityLabel(L10n.format(isExpanded ? "Collapse %@" : "Expand %@", L10n.string(title)))
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("home.section.\(title.lowercased())")
    }
}

private struct HomeProjectFolderRow: View {
    let project: WorkbenchSessionProject
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button(action: onToggle) {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    (isExpanded ? WorkbenchNavGlyph.folderOpen : .system("folder"))
                        .view(size: AppTheme.IconSize.smMd)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(project.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .frame(minHeight: AppTheme.Workbench.homeRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.name)
            .accessibilityLabel(L10n.format(isExpanded ? "Collapse %@" : "Expand %@", project.name))
            HomeNewSessionMenu(projectID: project.id)
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .background(isHovering ? AppTheme.Background.prominentColor : .clear, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct HomeSessionRow: View {
    let session: WorkbenchSession
    let isSelected: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AppTheme.Spacing.sm) {
                session.sessionType.navGlyph.view(size: AppTheme.IconSize.sm)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(session.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Workbench.homeRowHeight)
            .background(
                isSelected ? AppTheme.Background.raisedColor : isHovering ? AppTheme.Background.prominentColor : .clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.format("%@ · %@", session.title, L10n.string(key: session.sessionType.label)))
        .accessibilityLabel(L10n.format("%@ · %@", session.title, L10n.string(key: session.sessionType.label)))
        .accessibilityIdentifier("home.session.\(session.id.uuidString)")
    }
}

private struct HomeProjectEditorRequest: Identifiable {
    var id = UUID()
    var projectID: UUID? = nil
    var name = ""
    var session: WorkbenchSession? = nil
}

private struct HomeProjectEditorSheet: View {
    let request: HomeProjectEditorRequest
    let projects: WorkbenchProjectsStore
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string(request.projectID == nil ? "New project" : "Rename project"))
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
            TextField(L10n.string("Project name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit { save() }
            if let errorMessage {
                Text(L10n.display(errorMessage)).foregroundStyle(AppTheme.Status.errorColor)
                    .font(.system(size: AppTheme.FontSize.xs))
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string(request.projectID == nil ? "Create" : "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.zoomed(360))
        .onAppear { name = request.name; isNameFocused = true }
    }

    private func save() {
        do {
            if let id = request.projectID { try projects.rename(id, name: name) }
            else {
                let id = try projects.create(name: name, session: request.session)
                onCreated(id)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
