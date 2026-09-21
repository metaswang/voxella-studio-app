import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case account
    case calendar
    case general
    case models
    case voiceLibrary
    case ai
    case agent
    case skills
    case storage

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .account: return L10n.string("Account")
        case .calendar: return L10n.string("Calendar")
        case .general: return L10n.string("General")
        case .voiceLibrary: return L10n.string("Voice Library")
        case .models: return L10n.string("Local Features")
        case .ai: return L10n.string("AI Service")
        case .agent: return L10n.string("MCP")
        case .skills: return L10n.string("Skills")
        case .storage: return L10n.string("Storage")
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.circle"
        case .calendar: return "calendar"
        case .general: return "gearshape"
        case .voiceLibrary: return "waveform.badge.magnifyingglass"
        case .models: return "square.stack.3d.up"
        case .ai: return "sparkles"
        case .agent: return "network"
        case .skills: return "book.closed"
        case .storage: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @State private var providerConnectionStates: [UUID: ProviderConnectionState] = [:]

    init(initialTab: SettingsTab = .account) {
        _selectedTab = State(initialValue: initialTab)
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab, visibleTabs: visibleTabs)
                .frame(width: AppTheme.Settings.sidebarWidth)

            SettingsDetail(
                tab: selectedTab,
                providerConnectionStates: $providerConnectionStates
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Background.surfaceColor)
        }
        .frame(
            minWidth: AppTheme.Window.settingsMin.width,
            maxWidth: .infinity,
            minHeight: AppTheme.Window.settingsMin.height,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .onAppear {
            if !visibleTabs.contains(selectedTab) {
                selectedTab = visibleTabs.first ?? .general
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let visibleTabs: [SettingsTab]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IdentityStrip()
            tabList
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(visibleTabs) { tab in
                SidebarRowButton(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

private struct SettingsDetail: View {
    let tab: SettingsTab
    @Binding var providerConnectionStates: [UUID: ProviderConnectionState]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tab != .models && tab != .voiceLibrary {
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .frame(
                        maxWidth: AppTheme.Settings.contentMaxWidth,
                        alignment: .leading
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppTheme.Spacing.xxl)
                    .padding(.top, AppTheme.Spacing.xxl)
                    .padding(.bottom, AppTheme.Spacing.xxl)
            }

            Group {
                if tab == .voiceLibrary {
                    VoiceLibraryView()
                } else if tab == .skills {
                    SkillsPane()
                } else if tab == .models {
                    // Owns title + scroll so the heading shares one left edge with content.
                    ModelsPane()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                            switch tab {
                            case .account:
                                AccountPane()
                            case .calendar:
                                GoogleCalendarSettingsPane()
                            case .general:
                                AppearanceSettingsPane()
                                LanguageSettingsPane()
#if !MAC_APP_STORE
                                SettingsSection(title: "Updates") {
                                    UpdatesPane(updater: AppUpdater.shared)
                                }
#endif
                                SettingsSection(title: "Recording") {
                                    RecordingPane()
                                }
                                SettingsSection(title: "Voice Input") {
                                    VoiceInputSettingsPane()
                                }
                                SettingsSection(title: "Notifications") {
                                    NotificationsPane()
                                }
                                SettingsSection(title: "Privacy & Diagnostics") {
                                    PrivacyPane()
                                }
                            case .models, .voiceLibrary:
                                EmptyView()
                            case .ai:
                                AISettingsPane(connectionStates: $providerConnectionStates)
                            case .agent:
                                AgentPane()
                            case .skills:
                                EmptyView()
                            case .storage:
                                StoragePane()
                            }
                        }
                        .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.xxl)
                        .padding(.bottom, AppTheme.Spacing.xxl)
                    }
                    .appScrollEdgeEffect(.top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string(title))
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.vertical, AppTheme.Spacing.mdLg)
            .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string(title))
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
            content()
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string(title))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string(subtitle))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(L10n.string(title))
                .accessibilityHint(L10n.string(subtitle))
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var hosting: NSHostingController<AnyView>?
    private var escapeMonitor: Any?
    private var lastAppliedZoomScale = AppZoomScale.shared.scale
    private var zoomObserver: NSObjectProtocol?

    private init() {
        let initialView = SettingsView()
            .appZoomEnvironment()
            .appLocalization()
            .tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        hosting.sizingOptions = .minSize
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(AppTheme.Window.settingsDefault)
        window.minSize = AppTheme.Window.settingsMin
        window.title = L10n.string("Settings")
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        self.hosting = hosting
        super.init(window: window)
        window.delegate = self
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
        removeEscapeMonitor()
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            hosting?.rootView = AnyView(
                SettingsView(initialTab: tab)
                    .id(UUID())
                    .appZoomEnvironment()
                    .appLocalization()
                    .tint(AppTheme.Accent.primary)
            )
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEscapeMonitor()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window else { return event }
            self.window?.performClose(nil)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeEscapeMonitor()
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
        window.minSize = AppTheme.Window.settingsMin
    }
}

#Preview {
    SettingsView()
}
