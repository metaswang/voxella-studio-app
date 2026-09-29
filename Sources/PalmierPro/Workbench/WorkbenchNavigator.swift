import AppKit
import Observation
import SwiftUI

/// One workspace the user can return to with Back / Forward.
enum WorkbenchScreen: Equatable {
    case editor(ObjectIdentifier)
    case session(UUID)
    case transcribe(UUID?)
    case dub(UUID)
    case place(WorkbenchRoute)

    static func capture(
        editorID: ObjectIdentifier?,
        route: WorkbenchRoute,
        sessionID: UUID?,
        transcriptionID: UUID?,
        dubID: UUID?
    ) -> WorkbenchScreen? {
        if let editorID { return .editor(editorID) }
        switch route {
        case .session:
            guard let sessionID else { return nil }
            return .session(sessionID)
        case .transcribe:
            return .transcribe(transcriptionID)
        case .dub:
            guard let dubID else { return nil }
            return .dub(dubID)
        case .voiceLibrary:
            return .place(.recent)
        case .recent, .dashboard, .meetBot, .knowledge, .videoEditor:
            return .place(route)
        }
    }
}

/// Browser-style history for workspace changes: sidebar pages, sessions, dubbing, and the video editor.
@MainActor
@Observable
final class WorkbenchNavigator {
    static let shared = WorkbenchNavigator()

    private(set) var canGoBack = false
    private(set) var canGoForward = false

    private var backStack: [WorkbenchScreen] = []
    private var forwardStack: [WorkbenchScreen] = []
    private var current: WorkbenchScreen?
    private var pending: WorkbenchScreen?
    private var commitScheduled = false
    private var mouseMonitor: Any?
    private let historyLimit = 50
    private let captureScreen: () -> WorkbenchScreen?
    private let applyScreen: (WorkbenchScreen) -> WorkbenchScreen?

    init(
        captureScreen: (() -> WorkbenchScreen?)? = nil,
        applyScreen: ((WorkbenchScreen) -> WorkbenchScreen?)? = nil
    ) {
        self.captureScreen = captureScreen ?? { Self.captureCurrentScreen() }
        self.applyScreen = applyScreen ?? { Self.apply($0) }
    }

    static func captureCurrentScreen() -> WorkbenchScreen? {
        let appState = AppState.shared
        let store = WorkbenchStore.shared
        return WorkbenchScreen.capture(
            editorID: appState.editorPresentation == .active
                ? appState.activeProject.map(ObjectIdentifier.init) : nil,
            route: store.route,
            sessionID: store.selectedSessionID,
            transcriptionID: store.selectedTranscriptionID,
            dubID: store.selectedDubID
        )
    }

    func note(_ screen: WorkbenchScreen?) {
        guard let screen else { return }
        pending = screen
        scheduleCommit()
    }

    func goBack() {
        travel(back: true)
    }

    func goForward() {
        travel(back: false)
    }

    func installMouseNavigationIfNeeded(in window: NSWindow) {
        guard mouseMonitor == nil else { return }
        // The hosting view's task can run while HomeWindowController.shared is still
        // initializing. Register from showWindow() with the completed window instead.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            switch event.buttonNumber {
            case 3:
                Task { @MainActor in WorkbenchNavigator.shared.goBack() }
                return nil
            case 4:
                Task { @MainActor in WorkbenchNavigator.shared.goForward() }
                return nil
            default:
                return event
            }
        }
    }

    private func travel(back: Bool) {
        // SwiftUI may not have delivered the latest onChange yet, and note() commits asynchronously.
        note(captureScreen())
        commit()
        guard let origin = current else { return }
        while let target = back ? backStack.popLast() : forwardStack.popLast() {
            guard target != origin,
                  let landed = applyScreen(target), landed != origin else { continue }
            if back {
                push(origin, onto: &forwardStack)
            } else {
                push(origin, onto: &backStack)
            }
            current = landed
            pending = nil
            break
        }
        refreshFlags()
    }

    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.commit()
        }
    }

    /// Coalesce route and editor updates from the same turn into one history step.
    private func commit() {
        commitScheduled = false
        guard let screen = pending else {
            refreshFlags()
            return
        }
        pending = nil
        guard let current else {
            self.current = screen
            refreshFlags()
            return
        }
        guard current != screen else { return }
        push(current, onto: &backStack)
        forwardStack.removeAll()
        self.current = screen
        refreshFlags()
    }

    private func push(_ screen: WorkbenchScreen, onto stack: inout [WorkbenchScreen]) {
        stack.append(screen)
        if stack.count > historyLimit {
            stack.removeFirst(stack.count - historyLimit)
        }
    }

    private func refreshFlags() {
        let back = !backStack.isEmpty
        let forward = !forwardStack.isEmpty
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
    }

    private static func apply(_ screen: WorkbenchScreen) -> WorkbenchScreen? {
        let store = WorkbenchStore.shared
        let appState = AppState.shared
        switch screen {
        case .editor(let id):
            guard let project = appState.activeProject, ObjectIdentifier(project) == id else { return nil }
            if appState.editorPresentation != .active {
                appState.resumeEditor()
            }
            return .editor(id)
        case .session(let id):
            guard store.selectSessionForHistory(id) else { return nil }
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            return .session(id)
        case .transcribe(let id):
            guard id == nil || store.transcriptions.contains(where: { $0.id == id }) else { return nil }
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            store.selectedTranscriptionID = id
            store.selectedSessionID = nil
            store.route = .transcribe
            return .transcribe(id)
        case .dub(let id):
            guard store.dubs.contains(where: { $0.id == id }) else { return nil }
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            store.selectedDubID = id
            store.selectedSessionID = nil
            store.route = .dub
            return .dub(id)
        case .place(let route):
            guard route != .dub, route != .session else { return nil }
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            switch route {
            case .recent, .voiceLibrary:
                store.showRecentSessions()
                return .place(.recent)
            case .transcribe:
                store.selectedTranscriptionID = nil
                store.route = .transcribe
                return .transcribe(nil)
            case .dub, .session:
                return nil
            case .dashboard, .meetBot, .knowledge, .videoEditor:
                store.selectedSessionID = nil
                store.route = route
                return .place(route)
            }
        }
    }
}

struct WorkbenchHistoryControls: View {
    var body: some View {
        WorkbenchHistoryButtons(navigator: WorkbenchNavigator.shared)
    }
}

private struct WorkbenchHistoryButtons: View {
    @Bindable var navigator: WorkbenchNavigator

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            historyButton(
                systemImage: "chevron.backward",
                help: "Back (⌘[)",
                enabled: navigator.canGoBack,
                action: navigator.goBack
            )
            .keyboardShortcut("[", modifiers: .command)

            historyButton(
                systemImage: "chevron.forward",
                help: "Forward (⌘])",
                enabled: navigator.canGoForward,
                action: navigator.goForward
            )
            .keyboardShortcut("]", modifiers: .command)
        }
    }

    private func historyButton(
        systemImage: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : AppTheme.Opacity.medium)
        .help(L10n.string(help))
        .accessibilityLabel(L10n.string(help))
    }
}
