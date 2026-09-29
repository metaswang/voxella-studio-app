import AppKit
import Observation
import SwiftUI

/// One workspace the user can return to with Back / Forward.
enum WorkbenchScreen: Equatable {
    case editor
    case session(UUID)
    case transcribe(UUID?)
    case dub(UUID)
    case place(WorkbenchRoute)

    static func capture(
        editorActive: Bool,
        route: WorkbenchRoute,
        sessionID: UUID?,
        transcriptionID: UUID?,
        dubID: UUID?
    ) -> WorkbenchScreen? {
        if editorActive { return .editor }
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
    private var isApplying = false
    private var commitScheduled = false
    private var mouseMonitor: Any?
    private let historyLimit = 50

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

    func installMouseNavigationIfNeeded() {
        guard mouseMonitor == nil else { return }
        let windowNumber = HomeWindowController.shared.window?.windowNumber
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard let windowNumber, event.window?.windowNumber == windowNumber else { return event }
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
        guard current != nil else { return }
        let target = back ? backStack.popLast() : forwardStack.popLast()
        guard let target else {
            refreshFlags()
            return
        }
        isApplying = true
        guard let landed = apply(target), let origin = current, landed != origin else {
            isApplying = false
            refreshFlags()
            return
        }
        if back {
            push(origin, onto: &forwardStack)
        } else {
            push(origin, onto: &backStack)
        }
        current = landed
        pending = landed
        refreshFlags()
        scheduleCommit()
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
            isApplying = false
            refreshFlags()
            return
        }
        if isApplying {
            current = screen
            isApplying = false
            refreshFlags()
            return
        }
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

    private func apply(_ screen: WorkbenchScreen) -> WorkbenchScreen? {
        let store = WorkbenchStore.shared
        let appState = AppState.shared
        switch screen {
        case .editor:
            guard appState.activeProject != nil else { return nil }
            if appState.editorPresentation != .active {
                appState.resumeEditor()
            }
            return .editor
        case .session(let id):
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            guard store.selectSessionForHistory(id) else { return nil }
            return .session(id)
        case .transcribe(let id):
            if appState.editorPresentation == .active {
                appState.suspendEditor()
            }
            store.selectedTranscriptionID = id
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
