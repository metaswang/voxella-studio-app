import SwiftUI

struct HomeView: View {
    @AppStorage("voxella.workbench.sidebarExpanded") private var sidebarExpanded = true
    @State private var sessionSearch = SessionSearchController()
    @State private var isSessionSearchPresented = false
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var tips = WorkbenchTipCenter.shared
    @Bindable private var appState = AppState.shared
    @Bindable private var account = AccountService.shared

    private var isEditorActive: Bool { appState.editorPresentation == .active }

    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar(
                isExpanded: isEditorActive ? .constant(false) : $sidebarExpanded,
                onOpenSearch: presentSessionSearch
            )
            .frame(
                width: isEditorActive || !sidebarExpanded
                    ? AppTheme.Workbench.sidebarCollapsedWidth
                    : AppTheme.Workbench.sidebarExpandedWidth
            )
            Divider()

            VStack(spacing: 0) {
                if isEditorActive, let editor = appState.activeProject?.editorViewModel {
                    EditorChrome()
                        .environment(editor)
                } else {
                    WorkbenchTopBar(isSidebarExpanded: $sidebarExpanded)
                }
                Divider()
                WorkbenchTopTipBanner()
                    .animation(.easeInOut(duration: AppTheme.Anim.transition), value: tips.tip?.id)

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
        .frame(
            minWidth: isEditorActive ? AppTheme.Window.projectMin.width : AppTheme.Window.homeMin.width,
            maxWidth: .infinity,
            minHeight: isEditorActive ? AppTheme.Window.projectMin.height : AppTheme.Window.homeMin.height,
            maxHeight: .infinity
        )
        .background(AppTheme.Background.baseColor)
        .ignoresSafeArea(.container, edges: .top)
        .focusEffectDisabled()
        .sheet(isPresented: $isSessionSearchPresented) {
            SessionSearchPalette(controller: sessionSearch)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voxellaPresentSessionSearch)) { _ in
            presentSessionSearch()
        }
        .task(id: trialNoticeIdentity) {
            await presentTrialNoticesWhenEligible()
        }
        .onChange(of: appState.editorPresentation) { _, presentation in
            HomeWindowController.shared.applyEditorMode(presentation == .active)
        }
    }

    private func presentSessionSearch() {
        sessionSearch.reset()
        isSessionSearchPresented = true
    }

    private var trialNoticeIdentity: String? {
        guard let presentation = account.trialPresentation else { return nil }
        switch presentation {
        case let .active(trial):
            return "active.\(Int64(trial.endsAt.timeIntervalSince1970))"
        case .expired:
            return "expired"
        case .verificationRequired:
            return "verify"
        }
    }

    private var trialReminderWakeDate: Date? {
        guard case let .active(trial)? = account.trialPresentation else { return nil }
        return trial.endsAt.addingTimeInterval(-(72 * 60 * 60))
    }

    private func presentTrialNoticesWhenEligible() async {
        guard !Task.isCancelled, !isEditorActive else { return }

        if let trial = await AccountService.shared.consumeTrialStartedPresentation() {
            await waitForExistingTipToClear()
            guard !Task.isCancelled, !isEditorActive, tips.tip == nil else { return }
            tips.show(
                WorkbenchTip(
                    id: "trial-started.\(Int64(trial.endsAt.timeIntervalSince1970))",
                    message: "Your 14-day trial has started. \(trial.sidebarLabel).",
                    kind: .info,
                    actionLabel: trialPurchaseActionLabel,
                    action: .openAppAccess,
                    autoDismiss: false
                )
            )
            return
        }

        if let wakeDate = trialReminderWakeDate, wakeDate > .now {
            do { try await Task.sleep(for: .seconds(wakeDate.timeIntervalSinceNow)) }
            catch { return }
        }
        guard !Task.isCancelled, !isEditorActive else { return }

        await waitForExistingTipToClear()
        guard !Task.isCancelled, !isEditorActive, tips.tip == nil,
              let trial = await AccountService.shared.consumeTrialReminderPresentation()
        else { return }

        tips.show(
            WorkbenchTip(
                id: "trial-reminder.\(Int64(trial.endsAt.timeIntervalSince1970))",
                message: "Your trial ends in \(trial.sidebarLabel). Existing projects remain available.",
                kind: .warning,
                actionLabel: trialPurchaseActionLabel,
                action: .openAppAccess,
                autoDismiss: false
            )
        )
    }

    private var trialPurchaseActionLabel: String {
#if MAC_APP_STORE
        "Buy Lifetime"
#else
        "View plans"
#endif
    }

    private func waitForExistingTipToClear() async {
        guard tips.tip != nil else { return }
        do { try await Task.sleep(for: AppTheme.Workbench.tipAutoDismiss) }
        catch { return }
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
            .sheet(item: Bindable(editor).pendingEditorTranslationRequest) { request in
                EditorTranslationSheet(request: request)
                    .environment(editor)
            }
            .sheet(item: Bindable(editor).pendingEditorDubRequest) { request in
                EditorDubSheet(request: request)
                    .environment(editor)
            }
            .overlay {
                TourOverlay()
                    .environment(editor)
            }
            .tint(AppTheme.Accent.primary)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch store.route {
            case .recent:
                RecentSessionsView()
            case .dashboard:
                WorkbenchLibraryView()
            case .transcribe:
                TranscribeWorkbenchView()
            case .meetBot:
                MeetBotView()
            case .dub:
                DubWorkbenchView()
            case .voiceLibrary:
                RecentSessionsView()
                    .onAppear {
                        store.showRecentSessions()
                        SettingsWindowController.shared.show(tab: .voiceLibrary)
                    }
            case .videoEditor:
                VideoEditorHomeView()
            case .session:
                if store.selectedSession != nil {
                    WorkbenchSessionDetailView()
                } else {
                    RecentSessionsView()
                        .onAppear { store.showRecentSessions() }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ExternalOpenHandler.open(providers)
        }
    }
}

private struct WorkbenchTopBar: View {
    @Binding var isSidebarExpanded: Bool
    @Bindable private var store = WorkbenchStore.shared

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
            .help(L10n.string(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar"))
            .accessibilityLabel(L10n.string(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar"))

            if store.route != .session {
                Text(L10n.string(store.route.title))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }
}

private struct WorkbenchSidebar: View {
    @Binding var isExpanded: Bool
    let onOpenSearch: () -> Void
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var appState = AppState.shared
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                WorkbenchBrandIcon.image(size: AppTheme.IconSize.smMd)

                if isExpanded {
                    Text(AppIdentity.productName)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: AppTheme.Workbench.toolbarHeight)
            .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
            .padding(.top, AppTheme.Workbench.windowControlsInset)

            Button(action: onOpenSearch) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
                    if isExpanded {
                        Text(L10n.string("Search")).font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
                .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sidebarRowHeight, alignment: isExpanded ? .leading : .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Search tasks (⌘K)"))
            .accessibilityLabel(L10n.string("Search tasks"))

            ForEach(WorkbenchRoute.sidebarRoutes) { route in
                Button {
                    select(route)
                } label: {
                    HStack(spacing: AppTheme.Spacing.md) {
                        route.navGlyph.view(size: 18)
                            .frame(width: 24, height: 24)
                        if isExpanded {
                            Text(L10n.string(route.title))
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
                .help(L10n.string(route.title))
                .accessibilityLabel(L10n.string(route.title))
            }

            Spacer()

            TrialSidebarStatus(isExpanded: isExpanded)

            if case .active(_)? = account.trialPresentation {
                Divider().overlay(AppTheme.Border.subtleColor)
            }

            Button {
                SettingsWindowController.shared.show()
            } label: {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    if isExpanded {
                        Text(L10n.string("Settings"))
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
            .help(L10n.string("Settings"))

            Spacer().frame(height: AppTheme.Spacing.sm)
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
            store.startNewDubDraft()
        default:
            store.route = route
        }
    }
}

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HomeWindowController()

    private var isEditorMode = false
    private var hasAppliedInitialWindowState = false

    private init() {
        let hostingController = NSHostingController(rootView: FirstRunRootView().appLocalization().tint(AppTheme.Accent.primary))
        hostingController.sizingOptions = .minSize
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(OnboardingState.shared.isComplete ? AppTheme.Window.homeDefault : AppTheme.Onboarding.windowSize)
        window.minSize = NSSize(width: 960, height: 640)
        window.title = " "
        window.backgroundColor = AppTheme.Background.base
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.fullScreenNone]
        window.center()
        super.init(window: window)
        window.delegate = self
        hideNativeTitlebarTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasAppliedInitialWindowState, let window else { return }
        hasAppliedInitialWindowState = true
        if OnboardingState.shared.isComplete, !window.isZoomed, !window.styleMask.contains(.fullScreen) {
            window.zoom(nil)
        }
    }

    func presentSessionSearch() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .voxellaPresentSessionSearch, object: nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hideNativeTitlebarTitle()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard OnboardingState.shared.isComplete else { return true }
        guard isEditorMode || WorkbenchStore.shared.route != .dashboard else { return true }
        AppState.shared.showDashboard()
        return false
    }

    private func hideNativeTitlebarTitle() {
        guard let window else { return }
        window.title = " "
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }

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

extension Notification.Name {
    static let voxellaPresentSessionSearch = Notification.Name("Voxella.presentSessionSearch")
}
