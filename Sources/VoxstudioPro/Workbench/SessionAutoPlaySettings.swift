import Foundation

/// Whether opening a session starts playback on its own. Off by default.
enum SessionAutoPlaySettings {
    private static let enabledKey = "voxella.session.autoPlayOnOpen"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
