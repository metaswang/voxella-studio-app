import CoreGraphics
import Foundation
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

    @Test func centersTheDefaultRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(
            RecordingRegionGeometry.defaultRect(in: bounds, minimum: 48)
                == CGRect(x: 660, y: 315, width: 600, height: 450)
        )
    }

    @Test func placesASavedRegionBackInsideTheDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let placed = RecordingRegionGeometry.placed(
            CGRect(x: 700, y: 500, width: 300, height: 200),
            in: bounds,
            minimum: 48
        )
        #expect(placed == CGRect(x: 500, y: 400, width: 300, height: 200))
    }

    @Test func ignoresASavedRegionSmallerThanTheMinimum() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(
            RecordingRegionGeometry.placed(
                CGRect(x: 10, y: 10, width: 20, height: 20),
                in: bounds,
                minimum: 48
            ) == nil
        )
    }

    @Test func cornerHandleWinsOverTheAdjacentEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        #expect(
            RecordingRegionGeometry.handle(
                at: CGPoint(x: 100, y: 220),
                in: rect,
                diameter: 10,
                hitOutset: 6
            ) == .topLeft
        )
    }

    @Test func interiorOfTheRegionIsNotAHandle() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        #expect(
            RecordingRegionGeometry.handle(
                at: CGPoint(x: 200, y: 160),
                in: rect,
                diameter: 10,
                hitOutset: 6
            ) == nil
        )
    }

    @Test func movingStopsAtTheDisplayEdge() {
        let moved = RecordingRegionGeometry.moved(
            CGRect(x: 100, y: 100, width: 50, height: 40),
            from: CGPoint(x: 110, y: 110),
            to: CGPoint(x: 900, y: 900),
            in: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        #expect(moved == CGRect(x: 350, y: 260, width: 50, height: 40))
    }

    @Test func resizingTheRightHandleKeepsTheLeftEdge() {
        let resized = RecordingRegionGeometry.resized(
            CGRect(x: 100, y: 80, width: 200, height: 100),
            handle: .right,
            to: CGPoint(x: 360, y: 90),
            minimum: 48,
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(resized == CGRect(x: 100, y: 80, width: 260, height: 100))
    }

    @Test func resizingCannotShrinkBelowTheMinimum() {
        let resized = RecordingRegionGeometry.resized(
            CGRect(x: 100, y: 80, width: 200, height: 100),
            handle: .left,
            to: CGPoint(x: 290, y: 80),
            minimum: 48,
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(resized == CGRect(x: 252, y: 80, width: 48, height: 100))
    }

    @Test func remembersTheLastRegionForADisplay() {
        let suite = "RecordingRegionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let rect = CGRect(x: 12, y: 24, width: 300, height: 180)
        RecordingRegionStore.save(rect, for: "Built-in Display", defaults: defaults)
        #expect(RecordingRegionStore.rect(for: "Built-in Display", defaults: defaults) == rect)
        defaults.removePersistentDomain(forName: suite)
    }
}
