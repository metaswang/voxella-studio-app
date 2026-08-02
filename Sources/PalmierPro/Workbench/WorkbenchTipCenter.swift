import Foundation
import Observation

enum WorkbenchTipKind: Equatable, Sendable {
    case success
    case error
    case info
}

enum WorkbenchTipAction: Equatable, Sendable {
    case openAISettings
}

struct WorkbenchTip: Equatable, Identifiable, Sendable {
    let id: String
    let message: String
    let kind: WorkbenchTipKind
    let actionLabel: String?
    let action: WorkbenchTipAction?

    init(
        id: String? = nil,
        message: String,
        kind: WorkbenchTipKind = .info,
        actionLabel: String? = nil,
        action: WorkbenchTipAction? = nil
    ) {
        self.id = id ?? "\(kind):\(message)"
        self.message = message
        self.kind = kind
        self.actionLabel = actionLabel
        self.action = action
    }
}

@Observable
@MainActor
final class WorkbenchTipCenter {
    static let shared = WorkbenchTipCenter()

    private(set) var tip: WorkbenchTip?
    private var hideTask: Task<Void, Never>?
    private var recentShownAt: [String: ContinuousClock.Instant] = [:]

    private init() {}

    func show(
        _ message: String,
        kind: WorkbenchTipKind = .info,
        id: String? = nil,
        actionLabel: String? = nil,
        action: WorkbenchTipAction? = nil
    ) {
        show(
            WorkbenchTip(
                id: id,
                message: message,
                kind: kind,
                actionLabel: actionLabel,
                action: action
            )
        )
    }

    func show(_ tip: WorkbenchTip) {
        let now = ContinuousClock.now
        if let last = recentShownAt[tip.id],
           now - last < AppTheme.Workbench.tipDedupeWindow {
            return
        }
        recentShownAt[tip.id] = now
        pruneRecent(now: now)

        hideTask?.cancel()
        self.tip = tip
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: AppTheme.Workbench.tipAutoDismiss)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        tip = nil
    }

    func performAction() {
        guard let tip else { return }
        switch tip.action {
        case .openAISettings:
            SettingsWindowController.shared.show(tab: .ai)
        case .none:
            break
        }
        hide()
    }

    private func pruneRecent(now: ContinuousClock.Instant) {
        recentShownAt = recentShownAt.filter { _, shownAt in
            now - shownAt < AppTheme.Workbench.tipDedupeWindow
        }
    }
}
