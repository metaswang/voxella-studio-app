import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var isTerminating = false
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []
    private var searchEmbeddingPrewarmTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = AppAppearancePreferences.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        AppUpdater.shared.start()
        _ = RecordingSessionController.shared
        VoiceInputShortcutService.shared.start()

        HomeWindowController.shared.showWindow(nil)
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }
        AppState.shared.startMCPService()
        didFinishLaunching = true
        let queued = pendingOpenURLs
        pendingOpenURLs = []
        if !queued.isEmpty {
            ExternalOpenHandler.open(queued)
        }

        // Pre-warm NSOpenPanel to avoid main thread blocking during cold start.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.isTerminating else { return }
            _ = NSOpenPanel()
        }

        searchEmbeddingPrewarmTask = Task(priority: .utility) { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                guard let self, !self.isTerminating else { return }
                await SessionIndexCoordinator.shared.prewarmEmbeddings()
            } catch is CancellationError {
            } catch {
                Log.search.warning("search embedding prewarm scheduling failed error=\(error.localizedDescription)")
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            ExternalOpenHandler.open(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    @objc func transcribeMediaFromService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = ExternalOpenPasteboard.fileURLs(from: pasteboard)
        Task { @MainActor in
            ExternalOpenHandler.open(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showDashboard()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        searchEmbeddingPrewarmTask?.cancel()
        VoiceInputShortcutService.shared.stop()
        VoiceInputCoordinator.shared.shutdown()
        let projects = AppState.shared.openProjects

        Task { @MainActor in
            do {
                await RecordingSessionController.shared.prepareForTermination()
                for project in projects {
                    try await project.saveBeforeClosing()
                }
                if !MLXRuntime.beginTermination() {
                    await MLXRuntime.waitUntilIdle()
                }
                AppState.shared.stopMCPService()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                projects.forEach { $0.editorViewModel.projectPackageCoordinator.cancelClosing() }
                isTerminating = false
                sender.presentError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createProjectInteractively()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func zoomIn(_ sender: Any?) {
        AppZoomScale.shared.increase()
    }

    @MainActor
    @objc func zoomOut(_ sender: Any?) {
        AppZoomScale.shared.decrease()
    }

    @MainActor
    @objc func resetZoom(_ sender: Any?) {
        AppZoomScale.shared.reset()
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)):
            return !AppZoomScale.shared.isAtMaximum
        case #selector(zoomOut(_:)):
            return !AppZoomScale.shared.isAtMinimum
        case #selector(resetZoom(_:)):
            return !AppZoomScale.shared.isDefault
        default:
            return true
        }
    }

    @MainActor
    @objc func showSessionSearch(_ sender: Any?) {
        HomeWindowController.shared.presentSessionSearch()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showLocalModels(_ sender: Any?) {
        LocalModelManager.shared.presentManager()
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackWindowController.shared.show()
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard AppState.shared.activeProject?.editorViewModel != nil else { return }
        AppState.shared.resumeEditor()
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
