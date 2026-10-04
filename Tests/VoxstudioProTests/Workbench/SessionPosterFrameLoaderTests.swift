import AVFoundation
import ImageIO
import Testing
@testable import VoxstudioPro

@Suite("Session poster extraction")
struct SessionPosterFrameLoaderTests {
    @Test func extractsVideoWhoseFirstFrameStartsAfterZero() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session-poster-offset.mp4")
        let asset = AVURLAsset(url: url)
        let exactGenerator = AVAssetImageGenerator(asset: asset)
        exactGenerator.requestedTimeToleranceBefore = .zero
        exactGenerator.requestedTimeToleranceAfter = .zero
        await #expect(throws: (any Error).self) {
            _ = try await exactGenerator.image(at: .zero)
        }

        let data = try #require(await SessionPosterFrameLoader.load(url: url, enabled: true))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 36)
    }

    @Test func disabledPosterDoesNotLoadMedia() async {
        let data = await SessionPosterFrameLoader.load(
            url: URL(fileURLWithPath: "/missing/audio.m4a"), enabled: false
        )
        #expect(data == nil)
    }
}
