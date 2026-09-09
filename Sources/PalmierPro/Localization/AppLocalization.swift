import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppLocalization {
    static let shared = AppLocalization()

    let activeIdentifier: String
    let activeLocale: Locale
    let availableLanguages: [AppLanguage]

    var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.id, forKey: AppLanguage.defaultsKey)
        }
    }

    var requiresRestart: Bool {
        (selection.identifier ?? systemIdentifier) != activeIdentifier
    }

    private let defaults: UserDefaults
    private let localizedBundle: Bundle
    private let englishBundle: Bundle
    private let systemIdentifier: String

    init(
        defaults: UserDefaults = .standard,
        resourceBundle: Bundle = BundledResource.bundle,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        let resources = Self.localizationResources(in: resourceBundle)
        let identifiers = resources.map(\.identifier)
        availableLanguages = identifiers.map(AppLanguage.language)
        let resolvedSystemIdentifier = Self.preferredIdentifier(
            in: resources,
            preferredLanguages: preferredLanguages
        )
        systemIdentifier = resolvedSystemIdentifier

        let storedLanguage = AppLanguage.stored(in: defaults)
        let validLanguage: AppLanguage
        if let identifier = storedLanguage.identifier, identifiers.contains(identifier) {
            validLanguage = .language(identifier)
        } else {
            validLanguage = .system
        }
        if defaults.string(forKey: AppLanguage.defaultsKey).map({ $0 != validLanguage.id }) == true {
            defaults.set(validLanguage.id, forKey: AppLanguage.defaultsKey)
        }

        selection = validLanguage
        let resolvedActiveIdentifier = validLanguage.identifier ?? resolvedSystemIdentifier
        activeIdentifier = resolvedActiveIdentifier
        activeLocale = Locale(identifier: resolvedActiveIdentifier)
        localizedBundle = resources.first { $0.identifier == resolvedActiveIdentifier }?.bundle
            ?? resources.first { $0.identifier == "en" }?.bundle
            ?? resourceBundle
        englishBundle = resources.first { $0.identifier == "en" }?.bundle ?? resourceBundle
    }

    func string(key: String) -> String {
        let localized = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
        guard localized == key else { return localized }
        return englishBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func displayName(for language: AppLanguage) -> String {
        guard let identifier = language.identifier else {
            return string(key: L10n.key("System Language"))
        }
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    private struct LocalizationResource {
        let identifier: String
        let bundle: Bundle
    }

    private static func localizationResources(in bundle: Bundle) -> [LocalizationResource] {
        let rootURLs = bundle.localizations
            .filter { $0 != "Base" }
            .compactMap { identifier in
                bundle.url(forResource: identifier, withExtension: "lproj")
            }
        let nestedURLs = bundle.urls(forResourcesWithExtension: "lproj", subdirectory: "Localization") ?? []

        let resources = (rootURLs + nestedURLs).reduce(into: [String: LocalizationResource]()) { result, url in
            guard let localizationBundle = Bundle(url: url) else { return }
            let identifier = Locale(identifier: url.deletingPathExtension().lastPathComponent).identifier
            result[identifier] = LocalizationResource(identifier: identifier, bundle: localizationBundle)
        }

        return resources.values
            .sorted { lhs, rhs in
                let lhsName = Locale(identifier: lhs.identifier)
                    .localizedString(forIdentifier: lhs.identifier) ?? lhs.identifier
                let rhsName = Locale(identifier: rhs.identifier)
                    .localizedString(forIdentifier: rhs.identifier) ?? rhs.identifier
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
    }

    private static func preferredIdentifier(
        in resources: [LocalizationResource],
        preferredLanguages: [String]
    ) -> String {
        guard let primaryLanguage = preferredLanguages.first else { return "en" }
        return Bundle.preferredLocalizations(
            from: resources.map(\.identifier),
            forPreferences: [primaryLanguage]
        ).first.map { Locale(identifier: $0).identifier } ?? "en"
    }
}

extension View {
    func appLocalization() -> some View {
        environment(\.locale, AppLocalization.shared.activeLocale)
    }
}

@MainActor
enum L10n {
    nonisolated static func key(_ value: StaticString) -> String {
        value.description
    }

    static func string(_ key: String) -> String {
        AppLocalization.shared.string(key: key)
    }

    static func string(key: String) -> String {
        AppLocalization.shared.string(key: key)
    }

}
