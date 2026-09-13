import AppKit
import Foundation
import Observation

enum AppAppearanceChoice: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    static let defaultsKey = "appAppearance"

    var id: String { rawValue }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    static func stored(in defaults: UserDefaults) -> AppAppearanceChoice {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let choice = AppAppearanceChoice(rawValue: rawValue) else {
            return .system
        }
        return choice
    }
}

@MainActor @Observable
final class AppAppearancePreferences {
    static let shared = AppAppearancePreferences()

    var selection: AppAppearanceChoice {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: AppAppearanceChoice.defaultsKey)
            applyAppearance(selection.appKitAppearance)
        }
    }

    private let defaults: UserDefaults
    private let applyAppearance: (NSAppearance?) -> Void

    init(
        defaults: UserDefaults = .standard,
        applyAppearance: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 }
    ) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance

        let storedSelection = AppAppearanceChoice.stored(in: defaults)
        selection = storedSelection
        if defaults.string(forKey: AppAppearanceChoice.defaultsKey) != storedSelection.rawValue {
            defaults.set(storedSelection.rawValue, forKey: AppAppearanceChoice.defaultsKey)
        }
        applyAppearance(storedSelection.appKitAppearance)
    }
}
