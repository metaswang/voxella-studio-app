import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Export artifact routing and history")
@MainActor
struct ExportArtifactTests {
    @Test func legacyHistoriesClassifyByExtensionWithoutChangingTheirContent() throws {
        for (filename, kind) in [
            ("video.MP4", ExportArtifactKind.video), ("video.mov", .video), ("video.m4v", .video),
            ("edit.FCPXML", .timeline), ("edit.xml", .timeline), ("copy.voxella", .project),
            ("notes.txt", .unknown), ("no-extension", .unknown)
        ] {
            var original = job(filename)
            original.mediaSummary = "FCPXML · unrelated display text"
            let encoded = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(ExportJob.self, from: encoded)
            #expect(restored.artifact == nil)
            #expect(restored.artifactKind == kind)
            #expect(restored.filename == original.filename)
            #expect(restored.outputURL == original.outputURL)
            #expect(restored.mediaSummary == original.mediaSummary)
            #expect(restored.artifact?.targetEditor == nil)
        }
    }

    @Test func structuredMetadataSurvivesRoundTripAndOverridesFilenameInference() throws {
        var original = job("unusual-name.bin")
        original.artifact = ExportArtifactDescriptor(kind: .timeline, format: "FCPXML", targetEditor: .fcp,
                                                      durationSeconds: 12.5)
        let restored = try JSONDecoder().decode(ExportJob.self, from: JSONEncoder().encode(original))
        #expect(restored.artifact == original.artifact)
        #expect(restored.artifactKind == .timeline)
        #expect(restored.primaryAction == .importTimeline)

        let future = try JSONDecoder().decode(ExportArtifactKind.self, from: Data("\"future-type\"".utf8))
        #expect(future == .unknown)
    }

    @Test func actionsUseTheArtifactOutputAndNeverTheCurrentPurposeOrSourceProject() {
        let video = job("video.mp4")
        let timeline = job("timeline.fcpxml")
        var copy = job("copy.voxella")
        copy.sourceProjectURL = URL(fileURLWithPath: "/tmp/source.voxella")
        #expect(video.primaryAction == .playVideo(video.outputURL))
        #expect(timeline.primaryAction == .importTimeline)
        #expect(copy.primaryAction == .openProject(copy.outputURL))
        #expect(job("file.unknown").primaryAction == nil)
        #expect(job("queued.mp4", status: .waiting).primaryAction == nil)
        #expect(job("failed.mp4", status: .failed).primaryAction == nil)
    }

    @Test func screenshotRegressionTimelineHistoryDoesNotAppearUnderVideo() {
        let timeline = job("VoxStudio-export-ui-check.fcpxml")
        #expect(ExportHistoryFilter(kind: .video, projectID: "a").apply(to: [timeline]).isEmpty)
        #expect(ExportHistoryFilter(kind: .timeline, projectID: "a").apply(to: [timeline]).map(\.id) == [timeline.id])
        #expect(ExportHistoryFilter(kind: nil, projectID: "a").apply(to: [timeline]).first?.primaryAction == .importTimeline)
    }

    @Test func typeProjectSearchAndStatusComposeWithoutLosingPendingOrder() {
        let video = job("finished.mp4")
        let timeline = job("edit.xml")
        let copy = job("copy.voxella")
        let failed = job("other.mp4", projectID: "b", status: .failed)
        let active = job("rendering.mp4", status: .exporting)
        var named = job("named.mov", projectID: "b")
        named.sourceProjectURL = URL(fileURLWithPath: "/tmp/Travel.voxella")
        let jobs = [video, timeline, copy, failed, active, named]

        let currentVideos = ExportHistoryFilter(kind: .video, projectID: "a").apply(to: jobs)
        #expect(currentVideos.map(\.id) == [active.id, video.id])
        #expect(ExportHistoryFilter(kind: .video, projectID: nil).apply(to: jobs).count == 4)
        #expect(ExportHistoryFilter(kind: nil, projectID: "a").apply(to: jobs).count == 4)
        #expect(ExportHistoryFilter(kind: .video, projectID: nil, search: "travel", status: .completed)
            .apply(to: jobs).map(\.id) == [named.id])
        #expect(ExportHistoryFilter(kind: .video, projectID: nil, status: .attention)
            .apply(to: jobs).map(\.id) == [failed.id])
        #expect(ExportHistoryFilter(kind: .timeline, projectID: nil, search: "EDIT", status: .completed)
            .apply(to: jobs).map(\.id) == [timeline.id])
        #expect(ExportHistoryFilter(kind: .project, projectID: "a", status: .active).apply(to: jobs).isEmpty)
    }

    @Test(arguments: TimelineExportEditor.allCases)
    func queuePersistsTheChosenEditor(editor: TimelineExportEditor) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("history.json")
        let output = directory.appendingPathComponent("export.\(editor.defaultFormat.fileExtension)")
        let queue = ExportQueue(historyURL: history)
        try queue.enqueueVideo(timeline: Fixtures.timeline(),
            resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { nil }),
            resolveTimeline: { _ in nil }, format: editor.defaultFormat, resolution: .matchTimeline,
            fcpxmlTarget: editor.fcpxmlTarget, targetEditor: editor,
            missingMediaRefs: [], outputURL: output, source: .manual, projectID: "a", analyticsProjectID: nil)
        for _ in 0..<500 where queue.hasActivity { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!queue.hasActivity)
        let restored = try #require(ExportQueue(historyURL: history).jobs.first)
        #expect(restored.status == .completed)
        #expect(restored.artifactKind == .timeline)
        #expect(restored.artifact?.targetEditor == editor)
        #expect(restored.artifact?.format == (editor == .premiere ? "XMEML" : "FCPXML"))
    }

    private func job(_ name: String, projectID: String = "a", status: ExportJobStatus = .completed) -> ExportJob {
        ExportJob(id: UUID(), projectID: projectID, filename: name, source: .manual,
                  outputURL: URL(fileURLWithPath: "/tmp/\(name)"), createdAt: .now,
                  status: status, progress: 1, warnings: [])
    }
}
