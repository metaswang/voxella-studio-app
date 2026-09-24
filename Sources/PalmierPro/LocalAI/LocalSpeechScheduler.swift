import Foundation

enum LocalSpeechLane: String, Sendable, Equatable {
    case asr
    case dub
}

private enum LocalSpeechLeaseContext {
    @TaskLocal static var lane: LocalSpeechLane?
}

/// One in-flight local ASR or dub job. Same-lane jobs keep their weights;
/// a lane change drops the previous large model before the next load.
actor LocalSpeechScheduler {
    static let shared = LocalSpeechScheduler()
    static let idleInterval: Duration = .seconds(90)

    private struct SpeechWaiter {
        var id: UUID
        var jobID: UUID
        var lane: LocalSpeechLane
        var continuation: CheckedContinuation<Void, Error>
    }

    private struct YieldWaiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private var activeJobID: UUID?
    private var activeLane: LocalSpeechLane?
    private var hotLane: LocalSpeechLane?
    private var speechWaiters: [SpeechWaiter] = []
    private var yieldWaiters: [YieldWaiter] = []
    private var yielding = 0
    private var idleTask: Task<Void, Never>?
    private var foreignIdleTask: Task<Void, Never>?

    func withLease<T>(
        jobID: UUID = UUID(),
        lane: LocalSpeechLane,
        onQueued: (@Sendable () -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        if LocalSpeechLeaseContext.lane == lane {
            return try await body()
        }
        try await acquire(jobID: jobID, lane: lane, onQueued: onQueued)
        do {
            try Task.checkCancellation()
            let value = try await LocalSpeechLeaseContext.$lane.withValue(
                lane,
                operation: { try await body() },
                isolation: isolation
            )
            await finish(jobID: jobID, lane: lane)
            return value
        } catch {
            await finish(jobID: jobID, lane: lane)
            throw error
        }
    }

    /// Blocks until no ASR or dub job is running or queued, then unloads that
    /// hot model. Pair with ``endForeignInference()`` after the caller finishes.
    func beginForeignInference() async throws {
        try await waitUntilSpeechDrained()
        idleTask?.cancel()
        idleTask = nil
        foreignIdleTask?.cancel()
        foreignIdleTask = nil
        await unloadHotSpeechLane()
    }

    func endForeignInference() async {
        yielding = max(0, yielding - 1)
        await pump()
        armForeignIdle()
    }

    private func acquire(
        jobID: UUID,
        lane: LocalSpeechLane,
        onQueued: (@Sendable () -> Void)?
    ) async throws {
        try Task.checkCancellation()
        if activeJobID == nil && yielding == 0 && speechWaiters.isEmpty {
            await grant(jobID: jobID, lane: lane)
            return
        }
        let waiterID = UUID()
        Log.app.notice(
            "Local speech queued job=\(jobID.uuidString) lane=\(lane.rawValue) waiting=\(speechWaiters.count + 1)"
        )
        onQueued?()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    speechWaiters.append(SpeechWaiter(
                        id: waiterID,
                        jobID: jobID,
                        lane: lane,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelSpeechWaiter(waiterID) }
        }
    }

    private func grant(jobID: UUID, lane: LocalSpeechLane) async {
        idleTask?.cancel()
        idleTask = nil
        foreignIdleTask?.cancel()
        foreignIdleTask = nil
        activeJobID = jobID
        activeLane = lane
        if let hotLane, hotLane != lane {
            Log.app.notice("Local speech lane switch from=\(hotLane.rawValue) to=\(lane.rawValue)")
            await unload(hotLane)
        }
        hotLane = lane
        await suspendForeignModels()
        Log.app.notice("Local speech lease granted job=\(jobID.uuidString) lane=\(lane.rawValue)")
    }

    private func finish(jobID: UUID, lane: LocalSpeechLane) async {
        guard activeJobID == jobID else { return }
        if lane == .asr {
            await LocalSpeechPipeline.shared.releaseSessionModels()
        }
        activeJobID = nil
        activeLane = nil
        Log.app.notice("Local speech lease released job=\(jobID.uuidString) lane=\(lane.rawValue)")
        await pump()
    }

    private func pump() async {
        if activeJobID != nil || yielding > 0 { return }
        if !speechWaiters.isEmpty {
            let next = speechWaiters.removeFirst()
            await grant(jobID: next.jobID, lane: next.lane)
            next.continuation.resume()
            return
        }
        if !yieldWaiters.isEmpty {
            let next = yieldWaiters.removeFirst()
            yielding += 1
            next.continuation.resume()
            return
        }
        armIdle()
    }

    private func waitUntilSpeechDrained() async throws {
        try Task.checkCancellation()
        if activeJobID == nil && speechWaiters.isEmpty && yielding == 0 {
            yielding += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeJobID == nil && speechWaiters.isEmpty && yielding == 0 {
                    yielding += 1
                    continuation.resume()
                } else {
                    yieldWaiters.append(YieldWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelYieldWaiter(waiterID) }
        }
    }

    private func cancelSpeechWaiter(_ id: UUID) {
        guard let index = speechWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = speechWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelYieldWaiter(_ id: UUID) {
        guard let index = yieldWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = yieldWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func armIdle() {
        guard hotLane != nil else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleInterval)
            } catch {
                return
            }
            await self?.idleFired()
        }
    }

    private func idleFired() async {
        guard !Task.isCancelled else { return }
        guard activeJobID == nil, speechWaiters.isEmpty, yielding == 0 else { return }
        guard let hotLane else { return }
        // Reserve the lane while the model actor releases its references. A new
        // lease must not load weights before this asynchronous unload finishes.
        yielding = 1
        self.hotLane = nil
        Log.app.notice("Local speech idle unload lane=\(hotLane.rawValue)")
        await unload(hotLane)
        yielding = 0
        await pump()
    }

    private func armForeignIdle() {
        guard activeJobID == nil, speechWaiters.isEmpty,
              yieldWaiters.isEmpty, yielding == 0 else { return }
        foreignIdleTask?.cancel()
        foreignIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleInterval)
            } catch {
                return
            }
            await self?.foreignIdleFired()
        }
    }

    private func foreignIdleFired() async {
        guard !Task.isCancelled else { return }
        guard activeJobID == nil, speechWaiters.isEmpty,
              yieldWaiters.isEmpty, yielding == 0 else { return }
        // Reserve the inference lane before releasing model references. A new
        // search or speech job waits until both resident models are unloaded.
        yielding = 1
        foreignIdleTask = nil
        Log.app.notice("Local search idle unload")
        await suspendForeignModels()
        MLXRuntime.logMemory("search-idle-unload")
        yielding = 0
        await pump()
    }

    private func unloadHotSpeechLane() async {
        guard let hotLane else { return }
        Log.app.notice("Local speech yield unload lane=\(hotLane.rawValue)")
        await unload(hotLane)
        self.hotLane = nil
    }

    private func unload(_ lane: LocalSpeechLane) async {
        switch lane {
        case .asr:
            await LocalSpeechPipeline.shared.releaseLane()
        case .dub:
            await LocalDubPipeline.shared.releaseLane()
        }
    }

    private func suspendForeignModels() async {
        await WeMMEmbeddingProvider.shared.releaseResidentModel()
        await RerankerService.shared.releaseResidentModel()
    }
}
