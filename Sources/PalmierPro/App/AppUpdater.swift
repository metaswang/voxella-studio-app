import AppKit
import Observation

#if SPARKLE_UPDATES
import Sparkle
#endif

@MainActor
protocol AppUpdateControlling: AnyObject {
    var isAvailable: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyInstallsUpdates: Bool { get }

    func start()
    func checkForUpdates()
    func setAutomaticallyInstallsUpdates(_ enabled: Bool)
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyInstallsUpdates: Bool { get }
    var stateDidChange: (() -> Void)? { get set }

    func start()
    func checkForUpdates()
    func setAutomaticallyInstallsUpdates(_ enabled: Bool)
}

@MainActor @Observable
final class AppUpdater: NSObject, AppUpdateControlling, NSMenuItemValidation {
    static let shared = AppUpdater()

    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyInstallsUpdates = false

    @ObservationIgnored private let driverFactory: @MainActor () -> (any AppUpdateDriving)?
    @ObservationIgnored private var driver: (any AppUpdateDriving)?

    override convenience init() {
        self.init(driverFactory: AppUpdater.makeDefaultDriver)
    }

    init(driverFactory: @escaping @MainActor () -> (any AppUpdateDriving)?) {
        self.driverFactory = driverFactory
        super.init()
    }

    func start() {
        guard driver == nil, let driver = driverFactory() else { return }
        self.driver = driver
        driver.stateDidChange = { [weak self, weak driver] in
            guard let self, let driver else { return }
            self.refreshState(from: driver)
        }
        driver.start()
        isAvailable = true
        refreshState(from: driver)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver?.checkForUpdates()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        checkForUpdates()
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        guard let driver else { return }
        driver.setAutomaticallyInstallsUpdates(enabled)
        refreshState(from: driver)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates(_:)) ? canCheckForUpdates : true
    }

    private func refreshState(from driver: any AppUpdateDriving) {
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyInstallsUpdates = driver.automaticallyInstallsUpdates
    }

    private static func makeDefaultDriver() -> (any AppUpdateDriving)? {
#if SPARKLE_UPDATES
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else { return nil }
        return SparkleUpdateDriver()
#else
        return nil
#endif
    }
}

#if SPARKLE_UPDATES
@MainActor
private final class SparkleUpdateDriver: AppUpdateDriving {
    var stateDidChange: (() -> Void)?

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var canCheckObservation: NSKeyValueObservation?

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        controller.updater.automaticallyChecksForUpdates
    }

    var automaticallyInstallsUpdates: Bool {
        controller.updater.automaticallyDownloadsUpdates
    }

    func start() {
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard change.newValue != nil else { return }
            Task { @MainActor [weak self] in
                self?.stateDidChange?()
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}
#endif
