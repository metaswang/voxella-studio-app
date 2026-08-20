import SwiftUI

enum CurveEditorGeometry {
    static func screenPoint(_ point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    static func normalizedPoint(at location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(
            x: min(1, max(0, location.x / size.width)),
            y: min(1, max(0, 1 - location.y / size.height))
        )
    }

    static func grabbedPoint(
        at location: CGPoint,
        in points: [CurvePoint],
        canvasSize: CGSize,
        hitDiameter: CGFloat
    ) -> (points: [CurvePoint], index: Int) {
        if let index = nearestIndex(
            to: location,
            in: points,
            canvasSize: canvasSize,
            hitDiameter: hitDiameter
        ) {
            return (points, index)
        }
        let point = normalizedPoint(at: location, in: canvasSize)
        let updated = (points + [point]).sorted { $0.x < $1.x }
        return (updated, updated.firstIndex(of: point) ?? 0)
    }

    static func movedPoint(
        in points: [CurvePoint],
        at index: Int,
        to location: CGPoint,
        canvasSize: CGSize
    ) -> [CurvePoint] {
        var updated = points
        let point = normalizedPoint(at: location, in: canvasSize)
        updated[index].y = point.y
        if index != updated.startIndex, index != updated.index(before: updated.endIndex) {
            updated[index].x = min(
                updated[index + 1].x - 0.001,
                max(updated[index - 1].x + 0.001, point.x)
            )
        }
        return updated
    }

    static func removingNearestPoint(
        to location: CGPoint,
        in points: [CurvePoint],
        canvasSize: CGSize,
        hitDiameter: CGFloat
    ) -> [CurvePoint]? {
        guard let index = nearestIndex(
            to: location,
            in: points,
            canvasSize: canvasSize,
            hitDiameter: hitDiameter
        ), points.count > 2,
           index > points.startIndex,
           index < points.index(before: points.endIndex) else {
            return nil
        }
        var updated = points
        updated.remove(at: index)
        return updated
    }

    static func histogramAreaPath(_ bins: [Float], in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in bins.enumerated() {
            let x = CGFloat(index) / CGFloat(bins.count - 1) * size.width
            path.addLine(to: CGPoint(x: x, y: size.height - CGFloat(value) * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private static func nearestIndex(
        to location: CGPoint,
        in points: [CurvePoint],
        canvasSize: CGSize,
        hitDiameter: CGFloat
    ) -> Int? {
        var nearest: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let screenPoint = screenPoint(point, in: canvasSize)
            let distance = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
            if distance <= hitDiameter / 2,
               nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        return nearest?.index
    }
}
