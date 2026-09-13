import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Recording region geometry")
struct RecordingRegionGeometryTests {
    @Test(arguments: [
        CGPoint(x: 500, y: 400),
        CGPoint(x: -100, y: -100)
    ])
    func clipsDraggingToTheSelectedDisplay(end: CGPoint) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rect = RecordingRegionGeometry.dragRect(from: CGPoint(x: 100, y: 100), to: end, bounds: bounds)
        #expect(bounds.contains(rect))
        #expect(rect.width > 0 && rect.height > 0)
    }

    @Test func reverseDragProducesTheSameSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let start = CGPoint(x: 100, y: 200)
        let end = CGPoint(x: 600, y: 700)
        #expect(
            RecordingRegionGeometry.dragRect(from: start, to: end, bounds: bounds)
                == RecordingRegionGeometry.dragRect(from: end, to: start, bounds: bounds)
        )
    }

    @Test func convertsToTopLeftDisplayCoordinatesInPoints() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 100, y: 150, width: 400, height: 300)
        #expect(
            RecordingRegionGeometry.sourceRect(from: rect, bounds: bounds)
                == CGRect(x: 100, y: 450, width: 400, height: 300)
        )
    }

    @Test func clickWithoutDraggingHasNoArea() {
        let point = CGPoint(x: 100, y: 100)
        #expect(RecordingRegionGeometry.dragRect(
            from: point, to: point, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        ).isEmpty)
    }
}
