import Foundation
import Testing
@testable import PalmierPro

@Suite("App zoom scale")
struct AppZoomScaleTests {
    @Test func defaultScalePreservesExistingZoom() {
        let defaults = isolatedDefaults()
        let scale = AppZoomScale(defaults: defaults)

        #expect(scale.scale == AppZoomScale.defaultScale)
    }

    @Test func scaleChangesPersistAndStayWithinBounds() {
        let defaults = isolatedDefaults()
        let scale = AppZoomScale(defaults: defaults)

        scale.increase()
        #expect(scale.scale == 1.1)
        #expect(defaults.double(forKey: AppZoomScale.defaultsKey) == 1.1)

        for _ in 0..<20 { scale.increase() }
        #expect(scale.scale == AppZoomScale.maximumScale)

        for _ in 0..<20 { scale.decrease() }
        #expect(scale.scale == AppZoomScale.minimumScale)
    }

    @Test func resetReturnsToDefaultScale() {
        let scale = AppZoomScale(defaults: isolatedDefaults())

        scale.setScale(1.4)
        scale.reset()

        #expect(scale.scale == AppZoomScale.defaultScale)
        #expect(scale.isDefault)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "VoxStudio.AppZoomScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
