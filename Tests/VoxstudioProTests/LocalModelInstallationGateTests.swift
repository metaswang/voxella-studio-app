import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Local model installation gate")
struct LocalModelInstallationGateTests {
    actor Probe {
        private var active = 0
        private(set) var maximumActive = 0
        private var releases: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            active += 1
            maximumActive = max(maximumActive, active)
            await withCheckedContinuation { releases.append($0) }
            active -= 1
        }

        func releaseNext() {
            releases.removeFirst().resume()
        }

        func releaseCount() -> Int { releases.count }
    }

    @Test("serializes callers")
    func serializesCallers() async throws {
        let gate = LocalModelInstallationGate()
        let probe = Probe()
        let first = Task { try await gate.withPermit { await probe.enter() } }
        while await probe.releaseCount() == 0 { await Task.yield() }
        let second = Task { try await gate.withPermit { await probe.enter() } }

        await probe.releaseNext()
        while await probe.releaseCount() == 0 { await Task.yield() }
        await probe.releaseNext()
        try await first.value
        try await second.value

        #expect(await probe.maximumActive == 1)
    }

    @Test("cancels a queued caller without cancelling the active operation")
    func cancelsQueuedCaller() async throws {
        let gate = LocalModelInstallationGate()
        let probe = Probe()
        let first = Task { try await gate.withPermit { await probe.enter() } }
        while await probe.releaseCount() == 0 { await Task.yield() }
        let queued = Task { try await gate.withPermit {} }
        queued.cancel()

        await probe.releaseNext()
        try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
    }
}
