import Testing
@testable import VoxstudioPro

@Suite("Workbench session status filter")
struct WorkbenchSessionStatusFilterTests {
    @Test(arguments: [
        (WorkbenchSessionStatusFilter.notStarted, false, WorkbenchJobState.notStarted, false, true),
        (.queued, false, .queued, false, true),
        (.processing, false, .running, false, true),
        (.processing, true, .cancelling, false, true),
        (.ready, true, .completed, false, true),
        (.needsAttention, true, .failed, false, true),
        (.needsAttention, true, .completed, true, true),
        (.cancelled, false, .cancelled, false, true),
        (.ready, false, .completed, false, false),
    ])
    func matchesGroupedStates(
        filter: WorkbenchSessionStatusFilter,
        hasUsableResult: Bool,
        state: WorkbenchJobState,
        hasAdditionalFailure: Bool,
        expected: Bool
    ) {
        let status = WorkbenchSessionStatus(
            hasUsableResult: hasUsableResult,
            taskState: state,
            hasAdditionalFailure: hasAdditionalFailure
        )
        #expect(filter.matches(status) == expected)
        #expect(WorkbenchSessionStatusFilter.all.matches(status))
    }

    @Test func readyResultCanAlsoMatchProcessingAndAttention() {
        let processing = WorkbenchSessionStatus(
            hasUsableResult: true,
            taskState: .running,
            hasAdditionalFailure: false
        )
        let attention = WorkbenchSessionStatus(
            hasUsableResult: true,
            taskState: .completed,
            hasAdditionalFailure: true
        )

        #expect(WorkbenchSessionStatusFilter.ready.matches(processing))
        #expect(WorkbenchSessionStatusFilter.processing.matches(processing))
        #expect(WorkbenchSessionStatusFilter.ready.matches(attention))
        #expect(WorkbenchSessionStatusFilter.needsAttention.matches(attention))
    }

    @Test func readyResultMatchesProcessingWhileSummaryOrSyncRuns() {
        let status = WorkbenchSessionStatus(
            hasUsableResult: true,
            taskState: .completed,
            hasAdditionalFailure: false,
            hasAdditionalActivity: true
        )

        #expect(WorkbenchSessionStatusFilter.ready.matches(status))
        #expect(WorkbenchSessionStatusFilter.processing.matches(status))
        #expect(status.secondaryLabel == "Processing")
    }
}
