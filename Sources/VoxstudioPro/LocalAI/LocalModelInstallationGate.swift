import Foundation

actor LocalModelInstallationGate {
    static let shared = LocalModelInstallationGate()

    private var isHeld = false
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    order.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while let id = order.first {
            order.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else { continue }
            continuation.resume()
            return
        }
        isHeld = false
    }
}
