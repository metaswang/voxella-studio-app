import Foundation

@MainActor
final class EditorUndo {
    private weak var manager: UndoManager?
    private var transactionActive = false
    private var transactionGroupOpened = false
    private var stackObservers: [NSObjectProtocol] = []
    var onActionCommitted: (() -> Void)?
    var onStackChanged: (() -> Void)?

    func attach(_ manager: UndoManager?) {
        removeStackObservers()
        self.manager = manager
        guard let manager else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onStackChanged?()
                }
            }
            stackObservers.append(token)
        }
    }

    private func removeStackObservers() {
        let center = NotificationCenter.default
        for token in stackObservers {
            center.removeObserver(token)
        }
        stackObservers.removeAll()
    }

    func perform<T>(_ actionName: String, _ work: () throws -> T) rethrows -> T {
        guard let manager, !manager.isUndoing, !manager.isRedoing else {
            return try work()
        }
        guard !transactionActive else { return try work() }

        let initialGroupingLevel = manager.groupingLevel
        // Prevent Foundation from wrapping an explicit editor transaction in an event group.
        let restoresEventGrouping = manager.groupsByEvent && initialGroupingLevel == 0
        if restoresEventGrouping { manager.groupsByEvent = false }
        transactionActive = true
        transactionGroupOpened = false
        defer {
            let groupOpened = transactionGroupOpened
            transactionActive = false
            transactionGroupOpened = false
            if groupOpened {
                manager.setActionName(actionName)
                manager.endUndoGrouping()
                onActionCommitted?()
            }
            if restoresEventGrouping { manager.groupsByEvent = true }
            assert(manager.groupingLevel == initialGroupingLevel)
        }
        return try work()
    }

    func register<Target: AnyObject>(
        _ actionName: String,
        withTarget target: Target,
        handler: @escaping @MainActor (Target) -> Void
    ) {
        guard let manager, manager.isUndoRegistrationEnabled else { return }
        if !transactionActive, !manager.isUndoing, !manager.isRedoing {
            perform(actionName) { register(actionName, withTarget: target, handler: handler) }
            return
        }
        if transactionActive, !transactionGroupOpened {
            manager.beginUndoGrouping()
            transactionGroupOpened = true
        }
        manager.registerUndo(withTarget: target) { target in handler(target) }
    }

    func withoutRegistration<T>(_ work: () throws -> T) rethrows -> T {
        guard let manager, manager.isUndoRegistrationEnabled else {
            return try work()
        }
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        return try work()
    }

    var isRegistrationEnabled: Bool { manager?.isUndoRegistrationEnabled ?? true }

    /// The UndoManager currently attached; same instance used by withTimelineSwap/commitTrim.
    var attachedUndoManager: UndoManager? { manager }

    var canUndo: Bool { manager?.canUndo ?? false }
    var canRedo: Bool { manager?.canRedo ?? false }
    var undoActionName: String { manager?.undoActionName ?? "" }
    var redoActionName: String { manager?.redoActionName ?? "" }

    func undoLatest() -> String? {
        guard let manager, manager.canUndo else { return nil }
        let actionName = manager.undoActionName
        manager.undo()
        return actionName
    }

    func redoLatest() -> String? {
        guard let manager, manager.canRedo else { return nil }
        let actionName = manager.redoActionName
        manager.redo()
        return actionName
    }

    func removeAllActions<Target: AnyObject>(withTarget target: Target) {
        manager?.removeAllActions(withTarget: target)
    }
}
