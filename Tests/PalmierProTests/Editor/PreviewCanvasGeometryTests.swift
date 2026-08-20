import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Preview canvas geometry")
struct PreviewCanvasGeometryTests {
    @Test func aspectFitCentersVideoInWideAndTallViews() {
        let timeline = Timeline(width: 1_920, height: 1_080)

        let square = PreviewCanvasGeometry.videoContentRect(
            in: CGSize(width: 1_000, height: 1_000),
            timeline: timeline
        )
        #expect(abs(square.minX - 0) < 0.000_001)
        #expect(abs(square.minY - 218.75) < 0.000_001)
        #expect(abs(square.width - 1_000) < 0.000_001)
        #expect(abs(square.height - 562.5) < 0.000_001)

        let wide = PreviewCanvasGeometry.videoContentRect(
            in: CGSize(width: 2_000, height: 500),
            timeline: timeline
        )
        #expect(abs(wide.minX - 555.555_555_555_555_5) < 0.000_001)
        #expect(abs(wide.minY - 0) < 0.000_001)
        #expect(abs(wide.width - 888.888_888_888_888_9) < 0.000_001)
        #expect(abs(wide.height - 500) < 0.000_001)
    }

    @Test func invalidViewOrTimelineSizeReturnsZero() {
        #expect(
            PreviewCanvasGeometry.videoContentRect(
                in: CGSize(width: 0, height: 500),
                timeline: Timeline(width: 1_920, height: 1_080)
            ) == .zero
        )
        #expect(
            PreviewCanvasGeometry.videoContentRect(
                in: CGSize(width: 500, height: 500),
                timeline: Timeline(width: 0, height: 1_080)
            ) == .zero
        )
    }
}
