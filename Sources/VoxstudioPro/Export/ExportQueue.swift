import Foundation
import AVFoundation

enum ExportJobSource: String, Codable, Sendable {
    case manual
    case agent
}

enum ExportJobStatus: String, Codable, Sendable {
    case waiting = "queued"
    case preparing
    case exporting = "rendering"
    case canceling
    case completed
    case failed
    case canceled

    var isRunning: Bool {
        switch self {
        case .preparing, .exporting, .canceling: true
        default: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .canceled: true
        default: false
        }
    }

    var isPending: Bool { self == .waiting || isRunning }
}

struct ExportJob: Identifiable, Codable, Sendable {
    let id: UUID
    let projectID: String
    let filename: String
    let source: ExportJobSource
    let outputURL: URL
    let createdAt: Date
    var status: ExportJobStatus
    var progress: Double
    var error: String?
    var warnings: [String]
    var palmierReport: PalmierProjectExporter.Report? = nil
    var sourceProjectURL: URL? = nil
    var sourceProjectRegistryID: UUID? = nil

    var coverData: Data? = nil
    var mediaSummary: String? = nil
    var outputBytes: Int64? = nil
    var outputModifiedAt: Date? = nil
    var outputCreatedAt: Date? = nil
    var artifact: ExportArtifactDescriptor? = nil

    enum CodingKeys: String, CodingKey {
        case id, projectID, filename, source, outputURL, createdAt, status, progress, error, warnings
        case sourceProjectURL, sourceProjectRegistryID, coverData, mediaSummary, outputBytes, outputModifiedAt, outputCreatedAt
        case artifact
    }

    @MainActor var linkedProjectURL: URL? {
        if let sourceProjectRegistryID,
           let entry = ProjectRegistry.shared.entries.first(where: { $0.id == sourceProjectRegistryID }) {
            return entry.url
        }
        return sourceProjectURL
    }
}

struct ExportQueueSubmission: Sendable {
    let jobID: UUID
    let started: Bool
    let queuePosition: Int
}

enum ExportQueueError: LocalizedError {
    case destinationInUse(String)

    var errorDescription: String? {
        switch self {
        case .destinationInUse(let filename):
            "An export to \(filename) is already waiting or in progress."
        }
    }
}

@Observable
@MainActor
final class ExportQueue {
    static let shared = ExportQueue(historyURL: Project.storageDirectory.appendingPathComponent("export-history.json"))

    typealias Operation = @MainActor (ExportService) async -> Void
    private(set) var jobs: [ExportJob] = []
    private var operations: [UUID: Operation] = [:]
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var activeService: ExportService?

    private let historyURL: URL?
    private(set) var historyError: String?

    // Explicit storage keeps test queues isolated from the user's export library.
    init(historyURL: URL? = nil) {
        self.historyURL = historyURL
        guard let historyURL, FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            jobs = try JSONDecoder().decode([ExportJob].self, from: Data(contentsOf: historyURL))
            for index in jobs.indices where jobs[index].status.isPending {
                jobs[index].status = .failed
                jobs[index].error = "Export interrupted when VoxStudio closed. Export again to retry."
            }
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func saveHistory() {
        guard let historyURL else { return }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: historyURL, options: .atomic)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    var hasActivity: Bool { jobs.contains { $0.status.isPending } }
    var isExportActive: Bool { activeID != nil }

    func waitWhileExportActive() async throws {
        while isExportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }

    func jobs(for projectID: String) -> [ExportJob] {
        jobs.filter { $0.projectID == projectID }
    }

    func isDestinationReserved(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return jobs.contains { $0.status.isPending && $0.outputURL.standardizedFileURL.path == path }
    }

    @discardableResult
    func enqueueVideo(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        format: ExportFormat,
        resolution: ExportResolution,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        targetEditor: TimelineExportEditor? = nil,
        missingMediaRefs: Set<String>,
        outputURL: URL,
        source: ExportJobSource,
        projectID: String,
        analyticsProjectID: String?,
        warnings: [String] = [],
        sourceProjectURL: URL? = nil,
        coverData: Data? = nil
    ) throws -> ExportQueueSubmission {
        let resolver = resolver.snapshot()
        let analyticsInput = ExportTimelineAnalyticsInput(
            scope: .exportedTimeline(root: timeline, resolveTimeline: resolveTimeline),
            manifest: resolver.manifestSnapshot(),
            exportFilename: outputURL.lastPathComponent
        )
        let size = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))
        let seconds = Double(timeline.totalFrames) / Double(max(1, timeline.fps))
        let formatName: String = switch format {
        case .h264: "H.264"
        case .h265: "H.265"
        case .prores: "ProRes"
        case .hevcHDR: "HEVC 10-bit HDR"
        case .xml: "XMEML"
        case .fcpxml: "FCPXML"
        }
        let summary = "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60)) · \(Int(size.width))×\(Int(size.height)) · \(timeline.fps) fps · \(formatName)"
        let isTimeline = format == .xml || format == .fcpxml
        let artifact = ExportArtifactDescriptor(
            kind: isTimeline ? .timeline : .video,
            format: formatName,
            targetEditor: isTimeline ? (targetEditor ?? (format == .xml ? .premiere : (fcpxmlTarget == .fcp ? .fcp : .resolve))) : nil,
            durationSeconds: seconds
        )
        return try enqueue(outputURL: outputURL, projectID: projectID, source: source, warnings: warnings,
                           sourceProjectURL: sourceProjectURL, mediaSummary: summary, coverData: coverData, artifact: artifact) { service in
            await service.export(
                timeline: timeline,
                resolver: resolver,
                resolveTimeline: resolveTimeline,
                format: format,
                resolution: resolution,
                fcpxmlVersion: fcpxmlVersion,
                fcpxmlTarget: fcpxmlTarget,
                missingMediaRefs: missingMediaRefs,
                outputURL: outputURL,
                analyticsContext: ExportAnalyticsContext(
                    source: source.rawValue,
                    projectId: analyticsProjectID,
                    timelineInput: analyticsInput
                )
            )
        }
    }

    @discardableResult
    func enqueuePalmierProject(
        projectFile: ProjectFile,
        manifest: MediaManifest,
        sourceProjectURL: URL?,
        outputURL: URL,
        source: ExportJobSource,
        projectID: String,
        analyticsProjectID: String?,
        coverData: Data? = nil
    ) throws -> ExportQueueSubmission {
        let analyticsInput = ExportTimelineAnalyticsInput(
            scope: .project(
                timelines: projectFile.timelines,
                rootTimelineId: projectFile.activeTimelineId
            ),
            manifest: manifest,
            exportFilename: outputURL.lastPathComponent
        )
        let artifact = ExportArtifactDescriptor(kind: .project, format: Project.fileExtension,
            timelineCount: projectFile.timelines.count, mediaFileCount: manifest.entries.count)
        return try enqueue(outputURL: outputURL, projectID: projectID, source: source, sourceProjectURL: sourceProjectURL, mediaSummary: L10n.format("%@ timelines · %@ media files", projectFile.timelines.count, manifest.entries.count), coverData: coverData, artifact: artifact) { service in
            await service.exportPalmierProject(
                projectFile: projectFile,
                manifest: manifest,
                sourceProjectURL: sourceProjectURL,
                outputURL: outputURL,
                analyticsContext: ExportAnalyticsContext(
                    source: source.rawValue,
                    projectId: analyticsProjectID,
                    timelineInput: analyticsInput
                )
            )
        }
    }

    @discardableResult
    func cancel(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        switch jobs[index].status {
        case .waiting:
            operations[id] = nil
            jobs[index].status = .canceled
            saveHistory()
            return true
        case .preparing, .exporting:
            if let activeService, !activeService.cancel() { return false }
            jobs[index].status = .canceling
            activeTask?.cancel()
            return true
        case .canceling:
            return true
        default:
            return false
        }
    }

    func remove(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.status.isFinished == true else { return }
        jobs.removeAll { $0.id == id }
        saveHistory()
    }

    func clearFinished(for projectID: String) {
        jobs.removeAll { $0.projectID == projectID && $0.status.isFinished }
        saveHistory()
    }

#if DEBUG
    @discardableResult
    func enqueueForTesting(
        outputURL: URL,
        projectID: String = "test-project",
        operation: @escaping Operation
    ) throws -> ExportQueueSubmission {
        try enqueue(outputURL: outputURL, projectID: projectID, source: .manual, operation: operation)
    }
#endif

    private func enqueue(
        outputURL: URL,
        projectID: String,
        source: ExportJobSource,
        warnings: [String] = [],
        sourceProjectURL: URL? = nil,
        mediaSummary: String? = nil,
        coverData: Data? = nil,
        artifact: ExportArtifactDescriptor? = nil,
        operation: @escaping Operation
    ) throws -> ExportQueueSubmission {
        guard !isDestinationReserved(outputURL) else {
            throw ExportQueueError.destinationInUse(outputURL.lastPathComponent)
        }

        let id = UUID()
        jobs.append(ExportJob(
            id: id,
            projectID: projectID,
            filename: outputURL.lastPathComponent,
            source: source,
            outputURL: outputURL,
            createdAt: .now,
            status: .waiting,
            progress: 0,
            warnings: warnings,
            palmierReport: nil,
            sourceProjectURL: sourceProjectURL,
            sourceProjectRegistryID: sourceProjectURL.flatMap { ProjectRegistry.shared.id(for: $0) },
            coverData: coverData ?? sourceProjectURL.flatMap {
                ImageEncoder.thumbnail(url: $0.appendingPathComponent(Project.thumbnailFilename), maxPixelSize: 320)
            }.flatMap { ImageEncoder.encodeJPEG($0, quality: 0.8) },
            mediaSummary: mediaSummary,
            artifact: artifact
        ))
        saveHistory()
        operations[id] = operation
        startNext()

        let waiting = jobs.filter { $0.status == .waiting }
        return ExportQueueSubmission(
            jobID: id,
            started: activeID == id,
            queuePosition: waiting.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        )
    }

    private func startNext() {
        guard activeID == nil,
              let index = jobs.firstIndex(where: { $0.status == .waiting && operations[$0.id] != nil }) else { return }
        let id = jobs[index].id
        activeID = id
        jobs[index].status = .preparing
        activeTask = Task { @MainActor [weak self] in await self?.run(id) }
    }

    private func run(_ id: UUID) async {
        guard activeID == id, let operation = operations[id] else { return }
        let service = ExportService()
        activeService = service
        guard !Task.isCancelled else {
            finish(id, status: .canceled, service: service)
            return
        }
        service.onPhaseChange = { [weak self] phase in self?.update(phase, for: id) }
        service.onProgressChange = { [weak self] progress in self?.update(progress, for: id) }

        await operation(service)

        let status: ExportJobStatus
        if service.didCommitOutput {
            status = .completed
        } else if service.wasCancelled || job(id)?.status == .canceling {
            status = .canceled
        } else if service.error != nil {
            status = .failed
        } else {
            service.error = "Export produced no output."
            status = .failed
        }
        if status == .completed, let outputURL = job(id)?.outputURL {
            let metadata = await Task.detached(priority: .utility) {
                await ExportArtifactMetadata.read(outputURL)
            }.value
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                // A project cover supplied from the current timeline is newer than the
                // package's last saved thumbnail. Video covers come from the rendered file.
                let isVideo = ["mp4", "mov", "m4v"].contains(outputURL.pathExtension.lowercased())
                if let cover = metadata.cover, isVideo || jobs[index].coverData == nil {
                    jobs[index].coverData = cover
                }
                jobs[index].outputBytes = metadata.bytes
                jobs[index].outputModifiedAt = metadata.modifiedAt
                jobs[index].outputCreatedAt = metadata.createdAt
                if let duration = metadata.durationSeconds {
                    jobs[index].artifact?.durationSeconds = duration
                }
                if let summary = metadata.videoSummary {
                    let hdr = jobs[index].mediaSummary?.contains("HDR") == true ? " · HDR" : ""
                    jobs[index].mediaSummary = summary + hdr
                }
            }
        }
        let source = job(id)?.source
        let filename = job(id)?.filename
        let outputURL = job(id)?.outputURL
        finish(id, status: status, service: service)

        guard source == .agent, let filename, let outputURL else { return }
        if status == .completed {
            AppNotifications.exportComplete(
                name: filename,
                outputURL: outputURL,
                size: service.lastReport?.outputSize,
                warningCount: job(id)?.warningCount(service.lastReport) ?? 0
            )
        } else if status == .failed {
            AppNotifications.exportFailed(name: filename, reason: service.error ?? "Export failed")
        }
    }

    private func finish(_ id: UUID, status: ExportJobStatus, service: ExportService) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].progress = status == .completed ? 1 : service.progress
        jobs[index].error = service.error
        if let report = service.lastPalmierReport {
            jobs[index].palmierReport = report
            jobs[index].warnings = report.warnings
        }
        saveHistory()
        operations[id] = nil
        activeID = nil
        activeTask = nil
        activeService = nil
        startNext()
    }

    private func update(_ phase: ExportService.Phase, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status != .canceling else { return }
        jobs[index].status = phase == .preparing ? .preparing : .exporting
    }

    private func update(_ progress: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status.isPending
        else { return }
        jobs[index].progress = min(1, max(0, progress))
    }

    private func job(_ id: UUID) -> ExportJob? {
        jobs.first { $0.id == id }
    }

}

private extension ExportJob {
    func warningCount(_ mediaReport: ExportRunReport?) -> Int {
        if let palmierReport { return palmierReport.missing.count }
        if let mediaReport {
            return mediaReport.offlineMediaRefs.count + mediaReport.unprocessableMediaRefs.count
        }
        return warnings.count
    }
}
