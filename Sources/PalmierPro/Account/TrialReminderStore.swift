import Foundation

actor TrialReminderStore {
    private static let reminderPrefix = "voxella.trial-reminder.presented."
    private static let startedPrefix = "voxella.trial-started.presented."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(userID: UUID, endsAt: Date) -> String {
        "\(reminderPrefix)\(userID.uuidString).\(Int64(endsAt.timeIntervalSince1970))"
    }

    static func startedKey(userID: UUID, endsAt: Date) -> String {
        "\(startedPrefix)\(userID.uuidString).\(Int64(endsAt.timeIntervalSince1970))"
    }

    func claim(key: String) -> Bool {
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    func remove(key: String) {
        defaults.removeObject(forKey: key)
    }
}
