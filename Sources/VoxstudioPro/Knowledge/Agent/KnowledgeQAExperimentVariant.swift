import Foundation

/// Development-only ablation controls. Production uses the complete workspace;
/// workers remain optional decisions, never a mandatory extra model pass.
enum KnowledgeQAExperimentVariant: String, Sendable {
    case native = "B1", adaptive = "B2", coverage = "B3", workers = "B4"

    static var current: Self {
        #if DEBUG
        Self(rawValue: ProcessInfo.processInfo.environment["VOXELLA_KB_QA_VARIANT"] ?? "B4") ?? .workers
        #else
        .workers
        #endif
    }

    func includes(_ name: String) -> Bool {
        if name == "analysis.update" || name == "session.aggregate" { return self == .coverage || self == .workers }
        if name == "knowledge.search_sources" || name == "session.get_speakers" { return self != .native }
        return true
    }
}
