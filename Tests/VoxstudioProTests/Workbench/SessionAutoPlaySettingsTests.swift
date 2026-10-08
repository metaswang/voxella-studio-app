import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Session auto-play setting", .serialized)
struct SessionAutoPlaySettingsTests {
    private static let key = "voxella.session.autoPlayOnOpen"

    @Test func defaultsToOffWhenUnset() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.key)
        defaults.removeObject(forKey: Self.key)
        defer { restore(previous) }

        #expect(SessionAutoPlaySettings.isEnabled == false)
    }

    @Test func roundTripsTheToggle() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.key)
        defer { restore(previous) }

        SessionAutoPlaySettings.isEnabled = true
        #expect(SessionAutoPlaySettings.isEnabled == true)
        #expect(defaults.bool(forKey: Self.key) == true)

        SessionAutoPlaySettings.isEnabled = false
        #expect(SessionAutoPlaySettings.isEnabled == false)
        #expect(defaults.bool(forKey: Self.key) == false)
    }

    private func restore(_ previous: Any?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
