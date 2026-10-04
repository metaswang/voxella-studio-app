import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Export queue", .serialized)
@MainActor
struct ExportQueueTests {
    @Test func runsInFIFOOrder() async throws {
        let queue = ExportQueue()
        var events: [String] = []
        let first = try enqueue(queue, "first.mov") { _ in
            events.append("first-start")
            await Task.yield()
            events.append("first-finish")
        }
        let second = try enqueue(queue, "second.mov") { _ in
            events.append("second-start")
            events.append("second-finish")
        }

        #expect(first.started)
        #expect(!second.started)
        #expect(second.queuePosition == 1)
        #expect(await waitUntil { !queue.hasActivity })
        #expect(events == ["first-start", "first-finish", "second-start", "second-finish"])
    }

    @Test func cancelingPreparingJobAdvancesQueueWithoutRunningIt() async throws {
        let queue = ExportQueue()
        var firstRan = false
        var secondRan = false
        let first = try enqueue(queue, "active.mov") { _ in
            firstRan = true
            try? await Task.sleep(for: .seconds(30))
        }
        let second = try enqueue(queue, "next.mov") { _ in secondRan = true }

        queue.cancel(first.jobID)

        #expect(await waitUntil {
            queue.job(first.jobID)?.status == .canceled && queue.job(second.jobID)?.status == .failed
        })
        #expect(!firstRan)
        #expect(secondRan)
        #expect(queue.job(second.jobID)?.error == "Export produced no output.")
    }

    @Test func cancelingWaitingJobDoesNotRunIt() async throws {
        let queue = ExportQueue()
        var waitingRan = false
        let blocker = try enqueue(queue, "waiting-blocker.mov") { _ in
            try? await Task.sleep(for: .seconds(30))
        }
        let waiting = try enqueue(queue, "waiting.mov") { _ in waitingRan = true }

        queue.cancel(waiting.jobID)
        queue.cancel(blocker.jobID)

        #expect(queue.job(waiting.jobID)?.status == .canceled)
        #expect(await waitUntil { !queue.hasActivity })
        #expect(!waitingRan)
    }

    @Test func scopesHistoryByProject() async throws {
        let queue = ExportQueue()
        let first = try enqueue(queue, "project-first.xml", projectID: "project-a") { _ in }
        let second = try enqueue(queue, "project-second.xml", projectID: "project-b") { _ in }
        #expect(await waitUntil { !queue.hasActivity })
        #expect(queue.jobs(for: "project-a").map(\.id) == [first.jobID])
        #expect(queue.jobs(for: "project-b").map(\.id) == [second.jobID])

        queue.clearFinished(for: "project-a")

        #expect(queue.jobs(for: "project-a").isEmpty)
        #expect(queue.jobs(for: "project-b").map(\.id) == [second.jobID])

        let url = temporaryURL("stable-project.palmier")
        let firstEditor = EditorViewModel()
        let secondEditor = EditorViewModel()
        firstEditor.projectURL = url
        secondEditor.projectURL = url
        #expect(firstEditor.exportQueueProjectID == secondEditor.exportQueueProjectID)
    }

    @Test func lateProgressAndCancellationKeepCommittedExportCompleted() async throws {
        let queue = ExportQueue()
        let outputURL = temporaryURL("late-cancel.xml")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        var jobID: UUID!
        var cancellationAccepted: Bool?
        var progressUpdate: ((Double) -> Void)?
        let submission = try queue.enqueueForTesting(outputURL: outputURL) { service in
            progressUpdate = service.onProgressChange
            await service.export(
                timeline: Fixtures.timeline(),
                resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { nil }),
                format: .xml,
                resolution: .matchTimeline,
                outputURL: outputURL
            )
            cancellationAccepted = queue.cancel(jobID)
        }
        jobID = submission.jobID

        #expect(await waitUntil { queue.job(jobID)?.status.isFinished == true })
        #expect(cancellationAccepted == false)
        #expect(queue.job(jobID)?.status == .completed)
        progressUpdate?(0.25)
        #expect(queue.job(jobID)?.progress == 1)
    }

    @Test func historyPersistsLinksAndRemovalWithoutDeletingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("history.json")
        let output = directory.appendingPathComponent("export.xml")
        let source = directory.appendingPathComponent("source.voxella")
        let queue = ExportQueue(historyURL: history)
        let submission = try queue.enqueueVideo(
            timeline: Fixtures.timeline(),
            resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { nil }),
            resolveTimeline: { _ in nil }, format: .xml, resolution: .matchTimeline,
            missingMediaRefs: [], outputURL: output, source: .manual,
            projectID: "persisted-project", analyticsProjectID: nil, sourceProjectURL: source
        )
        #expect(await waitUntil { !queue.hasActivity })
        let restored = ExportQueue(historyURL: history)
        let job = try #require(restored.jobs.first)
        #expect(job.id == submission.jobID)
        #expect(job.status == .completed)
        #expect(job.sourceProjectURL == source)
        #expect(job.outputBytes != nil)
        #expect(job.mediaSummary?.contains("XMEML") == true)
        restored.remove(job.id)
        #expect(ExportQueue(historyURL: history).jobs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func interruptedJobsRestoreAsFailuresAndReleaseDestination() throws {
        let history = temporaryURL(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: history) }
        let output = temporaryURL("interrupted.mp4")
        let job = ExportJob(id: UUID(), projectID: "project", filename: "interrupted.mp4",
                            source: .manual, outputURL: output, createdAt: .now,
                            status: .exporting, progress: 0.4, warnings: [],
                            coverData: Data([1, 2, 3]), mediaSummary: "1920×1080 · 30 fps")
        try JSONEncoder().encode([job]).write(to: history)
        let queue = ExportQueue(historyURL: history)
        #expect(queue.jobs.first?.status == .failed)
        #expect(queue.jobs.first?.coverData == job.coverData)
        #expect(queue.jobs.first?.error?.contains("interrupted") == true)
        #expect(!queue.isDestinationReserved(output))
        #expect(!queue.hasActivity)
    }

    @Test func readsCoverAndActualMetadataFromVideoAndProjectPackage() async throws {
        let video = try await ImageVideoGenerator.blackVideo(size: CGSize(width: 320, height: 180))
        let metadata = await ExportArtifactMetadata.read(video)
        let cover = try #require(metadata.cover)
        #expect(ImageEncoder.thumbnail(data: cover, maxPixelSize: 320) != nil)
        #expect(metadata.videoSummary?.contains("320×180") == true)
        #expect(metadata.videoSummary?.contains("fps") == true)
        #expect(metadata.bytes == Int64(try video.resourceValues(forKeys: [.fileSizeKey]).fileSize!))
        #expect(metadata.createdAt != nil)
        #expect(metadata.modifiedAt != nil)

        let package = temporaryURL(UUID().uuidString + ".voxella")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try cover.write(to: package.appendingPathComponent(Project.thumbnailFilename))
        try Data([1, 2, 3]).write(to: package.appendingPathComponent("test-media"))
        let packageMetadata = await ExportArtifactMetadata.read(package)
        #expect(packageMetadata.cover != nil)
        #expect(packageMetadata.bytes == Int64(cover.count + 3))
    }

    private func enqueue(
        _ queue: ExportQueue,
        _ name: String,
        projectID: String = "test-project",
        operation: @escaping @MainActor (ExportService) async -> Void
    ) throws -> ExportQueueSubmission {
        try queue.enqueueForTesting(outputURL: temporaryURL(name), projectID: projectID, operation: operation)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export-queue-\(name)")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private extension ExportQueue {
    func job(_ id: UUID) -> ExportJob? { jobs.first { $0.id == id } }
}
