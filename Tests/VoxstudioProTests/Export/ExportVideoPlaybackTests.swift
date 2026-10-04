import AVFoundation
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Export video preview", .serialized)
@MainActor
struct ExportVideoPlaybackTests {
    @Test func missingAndDamagedFilesShowRecoverableErrors() async throws {
        let player = ExportVideoPlayback()
        defer { player.stop() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        player.open(missing)
        #expect(await waitUntil { player.phase == .failed })
        #expect(player.error == ExportVideoPreviewError.missing.errorDescription)

        try Data("not a video".utf8).write(to: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        player.retry()
        #expect(await waitUntil { player.phase == .failed })
        #expect(player.error == ExportVideoPreviewError.unplayable.errorDescription)
        #expect(player.player.currentItem == nil)
    }

    @Test func closingDuringLoadingDiscardsTheLateResult() async throws {
        var completion: CheckedContinuation<AVPlayerItem, Error>?
        let playback = ExportVideoPlayback { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        }
        playback.open(URL(fileURLWithPath: "/tmp/slow.mp4"))
        #expect(await waitUntil { completion != nil })
        let pending = try #require(completion)
        playback.stop()
        pending.resume(returning: AVPlayerItem(asset: AVMutableComposition()))
        for _ in 0..<20 { await Task.yield() }
        #expect(playback.phase == .idle)
        #expect(playback.player.currentItem == nil)
        #expect(playback.player.rate == 0)
        #expect(playback.error == nil)
        #expect(playback.url == nil)
    }

    @Test func switchingFilesIgnoresAnEarlierLoadFailure() async throws {
        var completions: [String: CheckedContinuation<AVPlayerItem, Error>] = [:]
        let playback = ExportVideoPlayback { url in
            try await withCheckedThrowingContinuation { completions[url.lastPathComponent] = $0 }
        }
        defer { playback.stop() }
        playback.open(URL(fileURLWithPath: "/tmp/first.mp4"))
        #expect(await waitUntil { completions["first.mp4"] != nil })
        playback.open(URL(fileURLWithPath: "/tmp/second.mov"))
        #expect(await waitUntil { completions["second.mov"] != nil })
        try #require(completions["first.mp4"]).resume(throwing: ExportVideoPreviewError.missing)
        for _ in 0..<20 { await Task.yield() }
        #expect(playback.phase == .loading)
        #expect(playback.error == nil)
        #expect(playback.url?.lastPathComponent == "second.mov")
        try #require(completions["second.mov"]).resume(throwing: ExportVideoPreviewError.unreadable)
        #expect(await waitUntil { playback.phase == .failed })
        #expect(playback.error == ExportVideoPreviewError.unreadable.errorDescription)
    }

    @Test(arguments: [ExportFormat.h264, .prores])
    func actualExportPlaysAndStops(format: ExportFormat) async throws {
        let source = try await ImageVideoGenerator.blackVideo(size: CGSize(width: 320, height: 180))
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "video", name: "video", type: .video,
            source: .external(absolutePath: source.path), duration: 5)]
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", mediaRef: "video", start: 0, duration: 30)
        ])])
        timeline.width = 320
        timeline.height = 180
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = ExportService()
        await exporter.export(timeline: timeline,
            resolver: MediaResolver(manifest: { manifest }, projectURL: { nil }),
            format: format, resolution: .matchTimeline, outputURL: output)
        #expect(exporter.didCommitOutput)
        #expect(exporter.error == nil)
        let playback = ExportVideoPlayback()
        defer { playback.stop() }
        playback.open(output)
        #expect(await waitUntil { playback.phase == .ready || playback.phase == .failed })
        #expect(playback.phase == .ready)
        #expect(playback.error == nil)
        #expect((playback.player.currentItem?.asset as? AVURLAsset)?.url == output)
        playback.stop()
        #expect(playback.player.rate == 0)
        #expect(playback.player.currentItem == nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
