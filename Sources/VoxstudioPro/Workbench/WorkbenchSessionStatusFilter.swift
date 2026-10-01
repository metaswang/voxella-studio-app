enum WorkbenchSessionStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case notStarted
    case queued
    case ready
    case processing
    case needsAttention
    case cancelled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All statuses"
        case .notStarted: "Not started"
        case .queued: "Queued"
        case .ready: "Ready"
        case .processing: "Processing"
        case .needsAttention: "Needs attention"
        case .cancelled: "Cancelled"
        }
    }

    func matches(_ status: WorkbenchSessionStatus) -> Bool {
        switch self {
        case .all: true
        case .notStarted: !status.hasUsableResult && status.displayTaskState == .notStarted
        case .queued: status.showsQueued
        case .ready: status.hasUsableResult
        case .processing: status.showsProcessing
        case .needsAttention: status.needsAttention
        case .cancelled: status.displayTaskState == .cancelled
        }
    }
}
