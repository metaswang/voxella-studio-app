import AppKit
import Testing
@testable import PalmierPro

@MainActor
private final class TestUpdateDriver: AppUpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyInstallsUpdates = true
    var stateDidChange: (() -> Void)?
    private(set) var checkCount = 0

    func start() {}

    func checkForUpdates() {
        checkCount += 1
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        automaticallyInstallsUpdates = enabled
        stateDidChange?()
    }
}

@Suite("App updates")
@MainActor
struct AppUpdaterTests {
    @Test func unavailableUpdaterIsANoOp() {
        let updater = AppUpdater(driverFactory: { nil })

        updater.start()
        updater.checkForUpdates()
        updater.setAutomaticallyInstallsUpdates(true)

        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticallyInstallsUpdates)
    }

    @Test func disablingAutomaticInstallationKeepsScheduledChecksEnabled() {
        let driver = TestUpdateDriver()
        let updater = AppUpdater(driverFactory: { driver })
        updater.start()

        updater.setAutomaticallyInstallsUpdates(false)

        #expect(!updater.automaticallyInstallsUpdates)
        #expect(driver.automaticallyChecksForUpdates)
    }

    @Test func checkAndMenuValidationUseTheSameAvailabilityState() {
        let driver = TestUpdateDriver()
        let updater = AppUpdater(driverFactory: { driver })
        updater.start()
        let menuItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(AppUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )

        #expect(updater.validateMenuItem(menuItem))
        updater.checkForUpdates()
        #expect(driver.checkCount == 1)

        driver.canCheckForUpdates = false
        driver.stateDidChange?()
        #expect(!updater.validateMenuItem(menuItem))
        updater.checkForUpdates()
        #expect(driver.checkCount == 1)
    }

    @Test func mainMenuMatchesTheBuildDistribution() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenuBuilder.buildMenu()
        let appMenu = try #require(mainMenu.items.first?.submenu)
        let updateItem = appMenu.items.first { $0.title == "Check for Updates…" }

#if SPARKLE_UPDATES
        #expect(updateItem != nil)
        #expect(updateItem?.target === AppUpdater.shared)
#else
        #expect(updateItem == nil)
#endif
    }
}
