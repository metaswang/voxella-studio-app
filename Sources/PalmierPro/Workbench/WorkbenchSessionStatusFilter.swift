enum WorkbenchSessionStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case ready
    case processing
    case completed
    case needsAttention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All statuses"
        case .ready: "Ready"
        case .processing: "Processing"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        }
    }

    func matches(_ state: WorkbenchJobState) -> Bool {
        switch self {
        case .all: true
        case .ready: state == .ready
        case .processing: state == .running || state == .cancelling
        case .completed: state == .completed
        case .needsAttention: state == .failed || state == .cancelled
        }
    }
}
