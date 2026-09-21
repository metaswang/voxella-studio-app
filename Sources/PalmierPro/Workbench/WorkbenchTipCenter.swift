import Foundation
import Observation

enum WorkbenchTipKind: Equatable, Sendable {
    case success
    case warning
    case error
    case info
}

enum WorkbenchTipAction: Equatable, Sendable {
    case openAISettings
    case openAppAccess
    case openLocalFeatures
}

struct WorkbenchTip: Equatable, Identifiable, Sendable {
    let id: String
    let message: String
    let kind: WorkbenchTipKind
    let actionLabel: String?
    let action: WorkbenchTipAction?
    let autoDismiss: Bool

    init(
        id: String? = nil,
        message: String,
        kind: WorkbenchTipKind = .info,
        actionLabel: String? = nil,
        action: WorkbenchTipAction? = nil,
        autoDismiss: Bool = true
    ) {
        self.id = id ?? "\(kind):\(message)"
        self.message = message
        self.kind = kind
        self.actionLabel = actionLabel
        self.action = action
        self.autoDismiss = autoDismiss
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
        action: WorkbenchTipAction? = nil,
        autoDismiss: Bool = true
    ) {
        show(
            WorkbenchTip(
                id: id,
                message: message,
                kind: kind,
                actionLabel: actionLabel,
                action: action,
                autoDismiss: autoDismiss
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
        if tip.autoDismiss {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: AppTheme.Workbench.tipAutoDismiss)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    /// Updates an existing persistent tip without applying the normal
    /// duplicate suppression window. Useful for progress/failure transitions.
    func update(_ tip: WorkbenchTip) {
        hideTask?.cancel()
        hideTask = nil
        self.tip = tip
        if tip.autoDismiss {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: AppTheme.Workbench.tipAutoDismiss)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
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
        case .openAppAccess:
            AppAccessWindow.shared.present()
        case .openLocalFeatures:
            LocalModelManagerWindowController.shared.show()
        case .none:
            break
        }
        hide()
    }

    func hide(id: String) {
        guard tip?.id == id else { return }
        hide()
    }

    private func pruneRecent(now: ContinuousClock.Instant) {
        recentShownAt = recentShownAt.filter { _, shownAt in
            now - shownAt < AppTheme.Workbench.tipDedupeWindow
        }
    }
}
