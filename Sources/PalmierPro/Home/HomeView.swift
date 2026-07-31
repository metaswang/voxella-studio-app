import SwiftUI

struct HomeView: View {
    @AppStorage("voxella.workbench.sidebarExpanded") private var sidebarExpanded = false
    @Bindable private var store = WorkbenchStore.shared

    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar(isExpanded: $sidebarExpanded)
                .frame(
                    width: sidebarExpanded
                        ? AppTheme.Workbench.sidebarExpandedWidth
                        : AppTheme.Workbench.sidebarCollapsedWidth
                )

            Divider()

            VStack(spacing: 0) {
                WorkbenchTopBar(isSidebarExpanded: $sidebarExpanded)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: AppTheme.Window.homeMin.width,
            maxWidth: .infinity,
            minHeight: AppTheme.Window.homeMin.height,
            maxHeight: .infinity
        )
        .background(AppTheme.Background.baseColor)
        .focusEffectDisabled()
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
                // Orphaned session route (e.g. after relaunch) — show Recent list.
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
        HStack(spacing: AppTheme.Spacing.md) {
            Button {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    isSidebarExpanded.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityLabel(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")

            Text(store.route == .session ? (store.selectedSession?.title ?? store.route.title) : store.route.title)
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                .lineLimit(1)

            Text("LOCAL")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                .tracking(1.2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AppTheme.Status.successColor.opacity(0.16), in: Capsule())
                .foregroundStyle(AppTheme.Status.successColor)

            Spacer()

            Button {
                models.presentManager()
            } label: {
                Label(modelSummary, systemImage: "shippingbox")
                    .font(.system(size: AppTheme.FontSize.sm))
            }
            .buttonStyle(.plain)
            .help("Manage local models")

            Circle()
                .fill(offlineReady ? AppTheme.Status.successColor : AppTheme.Status.warningColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(offlineReady ? "Offline ready" : "Local models required")
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
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

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                WorkbenchBrandIcon.image(size: 32)

                if isExpanded {
                    Text("Voxella Studio")
                        .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
            .padding(.vertical, AppTheme.Spacing.md)

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
                    Text("No cloud account · No uploads")
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
        store.route == route || (store.route == .session && route == .recent)
    }

    private func select(_ route: WorkbenchRoute) {
        switch route {
        case .recent:
            store.showRecentSessions()
        case .transcribe:
            // Match web: Transcription nav opens the entry workspace, not a job list.
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
final class HomeWindowController: NSWindowController {
    static let shared = HomeWindowController()

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
