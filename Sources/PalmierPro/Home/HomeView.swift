import SwiftUI

struct HomeView: View {
    @AppStorage("voxella.workbench.sidebarExpanded") private var sidebarExpanded = false
    @State private var editorSidebarRevealed = false
    @State private var editorSidebarHideTask: Task<Void, Never>?
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var tips = WorkbenchTipCenter.shared
    @Bindable private var appState = AppState.shared

    private var isEditorActive: Bool { appState.editorPresentation == .active }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if !isEditorActive {
                    WorkbenchSidebar(isExpanded: $sidebarExpanded)
                        .frame(
                            width: sidebarExpanded
                                ? AppTheme.Workbench.sidebarExpandedWidth
                                : AppTheme.Workbench.sidebarCollapsedWidth
                        )
                    Divider()
                }

                VStack(spacing: 0) {
                    if isEditorActive, let editor = appState.activeProject?.editorViewModel {
                        EditorChrome()
                            .environment(editor)
                    } else {
                        WorkbenchTopBar(isSidebarExpanded: $sidebarExpanded)
                    }
                    Divider()
                    if !isEditorActive {
                        WorkbenchTopTipBanner()
                            .animation(.easeInOut(duration: AppTheme.Anim.transition), value: tips.tip?.id)
                    }

                    ZStack {
                        if let project = appState.activeProject {
                            embeddedEditor(project)
                                .opacity(isEditorActive ? 1 : 0)
                                .allowsHitTesting(isEditorActive)
                                .accessibilityHidden(!isEditorActive)
                        }
                        if !isEditorActive {
                            content
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isEditorActive {
                editorSidebarOverlay
            }
        }
        .frame(
            minWidth: isEditorActive ? AppTheme.Window.projectMin.width : AppTheme.Window.homeMin.width,
            maxWidth: .infinity,
            minHeight: isEditorActive ? AppTheme.Window.projectMin.height : AppTheme.Window.homeMin.height,
            maxHeight: .infinity
        )
        .background(AppTheme.Background.baseColor)
        .ignoresSafeArea(.container, edges: .top)
        .focusEffectDisabled()
        .onChange(of: appState.editorPresentation) { _, presentation in
            if presentation != .active {
                editorSidebarRevealed = false
                editorSidebarHideTask?.cancel()
                editorSidebarHideTask = nil
            }
            HomeWindowController.shared.applyEditorMode(presentation == .active)
        }
    }

    @ViewBuilder
    private func embeddedEditor(_ project: VideoProject) -> some View {
        let editor = project.editorViewModel
        EditorView()
            .environment(editor)
            .focusEffectDisabled()
            .sheet(isPresented: Bindable(editor).showExportDialog) {
                ExportView()
                    .environment(editor)
            }
            .sheet(item: Bindable(editor).pendingSettingsMismatch) { mismatch in
                ProjectSettingsMismatchView(mismatch: mismatch)
                    .environment(editor)
            }
            .overlay {
                TourOverlay()
                    .environment(editor)
            }
            .tint(AppTheme.Accent.primary)
    }

    private var editorSidebarOverlay: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(width: AppTheme.Workbench.editorSidebarHotZoneWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { revealEditorSidebar() }
                        else { scheduleHideEditorSidebar() }
                    }

                if editorSidebarRevealed {
                    HStack(spacing: 0) {
                        WorkbenchSidebar(isExpanded: .constant(true))
                            .frame(width: AppTheme.Workbench.sidebarExpandedWidth)
                            .background(AppTheme.Background.surfaceColor)
                            .shadow(AppTheme.Shadow.md)
                        Divider()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onHover { hovering in
                        if hovering {
                            editorSidebarHideTask?.cancel()
                            editorSidebarHideTask = nil
                            editorSidebarRevealed = true
                        } else {
                            scheduleHideEditorSidebar()
                        }
                    }
                }
            }
            .frame(
                width: editorSidebarRevealed
                    ? AppTheme.Workbench.sidebarExpandedWidth
                    : AppTheme.Workbench.editorSidebarHotZoneWidth
            )
            .animation(.easeInOut(duration: AppTheme.Anim.transition), value: editorSidebarRevealed)

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
    }

    private func revealEditorSidebar() {
        editorSidebarHideTask?.cancel()
        editorSidebarHideTask = nil
        editorSidebarRevealed = true
    }

    private func scheduleHideEditorSidebar() {
        editorSidebarHideTask?.cancel()
        editorSidebarHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppTheme.Anim.editorSidebarHideDelay))
            guard !Task.isCancelled else { return }
            editorSidebarRevealed = false
            editorSidebarHideTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.route {
        case .recent:
            RecentSessionsView()
        case .dashboard:
            WorkbenchLibraryView()
        case .transcribe:
            TranscribeWorkbenchView()
        case .dub:
            DubWorkbenchView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .videoEditor:
            VideoEditorLauncherView()
        case .session:
            if store.selectedSession != nil {
                WorkbenchSessionDetailView()
            } else {
                RecentSessionsView()
                    .onAppear { store.showRecentSessions() }
            }
        }
    }
}

private struct WorkbenchTopBar: View {
    @Binding var isSidebarExpanded: Bool
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    isSidebarExpanded.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .help(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityLabel(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")

            Text(store.route == .session ? (store.selectedSession?.title ?? store.route.title) : store.route.title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .lineLimit(1)

            Text("LOCAL")
                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.bold))
                .tracking(1.0)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(AppTheme.Status.successColor.opacity(0.16), in: Capsule())
                .foregroundStyle(AppTheme.Status.successColor)

            Spacer(minLength: 0)

            Button {
                models.presentManager()
            } label: {
                Label(modelSummary, systemImage: "shippingbox")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help("Manage local models")

            Circle()
                .fill(offlineReady ? AppTheme.Status.successColor : AppTheme.Status.warningColor)
                .frame(width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm)
                .accessibilityLabel(offlineReady ? "Offline ready" : "Local models required")
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }

    private var modelSummary: String {
        let installed = LocalModelManager.catalog.filter { models.state(for: $0.id).isInstalled }.count
        return "Models \(installed)/\(LocalModelManager.catalog.count)"
    }

    private var offlineReady: Bool {
        LocalModelManager.catalog
            .filter(\.isRecommended)
            .allSatisfy { models.state(for: $0.id).isInstalled }
    }
}

private struct WorkbenchSidebar: View {
    @Binding var isExpanded: Bool
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var appState = AppState.shared

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                WorkbenchBrandIcon.image(size: AppTheme.IconSize.smMd)

                if isExpanded {
                    Text("Voxella Studio")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: AppTheme.Workbench.toolbarHeight)
            .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
            .padding(.top, AppTheme.Workbench.windowControlsInset)

            ForEach(WorkbenchRoute.sidebarRoutes) { route in
                Button {
                    select(route)
                } label: {
                    HStack(spacing: AppTheme.Spacing.md) {
                        route.navGlyph.view(size: 18)
                            .frame(width: 24, height: 24)
                        if isExpanded {
                            Text(route.title)
                                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(isActive(route) ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: AppTheme.Workbench.sidebarRowHeight,
                        alignment: isExpanded ? .leading : .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(isActive(route) ? Color.white.opacity(AppTheme.Opacity.soft) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(route.title)
                .accessibilityLabel(route.title)
            }

            Spacer()

            Button {
                SettingsWindowController.shared.show()
            } label: {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    if isExpanded {
                        Text("Settings")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
                .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sidebarRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Runs on this Mac", systemImage: "apple.logo")
                    Text("No cloud account · Files stay local")
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            } else {
                Image(systemName: "lock.shield")
                    .foregroundStyle(AppTheme.Status.successColor)
                    .help("All processing stays on this Mac")
                    .padding(.bottom, AppTheme.Spacing.md)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.bottom, AppTheme.Spacing.md)
        .background(AppTheme.Background.surfaceColor)
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: isExpanded)
    }

    private func isActive(_ route: WorkbenchRoute) -> Bool {
        if appState.editorPresentation == .active {
            return route == .videoEditor
        }
        return store.route == route || (store.route == .session && route == .recent)
    }

    private func select(_ route: WorkbenchRoute) {
        if route == .videoEditor {
            if appState.activeProject != nil {
                appState.resumeEditor()
                return
            }
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            store.route = .videoEditor
            return
        }

        if appState.editorPresentation == .active {
            appState.suspendEditor()
        }

        switch route {
        case .recent:
            store.showRecentSessions()
        case .transcribe:
            store.selectedTranscriptionID = nil
            store.route = .transcribe
        case .dub:
            store.route = .dub
            store.ensureActiveDubDraft()
        default:
            store.route = route
        }
    }
}

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HomeWindowController()

    private var isEditorMode = false

    private init() {
        let hostingController = NSHostingController(rootView: HomeView().tint(AppTheme.Accent.primary))
        hostingController.sizingOptions = .minSize
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(AppTheme.Window.homeDefault)
        window.minSize = NSSize(width: 960, height: 640)
        window.title = "Voxella Studio"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.fullScreenNone]
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyEditorMode(_ enabled: Bool) {
        guard let window else { return }
        isEditorMode = enabled
        if enabled {
            window.minSize = AppTheme.Window.projectMin
            window.collectionBehavior = [.fullScreenPrimary, .managed]
        } else {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            window.minSize = NSSize(width: 960, height: 640)
            window.collectionBehavior = [.fullScreenNone]
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        AppState.shared.activeProject?.undoManager
    }
}
