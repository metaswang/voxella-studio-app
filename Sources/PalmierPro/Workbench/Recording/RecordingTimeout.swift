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
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = RecordingOnceGate<T>()
            gate.arm(continuation)
            let work = Task<Void, Never> {
                do {
                    let value = try await operation()
                    gate.resume(returning: value)
                } catch {
                    gate.resume(throwing: error)
                }
            }
            Task<Void, Never> {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.resume(throwing: RecordingError.captureFailed("Recording timed out.")) {
                    work.cancel()
                }
            }
        }
    }
}
