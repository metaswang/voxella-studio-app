import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Curve editor geometry")
struct CurveEditorGeometryTests {
    private let size = CGSize(width: 200, height: 100)
    private let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    @Test func coordinateConversionClampsToTheCanvas() {
        #expect(
            CurveEditorGeometry.screenPoint(CurvePoint(x: 0.25, y: 0.75), in: size)
                == CGPoint(x: 50, y: 25)
        )
        #expect(
            CurveEditorGeometry.normalizedPoint(at: CGPoint(x: 300, y: -20), in: size)
                == CurvePoint(x: 1, y: 1)
        )
    }

    @Test func grabbingAddsSortedPointsAndReusesNearbyPoints() {
        let inserted = CurveEditorGeometry.grabbedPoint(
            at: CGPoint(x: 100, y: 50),
            in: identity,
            canvasSize: size,
            hitDiameter: 10
        )
        #expect(inserted.points == [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 1, y: 1),
        ])
        #expect(inserted.index == 1)

        let existing = CurveEditorGeometry.grabbedPoint(
            at: CGPoint(x: 3, y: 98),
            in: identity,
            canvasSize: size,
            hitDiameter: 10
        )
        #expect(existing.points == identity)
        #expect(existing.index == 0)
    }

    @Test func movingPreservesEndpointXAndDoesNotCrossNeighbors() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 1, y: 1),
        ]
        let middle = CurveEditorGeometry.movedPoint(
            in: points,
            at: 1,
            to: CGPoint(x: 300, y: 25),
            canvasSize: size
        )
        #expect(middle[1] == CurvePoint(x: 0.999, y: 0.75))

        let endpoint = CurveEditorGeometry.movedPoint(
            in: points,
            at: 0,
            to: CGPoint(x: 100, y: 50),
            canvasSize: size
        )
        #expect(endpoint[0] == CurvePoint(x: 0, y: 0.5))
    }

    @Test func deletionKeepsEndpointsAndRemovesInteriorPoints() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 1, y: 1),
        ]
        #expect(
            CurveEditorGeometry.removingNearestPoint(
                to: CGPoint(x: 100, y: 50),
                in: points,
                canvasSize: size,
                hitDiameter: 10
            ) == identity
        )
        #expect(
            CurveEditorGeometry.removingNearestPoint(
                to: CGPoint(x: 0, y: 100),
                in: points,
                canvasSize: size,
                hitDiameter: 10
            ) == nil
        )
    }
}
