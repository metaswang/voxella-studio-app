import Foundation

actor LocalModelDownloadScheduler {
    static let shared = LocalModelDownloadScheduler()

    private let maximumTransfers: Int
    private var activeTransfers = 0
    private var activeByModel: [LocalModelID: Int] = [:]
    private var order: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]

    private struct Waiter {
        let modelID: LocalModelID
        let continuation: CheckedContinuation<Void, Error>
    }

    init(maximumTransfers: Int = LocalModelDownloadLimits.maximumConcurrentTransfers) {
        self.maximumTransfers = max(1, maximumTransfers)
    }

    func withPermit<Value: Sendable>(
        for modelID: LocalModelID,
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(for: modelID)
        defer { release(for: modelID) }
        try Task.checkCancellation()
        return try await operation()
    }

    func activeTransferCount() -> Int { activeTransfers }

    func activeTransferCount(for modelID: LocalModelID) -> Int {
        activeByModel[modelID] ?? 0
    }

    private func acquire(for modelID: LocalModelID) async throws {
        try Task.checkCancellation()
        if canGrant(modelID) {
            grant(modelID)
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    order.append(id)
                    waiters[id] = Waiter(modelID: modelID, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func canGrant(_ modelID: LocalModelID) -> Bool {
        guard activeTransfers < maximumTransfers else { return false }
        let competing = competingModelCount(including: modelID)
        let share = max(1, maximumTransfers / max(competing, 1))
        return (activeByModel[modelID] ?? 0) < share
    }

    private func competingModelCount(including modelID: LocalModelID) -> Int {
        var models = Set(activeByModel.compactMap { $0.value > 0 ? $0.key : nil })
        models.formUnion(waiters.values.map(\.modelID))
        models.insert(modelID)
        return max(models.count, 1)
    }

    private func grant(_ modelID: LocalModelID) {
        activeTransfers += 1
        activeByModel[modelID, default: 0] += 1
    }

    private func release(for modelID: LocalModelID) {
        activeTransfers = max(0, activeTransfers - 1)
        if let count = activeByModel[modelID] {
            if count <= 1 {
                activeByModel[modelID] = nil
            } else {
                activeByModel[modelID] = count - 1
            }
        }
        promoteWaiters()
    }

    private func promoteWaiters() {
        var index = 0
        while index < order.count {
            let id = order[index]
            guard let waiter = waiters[id] else {
                order.remove(at: index)
                continue
            }
            guard canGrant(waiter.modelID) else {
                index += 1
                continue
            }
            order.remove(at: index)
            waiters[id] = nil
            grant(waiter.modelID)
            waiter.continuation.resume()
            return
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.continuation.resume(throwing: CancellationError())
        promoteWaiters()
    }
}
