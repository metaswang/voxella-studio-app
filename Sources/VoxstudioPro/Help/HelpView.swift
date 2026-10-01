import SwiftUI

enum HelpTab: String, CaseIterable, Identifiable {
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var icon: String {
        "keyboard"
    }
}

struct HelpView: View {
    @State private var selectedTab: HelpTab

    init(initialTab: HelpTab = .shortcuts) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: AppTheme.zoomed(220))

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Background.surfaceColor)
        }
        .frame(
            minWidth: AppTheme.zoomed(820),
            idealWidth: AppTheme.zoomed(900),
            minHeight: AppTheme.zoomed(520),
            idealHeight: AppTheme.zoomed(560)
        )
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(HelpTab.allCases) { tab in
                sidebarRow(for: tab)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(for tab: HelpTab) -> some View {
        let isActive = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                    .frame(width: AppTheme.zoomed(16))
                Text(L10n.string(key: tab.rawValue))
                    .font(.system(size: AppTheme.FontSize.md, weight: isActive ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
            .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string(key: selectedTab.rawValue))
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            switch selectedTab {
            case .shortcuts: ShortcutsPane()
            }
        }
    }
}

@MainActor
final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    private var hosting: NSHostingController<AnyView>?
    private var lastAppliedZoomScale = AppZoomScale.shared.scale
    private var zoomObserver: NSObjectProtocol?

    private init() {
        let initialView = HelpView()
            .appZoomEnvironment()
            .appLocalization()
            .tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(AppTheme.zoomed(NSSize(width: 900, height: 560)))
        window.minSize = AppTheme.zoomed(NSSize(width: 820, height: 520))
        window.title = L10n.string("Help")
        window.setFrameAutosaveName("VoxellaStudioHelp-v1")
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        self.hosting = hosting
        super.init(window: window)
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .voxellaZoomScaleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyZoomScale()
            }
        }
    }

    isolated deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: HelpTab = .shortcuts) {
        hosting?.rootView = AnyView(
            HelpView(initialTab: tab)
                .id(UUID())
                .appZoomEnvironment()
                .appLocalization()
                .tint(AppTheme.Accent.primary)
        )
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyZoomScale() {
        guard let window else { return }
        let currentScale = AppZoomScale.shared.scale
        let previousScale = lastAppliedZoomScale
        guard currentScale != previousScale else { return }
        lastAppliedZoomScale = currentScale

        let current = window.contentRect(forFrameRect: window.frame).size
        let factor = currentScale / previousScale
        window.setContentSizePreservingCenter(NSSize(
            width: current.width * factor,
            height: current.height * factor
        ))
        window.minSize = AppTheme.zoomed(NSSize(width: 820, height: 520))
    }
}

#Preview {
    HelpView()
}
