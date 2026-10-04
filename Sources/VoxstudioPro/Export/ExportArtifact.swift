import Foundation

enum ExportArtifactKind: String, Codable, Sendable {
    case video, timeline, project, unknown

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    static func infer(from url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": .video
        case "xml", "fcpxml": .timeline
        case Project.fileExtension.lowercased(): .project
        default: .unknown
        }
    }

    var symbol: String {
        switch self {
        case .video: "play.rectangle"
        case .timeline: "doc.text"
        case .project: "shippingbox"
        case .unknown: "doc"
        }
    }
}

enum TimelineExportEditor: String, Codable, CaseIterable, Identifiable, Sendable {
    case resolve, fcp, premiere

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .resolve: "DaVinci Resolve"
        case .fcp: "Final Cut Pro"
        case .premiere: "Adobe Premiere Pro"
        }
    }

    var defaultFormat: ExportFormat { self == .premiere ? .xml : .fcpxml }
    var fcpxmlTarget: FCPXMLTarget { self == .fcp ? .fcp : .resolve }
}

/// Describes the committed artifact, not the export dialog's current settings.
/// Optional on ExportJob so histories saved by earlier versions still decode.
struct ExportArtifactDescriptor: Codable, Equatable, Sendable {
    var kind: ExportArtifactKind
    var format: String
    var targetEditor: TimelineExportEditor?
    var durationSeconds: Double?
    var timelineCount: Int?
    var mediaFileCount: Int?
}

enum ExportArtifactAction: Equatable {
    case playVideo(URL)
    case importTimeline
    case openProject(URL)
}

extension ExportJob {
    var artifactKind: ExportArtifactKind { artifact?.kind ?? .infer(from: outputURL) }

    var primaryAction: ExportArtifactAction? {
        guard status == .completed else { return nil }
        switch artifactKind {
        case .video: return .playVideo(outputURL)
        case .timeline: return .importTimeline
        case .project: return .openProject(outputURL)
        case .unknown: return nil
        }
    }
}

enum ExportHistoryStatus: String, CaseIterable {
    case all, active, completed, attention

    var title: String {
        switch self {
        case .all: "All statuses"
        case .active: "In progress"
        case .completed: "Completed"
        case .attention: "Needs attention"
        }
    }

    func matches(_ job: ExportJob) -> Bool {
        switch self {
        case .all: true
        case .active: job.status.isPending
        case .completed: job.status == .completed
        case .attention: job.status == .failed || job.status == .canceled || !job.warnings.isEmpty
        }
    }
}

struct ExportHistoryFilter {
    var kind: ExportArtifactKind?
    var projectID: String?
    var search = ""
    var status: ExportHistoryStatus = .all

    @MainActor func apply(to jobs: [ExportJob]) -> [ExportJob] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return jobs.filter { job in
            (kind == nil || job.artifactKind == kind)
                && (projectID == nil || job.projectID == projectID)
                && status.matches(job)
                && (query.isEmpty || job.filename.localizedCaseInsensitiveContains(query)
                    || (job.linkedProjectURL?.deletingPathExtension().lastPathComponent
                        .localizedCaseInsensitiveContains(query) ?? false))
        }.sorted {
            if $0.status.isPending != $1.status.isPending { return $0.status.isPending }
            return $0.createdAt > $1.createdAt
        }
    }
}
