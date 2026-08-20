import Testing
@testable import PalmierPro

@Suite("Workbench session status filter")
struct WorkbenchSessionStatusFilterTests {
    @Test(arguments: [
        (WorkbenchSessionStatusFilter.ready, WorkbenchJobState.ready, true),
        (.processing, .running, true),
        (.processing, .cancelling, true),
        (.completed, .completed, true),
        (.needsAttention, .failed, true),
        (.needsAttention, .cancelled, true),
        (.ready, .completed, false),
    ])
    func matchesGroupedStates(
        filter: WorkbenchSessionStatusFilter,
        state: WorkbenchJobState,
        expected: Bool
    ) {
        #expect(filter.matches(state) == expected)
        #expect(WorkbenchSessionStatusFilter.all.matches(state))
    }
}
