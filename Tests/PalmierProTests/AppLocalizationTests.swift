import Foundation
import Testing
@testable import PalmierPro

@Suite("App localization")
@MainActor
struct AppLocalizationTests {
    @Test func systemLanguageUsesOnlyTheFirstPreferredLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["it-IT", "zh-Hans"]
        )

        #expect(localization.activeIdentifier == "en")
    }

    @Test func systemLanguageMatchesRegionalVariants() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["zh-CN"]
        )

        #expect(localization.activeIdentifier == "zh-Hans")
    }

    @Test func explicitSupportedLanguageOverridesTheSystemLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ja", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["en"]
        )

        #expect(localization.selection == .language("ja"))
        #expect(localization.activeIdentifier == "ja")
    }

    @Test func unsupportedSavedLanguageResetsToSystemLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ko", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["en"]
        )

        #expect(localization.selection == .system)
        #expect(defaults.string(forKey: AppLanguage.defaultsKey) == "system")
    }

    @Test func missingLocalizedKeyFallsBackToEnglishResource() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("fr", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["fr"]
        )

        #expect(localization.string(key: "AI access") == "AI access")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppLocalizationTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
