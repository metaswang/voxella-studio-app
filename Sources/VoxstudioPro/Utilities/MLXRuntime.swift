import Foundation
import os

#if BUNDLED_SPEECH
import MLX
#endif

// Skip MLX model loads in unbundled builds to avoid a fatal mlx.metallib error.
enum MLXRuntime {
    /// Ordinary SwiftPM unit tests must never touch MLX because their test bundle does
    /// not carry the Metal runtime. Release qualification explicitly opts in after the
    /// built `mlx.metallib` has been colocated with the test executable.
    static let isAvailable = Bundle.main.bundleURL.pathExtension == "app"
        || ProcessInfo.processInfo.environment["VOXELLA_RUN_LOCAL_FIXTURES"] == "1"
    private static let gate = MLXOperationGate()

    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? {
            "On-device processing is unavailable in this app build."
        }
    }

    static func requireAvailable() throws {
        guard isAvailable else { throw Unavailable() }
    }

    static func beginOperation() throws {
        try requireAvailable()
        guard gate.begin() else { throw CancellationError() }
    }
    static func endOperation() { gate.end() }

    /// Recycled activation buffers. Weights stay active; this cap stops the
    /// Metal pool from growing to the device working-set limit.
    static let activationCacheLimit = 512 * 1024 * 1024

    private static let inferenceGate = AsyncSemaphore(value: 1)
    private static let memoryState = OSAllocatedUnfairLock(initialState: MemoryBudgetState())

    private struct MemoryBudgetState {
        var didConfigureCacheLimit = false
        var didTouchRuntime = false
    }

    static func configureMemoryBudget() {
        #if BUNDLED_SPEECH
        guard isAvailable else { return }
        let shouldLog = memoryState.withLock { state -> Bool in
            guard !state.didConfigureCacheLimit else { return false }
            state.didConfigureCacheLimit = true
            return true
        }
        guard shouldLog else { return }
        Memory.cacheLimit = activationCacheLimit
        Log.app.notice("MLX cache limit set to \(activationCacheLimit / (1024 * 1024))MB")
        #endif
    }

    /// Returns cached Metal buffers to the system. Active weights are kept.
    /// Skipped until a real inference has started, because clearing the cache
    /// before the Metal device exists crashes headless launches.
    static func releaseActivations() {
        #if BUNDLED_SPEECH
        guard isAvailable else { return }
        guard memoryState.withLock({ $0.didTouchRuntime }) else { return }
        Memory.clearCache()
        #endif
    }

    static func beginInference() async throws {
        try beginOperation()
        configureMemoryBudget()
        let waitStartedAt = DispatchTime.now().uptimeNanoseconds
        do { try await inferenceGate.wait() } catch {
            endOperation()
            throw error
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - waitStartedAt) / 1_000_000_000
        if waited >= 0.05 {
            Log.app.notice("MLX inference gate waited \(String(format: "%.2f", waited))s")
        }
        memoryState.withLock { $0.didTouchRuntime = true }
        logMemory("inference-begin")
    }
    static func endInference() {
        logMemory("inference-end")
        Task { await inferenceGate.signal() }
        endOperation()
    }

    static func logMemory(_ event: String) {
        #if BUNDLED_SPEECH
        guard isAvailable else { return }
        guard memoryState.withLock({ $0.didTouchRuntime || $0.didConfigureCacheLimit }) else { return }
        let snapshot = Memory.snapshot()
        let mb = 1024 * 1024
        Log.app.notice(
            "MLX memory \(event) activeMB=\(snapshot.activeMemory / mb) cacheMB=\(snapshot.cacheMemory / mb) peakMB=\(snapshot.peakMemory / mb)"
        )
        #endif
    }
    static var shouldStop: Bool { gate.shouldStop }
    static func beginTermination() -> Bool { gate.stop() }
    static func waitUntilIdle() async { await gate.waitUntilIdle() }
}

final class MLXOperationGate: @unchecked Sendable {
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private let operations = DispatchGroup()
    func begin() -> Bool {
        stopping.withLock { stopping in
            guard !stopping else { return false }
            operations.enter()
            return true
        }
    }
    func end() { operations.leave() }
    var shouldStop: Bool { stopping.withLock { $0 } }
    func stop() -> Bool {
        stopping.withLock { $0 = true }
        return operations.wait(timeout: .now()) == .success
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            operations.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }
}
