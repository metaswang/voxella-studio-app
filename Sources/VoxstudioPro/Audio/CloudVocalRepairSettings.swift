import Foundation

enum CloudVocalRepairSettings {
    private static let enabledKey = "voxella.cloudVocalRepair.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
