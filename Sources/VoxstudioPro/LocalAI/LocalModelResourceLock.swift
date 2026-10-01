import Foundation

actor LocalModelResourceLock {
    static let shared = LocalModelResourceLock()

    private var held: Set<String> = []
    private var order: [String: [UUID]] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func withLock<Value: Sendable>(
        for key: String,
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        guard !held.contains(key) else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        order[key, default: []].append(id)
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id, key: key) }
            }
            return
        }
        held.insert(key)
    }

    private func cancelWaiter(_ id: UUID, key: String) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order[key]?.removeAll { $0 == id }
        if order[key]?.isEmpty == true { order[key] = nil }
        continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String) {
        if var queued = order[key], !queued.isEmpty {
            let id = queued.removeFirst()
            order[key] = queued.isEmpty ? nil : queued
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        held.remove(key)
    }
}
