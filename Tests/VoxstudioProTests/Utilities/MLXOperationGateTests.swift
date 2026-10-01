import Testing
@testable import VoxstudioPro

@Test func mlxGateRejectsNewWorkAndDrainsActiveWork() async {
    let gate = MLXOperationGate()
    #expect(gate.begin())
    #expect(!gate.stop())
    #expect(!gate.begin())
    async let drained: Void = gate.waitUntilIdle()
    gate.end()
    await drained
    #expect(gate.stop())
}
