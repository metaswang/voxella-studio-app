import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenOptions {
    var startTutorial = false
}

enum EditorPresentation: String, Equatable {
    case none
    case active
    case suspended
}

enum ProjectError: LocalizedError {
    case nameTaken(URL)
    case invalidName(String)
    case openProjects([String])
    case projectsOpening([String])
    case deletionInProgress(URL)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let url):
            "A project named “\(url.deletingPathExtension().lastPathComponent)” already exists in that folder. Pick another name."
        case .invalidName(let name):
            "“\(name)” isn't a valid project name. Use a plain name without slashes or path components."
        case .openProjects(let names):
            "Close \(names.formatted()) before deleting."
        case .projectsOpening(let names):
            "Wait for \(names.formatted()) to finish opening before deleting."
        case .deletionInProgress(let url):
            "“\(url.deletingPathExtension().lastPathComponent)” is being moved to the Trash."
        }
    }
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    /// The single open video project, if any (active or suspended).
    private(set) var activeProject: VideoProject?
    private(set) var editorPresentation: EditorPresentation = .none
    private(set) var editorSession: EditorSessionController?

    private var projectPathsBeingDeleted: Set<String> = []
    private var projectOpenCounts: [String: Int] = [:]

    var openProjects: [VideoProject] {
        NSDocumentController.shared.documents.compactMap { $0 as? VideoProject }
    }

    var isEditorActive: Bool { editorPresentation == .active }

    private(set) var mcpService: MCPService?

    func startMCPService() {
        guard mcpService == nil else { return }
        guard MCPService.isEnabledPreference else {
            Log.mcp.notice("mcp disabled in settings; not starting")
            return
        }
        let service = MCPService(projectProvider: { [weak self] in
            self?.activeProject
        })
        service.start()
        mcpService = service
    }

    func stopMCPService() {
        mcpService?.stop()
        mcpService = nil
    }

    func setMCPEnabled(_ enabled: Bool) {
        MCPService.isEnabledPreference = enabled
        if enabled {
            startMCPService()
        } else {
            stopMCPService()
        }
    }

    // MARK: - Editor presentation

    /// Embed and show the project editor in the main window.
    func presentEditor(for project: VideoProject) {
        if let current = activeProject, current !== project {
            // Recover from stale bindings instead of silently keeping the old editor visible.
            Log.project.warning(
                "presentEditor replacing active project \(current.displayName) with \(project.displayName)"
            )
            current.editorViewModel.pause()
            current.editorViewModel.isPointerInputEnabled = false
            teardownSession()
            activeProject = nil
            editorPresentation = .none
            HomeWindowController.shared.applyEditorMode(false)
        }
        if activeProject !== project {
            activeProject = project
            project.editorViewModel.refreshProjectId()
            recordProjectActive(project)
            installSession(for: project)
        }
        editorPresentation = .active
        project.editorViewModel.isPointerInputEnabled = true
        editorSession?.setInputEnabled(true)
        WorkbenchStore.shared.route = .videoEditor
        HomeWindowController.shared.applyEditorMode(true)
        HomeWindowController.shared.showWindow(nil)
    }

    func suspendEditor() {
        guard editorPresentation == .active, let project = activeProject else { return }
        project.editorViewModel.pause()
        project.editorViewModel.onCancelTimelineDrag?()
        project.editorViewModel.isPointerInputEnabled = false
        editorPresentation = .suspended
        editorSession?.setInputEnabled(false)
        HomeWindowController.shared.applyEditorMode(false)
    }

    func resumeEditor() {
        guard let project = activeProject else { return }
        presentEditor(for: project)
    }

    /// Show the workbench without closing a suspended project. Suspends if the editor is active.
    func showHome() {
        if editorPresentation == .active {
            suspendEditor()
        }
        HomeWindowController.shared.showWindow(nil)
    }

    /// Compatibility alias for call sites that previously opened a separate editor window.
    func showEditor(for project: VideoProject) {
        presentEditor(for: project)
    }

    func activateProject(_ project: VideoProject) {
        presentEditor(for: project)
    }

    func handleProjectClosed(_ project: VideoProject) {
        guard activeProject === project else { return }
        teardownSession()
        activeProject = nil
        editorPresentation = .none
        HomeWindowController.shared.applyEditorMode(false)
        HomeWindowController.shared.showWindow(nil)
    }

    // Save and close project. Throws (without closing) if the save fails.
    func closeProject(_ project: VideoProject) async throws {
        if let url = project.fileURL { ProjectRegistry.shared.register(url) }
        try await project.saveBeforeClosing()
        let wasOpen = activeProject === project
        if wasOpen {
            teardownSession()
            activeProject = nil
            editorPresentation = .none
            HomeWindowController.shared.applyEditorMode(false)
        }
        project.close()
        if wasOpen {
            HomeWindowController.shared.showWindow(nil)
        }
    }

    func revealGeneratedAssetFromNotification(assetId: String?, projectURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let project = notificationTargetProject(assetId: assetId, projectURL: projectURL) else {
            if activeProject == nil {
                HomeWindowController.shared.showWindow(nil)
            }
            return
        }

        presentEditor(for: project)

        guard let assetId,
              let asset = project.editorViewModel.mediaAssets.first(where: { $0.id == assetId }) else {
            return
        }

        let editor = project.editorViewModel
        editor.mediaPanelVisible = true
        editor.maximizedPanel = nil
        editor.focusedPanel = .media
        editor.selectMediaAsset(asset)
        editor.mediaPanelRevealAssetId = assetId
    }

    private func notificationTargetProject(assetId: String?, projectURL: URL?) -> VideoProject? {
        if let projectURL {
            return openProjects.first { Self.sameFile($0.fileURL, projectURL) }
        }
        if let assetId {
            return openProjects.first { project in
                project.editorViewModel.mediaAssets.contains { $0.id == assetId }
            }
        }
        return activeProject
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func installSession(for project: VideoProject) {
        if let existing = editorSession, existing.editorViewModel === project.editorViewModel {
            return
        }
        teardownSession()
        let session = EditorSessionController(editorViewModel: project.editorViewModel)
        session.attach(to: HomeWindowController.shared)
        editorSession = session
    }

    private func teardownSession() {
        editorSession?.detach()
        editorSession = nil
    }

    /// Closes the current open project when opening or creating a different one.
    private func closeCurrentProjectIfNeeded(exceptURL: URL? = nil) async throws {
        guard let current = activeProject else { return }
        if let exceptURL, Self.sameFile(current.fileURL, exceptURL) { return }
        try await closeProject(current)
    }

    // MARK: - Project lifecycle

    private func instantiateProject(at url: URL, presentImmediately: Bool = true) -> VideoProject {
        let doc = VideoProject()
        doc.autoPresentEditor = presentImmediately
        doc.fileURL = url
        doc.fileType = VideoProject.typeIdentifier
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        return doc
    }

    /// Creates a new project in the storage folder; errors if the name is invalid or already taken.
    /// - Parameter presentImmediately: When false, prepares the document without activating the editor UI.
    @discardableResult
    func createProject(named name: String, presentImmediately: Bool = true) async throws -> VideoProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? Project.defaultProjectName : trimmed
        guard !base.contains("/"), !base.contains("\\"), base != ".", base != ".." else {
            throw ProjectError.invalidName(base)
        }
        let directory = Project.storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(base).appendingPathExtension(Project.fileExtension)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.nameTaken(url)
        }
        try await closeCurrentProjectIfNeeded()
        let doc = instantiateProject(at: url, presentImmediately: presentImmediately)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            doc.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        ProjectRegistry.shared.register(url)
        doc.editorViewModel.refreshProjectId()
        recordProjectCreated(doc)
        recordProjectOpened(doc)
        return doc
    }

    func createProjectInteractively() {
        Telemetry.beginOperation("save_panel", data: ["flow": "project_create"])
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.nameFieldStringValue = Project.defaultProjectName
        panel.directoryURL = Project.storageDirectory
        panel.title = L10n.string("New Project")
        panel.begin { [self] response in
            Telemetry.endOperation("save_panel")
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await closeCurrentProjectIfNeeded()
                    let doc = instantiateProject(at: url)
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                            if let error { cont.resume(throwing: error) } else { cont.resume() }
                        }
                    }
                    ProjectRegistry.shared.register(url)
                    doc.editorViewModel.refreshProjectId()
                    recordProjectCreated(doc)
                    recordProjectOpened(doc)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    func openProject(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) {
        Task {
            do {
                try await openProjectAsync(at: url, register: register, options: options)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @discardableResult
    func openProjectAsync(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) async throws -> VideoProject {
        try Task.checkCancellation()
        let resolved = url.standardizedFileURL
        guard !projectPathsBeingDeleted.contains(resolved.path) else {
            throw ProjectError.deletionInProgress(resolved)
        }
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }
        projectOpenCounts[resolved.path, default: 0] += 1
        defer {
            if projectOpenCounts[resolved.path] == 1 {
                projectOpenCounts[resolved.path] = nil
            } else {
                projectOpenCounts[resolved.path, default: 1] -= 1
            }
        }
        try await closeCurrentProjectIfNeeded(exceptURL: resolved)
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }
        let doc = try await VideoProject.load(from: resolved)
        try Task.checkCancellation()
        guard !projectPathsBeingDeleted.contains(resolved.path) else {
            throw ProjectError.deletionInProgress(resolved)
        }
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }

        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        if register { ProjectRegistry.shared.register(resolved) }
        doc.editorViewModel.refreshProjectId()
        recordProjectOpened(doc)
        apply(options, to: doc.editorViewModel)
        return doc
    }

    func deleteProjects(withIDs ids: Set<UUID>) async throws -> ProjectDeletionResult {
        let entries = ProjectRegistry.shared.entries.filter { ids.contains($0.id) }
        let openPaths = Set(openProjects.compactMap { $0.fileURL?.standardizedFileURL.path })
        let openEntries = entries.filter { openPaths.contains($0.url.standardizedFileURL.path) }
        guard openEntries.isEmpty else {
            throw ProjectError.openProjects(openEntries.map(\.name))
        }
        let openingEntries = entries.filter { projectOpenCounts[$0.url.standardizedFileURL.path] != nil }
        guard openingEntries.isEmpty else {
            throw ProjectError.projectsOpening(openingEntries.map(\.name))
        }

        let paths = Set(entries.map { $0.url.standardizedFileURL.path })
        if let path = paths.first(where: { projectPathsBeingDeleted.contains($0) }) {
            throw ProjectError.deletionInProgress(URL(fileURLWithPath: path))
        }
        projectPathsBeingDeleted.formUnion(paths)
        defer { projectPathsBeingDeleted.subtract(paths) }
        return await ProjectRegistry.shared.delete(entries)
    }

    private func showExistingProject(at url: URL, register: Bool, options: ProjectOpenOptions) -> VideoProject? {
        if let existing = openProjects.first(where: { Self.sameFile($0.fileURL, url) }) {
            if register { ProjectRegistry.shared.register(url) }
            presentEditor(for: existing)
            apply(options, to: existing.editorViewModel)
            return existing
        }
        return nil
    }

    private func recordProjectCreated(_ project: VideoProject) {
        Analytics.capture(.projectCreated, properties: project.editorViewModel.analyticsSnapshot())
    }

    private func recordProjectOpened(_ project: VideoProject) {
        let properties = project.editorViewModel.analyticsSnapshot()
        Analytics.capture(.projectOpened, properties: properties)
        if let projectId = project.editorViewModel.projectId {
            Analytics.captureProjectActive(projectId: projectId, properties: properties)
        }
    }

    private func recordProjectActive(_ project: VideoProject) {
        guard let projectId = project.editorViewModel.projectId else { return }
        let properties = project.editorViewModel.analyticsSnapshot()
        Analytics.captureProjectActive(projectId: projectId, properties: properties)
    }

    private func apply(_ options: ProjectOpenOptions, to editor: EditorViewModel) {
        if options.startTutorial {
            DispatchQueue.main.async { editor.tour.start(in: editor) }
        }
    }

    func openSample(slug: String, startTutorial: Bool, onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        let options = ProjectOpenOptions(startTutorial: startTutorial)
        if let cached = SampleProjectService.shared.cachedURL(slug: slug) {
            try await openProjectAsync(at: cached, register: false, options: options)
            return
        }
        let url = try await SampleProjectService.shared.materialize(slug: slug, onProgress: onProgress)
        try await openProjectAsync(at: url, register: false, options: options)
    }

    func openProjectFromPanel() {
        Telemetry.beginOperation("open_panel", data: ["flow": "project_open"])
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectContentType, Self.legacyProjectContentType]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L10n.string("Open Project")
        panel.begin { response in
            Telemetry.endOperation("open_panel")
            guard response == .OK, let url = panel.url else { return }
            AppState.shared.openProject(at: url)
        }
    }

    private static let projectContentType: UTType = {
        UTType(Project.typeIdentifier)
            ?? UTType(filenameExtension: Project.fileExtension, conformingTo: .package)
            ?? .package
    }()

    private static let legacyProjectContentType: UTType = {
        UTType(Project.legacyTypeIdentifier)
            ?? UTType(filenameExtension: Project.legacyFileExtension, conformingTo: .package)
            ?? .package
    }()

}
