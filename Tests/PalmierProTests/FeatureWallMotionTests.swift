import Testing
@testable import PalmierPro

@Suite("Feature wall motion")
struct FeatureWallMotionTests {
    @Test(arguments: [-1.0, 1.0])
    func oneCycleReturnsToTheSamePosition(direction: Double) {
        let start = FeatureWallMotion.position(index: 2, count: 5, pitch: 196, elapsed: 0, speed: direction * 17, offset: 94)
        let end = FeatureWallMotion.position(index: 2, count: 5, pitch: 196, elapsed: 980 / 17, speed: direction * 17, offset: 94)
        #expect(abs(start - end) < 0.0001)
    }

    @Test func focalPointIsEmphasizedAndEdgesRemainQuiet() {
        #expect(FeatureWallMotion.prominence(y: 285, center: 285, radius: 240) == 1)
        #expect(FeatureWallMotion.prominence(y: 45, center: 285, radius: 240) == 0)
        #expect(FeatureWallMotion.prominence(y: 525, center: 285, radius: 240) == 0)
        #expect(FeatureWallMotion.prominence(y: 225, center: 285, radius: 240) == FeatureWallMotion.prominence(y: 345, center: 285, radius: 240))
    }

    @Test @MainActor func centerZoomIsNoticeableRelativeToSurroundingCards() {
        let center = 285.0
        let focused = FeatureWallMotion.scale(y: center, center: center, reduceMotion: false)
        let nearby = FeatureWallMotion.scale(y: center + 70, center: center, reduceMotion: false)
        let outer = FeatureWallMotion.scale(y: center + 140, center: center, reduceMotion: false)
        #expect(focused >= 1.2)
        #expect(focused / outer >= 1.25)
        #expect(focused > nearby && nearby > outer)
    }

    @Test @MainActor func reducedMotionDisablesCenterZoom() {
        #expect(FeatureWallMotion.scale(y: 285, center: 285, reduceMotion: true) == 1)
        #expect(FeatureWallMotion.scale(y: 0, center: 285, reduceMotion: true) == 1)
    }

    @Test(arguments: [Double.nan, .infinity])
    func invalidElapsedTimeCannotCreateInvalidGeometry(elapsed: Double) {
        #expect(FeatureWallMotion.position(index: 0, count: 5, pitch: 196, elapsed: elapsed, speed: 17, offset: 0) == 0)
    }
}
