import AppKit
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("App appearance")
@MainActor
struct AppAppearanceTests {
    @Test func missingPreferenceDefaultsToSystem() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppAppearancePreferences(defaults: defaults, applyAppearance: { _ in })

        #expect(preferences.selection == .system)
        #expect(defaults.string(forKey: AppAppearanceChoice.defaultsKey) == "system")
    }

    @Test func invalidPreferenceResetsToSystem() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: AppAppearanceChoice.defaultsKey)

        let preferences = AppAppearancePreferences(defaults: defaults, applyAppearance: { _ in })

        #expect(preferences.selection == .system)
        #expect(defaults.string(forKey: AppAppearanceChoice.defaultsKey) == "system")
    }

    @Test(arguments: AppAppearanceChoice.allCases)
    func savedPreferenceLoads(choice: AppAppearanceChoice) {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(choice.rawValue, forKey: AppAppearanceChoice.defaultsKey)

        let preferences = AppAppearancePreferences(defaults: defaults, applyAppearance: { _ in })

        #expect(preferences.selection == choice)
    }

    @Test func selectionPersistsAndAppliesItsAppearance() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var appliedAppearances: [NSAppearance?] = []
        let preferences = AppAppearancePreferences(defaults: defaults) {
            appliedAppearances.append($0)
        }

        preferences.selection = .light
        #expect(defaults.string(forKey: AppAppearanceChoice.defaultsKey) == "light")
        #expect(appliedAppearances.last??.name == .aqua)

        preferences.selection = .system
        #expect(defaults.string(forKey: AppAppearanceChoice.defaultsKey) == "system")
        #expect(appliedAppearances.last! == nil)
    }

    @Test func choicesMapToExpectedAppKitAppearances() {
        #expect(AppAppearanceChoice.dark.appKitAppearance?.name == .darkAqua)
        #expect(AppAppearanceChoice.light.appKitAppearance?.name == .aqua)
        #expect(AppAppearanceChoice.system.appKitAppearance == nil)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
