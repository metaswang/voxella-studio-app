import Foundation

/// One-shot resume gate. Timeout, cancellation, and the underlying callback may race;
/// exactly one resume reaches the waiting continuation.
final class RecordingOnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var didResume = false

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didResume
    }

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if didResume {
            lock.unlock()
            return
        }
        if let pending {
            didResume = true
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        resume(.success(value))
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        resume(.failure(error))
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        if didResume {
            lock.unlock()
            return false
        }
        if let continuation {
            didResume = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return true
        }
        if pending != nil {
            lock.unlock()
            return false
        }
        pending = result
        lock.unlock()
        return true
    }
}

enum RecordingTimeout {
    /// Hard deadline: the waiter returns when the timer fires even if `operation` never
    /// completes. A late operation result is discarded by the one-shot gate.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: RecordingError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = RecordingOnceGate<T>()
        let tasks = RecordingDeadlineTasks()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.arm(continuation)
                tasks.install(Task<Void, Never> {
                    do {
                        try Task.checkCancellation()
                        guard !gate.isResumed else { return }
                        let value = try await operation()
                        if gate.resume(returning: value) { tasks.cancel() }
                    } catch {
                        if gate.resume(throwing: error) { tasks.cancel() }
                    }
                })
                tasks.install(Task<Void, Never> {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    if gate.resume(throwing: timeoutError) { tasks.cancel() }
                })
            }
        } onCancel: {
            gate.resume(throwing: CancellationError())
            tasks.cancel()
        }
    }
}

/// Handles completion/cancellation before either racing task has been installed.
private final class RecordingDeadlineTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        finished = true
        let pending = tasks
        tasks.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}
