import AppKit
import Foundation
import Testing
@testable import VoxstudioPro

private struct FixtureFetcher: AppUpdateFetching, @unchecked Sendable {
    var result: Result<Data, Error>

    func data(from url: URL) async throws -> Data {
        try result.get()
    }
}

private final class RecordingOpener: AppUpdateOpening, @unchecked Sendable {
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

@MainActor
private func makeUpdater(
    feedURL: String?,
    currentBuild: String = "10",
    currentShortVersion: String = "1.0.0",
    operatingSystemVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0),
    fetcher: FixtureFetcher,
    opener: RecordingOpener = RecordingOpener(),
    automaticallyChecks: Bool = false
) -> (AppUpdater, RecordingOpener) {
    let suite = "AppUpdaterTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(automaticallyChecks, forKey: AppUpdater.automaticCheckDefaultsKey)
    let updater = AppUpdater(
        feedURL: feedURL,
        currentBuild: currentBuild,
        currentShortVersion: currentShortVersion,
        operatingSystemVersion: operatingSystemVersion,
        defaults: defaults,
        fetcher: fetcher,
        opener: opener
    )
    return (updater, opener)
}

@MainActor
private func waitForStatus(_ updater: AppUpdater) async {
    for _ in 0..<40 {
        if updater.status != .idle && updater.status != .checking { return }
        try? await Task.sleep(for: .milliseconds(25))
    }
}

@Suite("App updates")
@MainActor
struct AppUpdaterTests {
    @Test func unavailableUpdaterIsANoOp() {
        let (updater, opener) = makeUpdater(
            feedURL: nil,
            currentBuild: "1",
            fetcher: FixtureFetcher(result: .failure(URLError(.notConnectedToInternet)))
        )

        updater.start()
        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)

        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.status == .idle)
        #expect(opener.opened.isEmpty)
    }

    @Test func automaticCheckToggleDoesNotInstall() async {
        let (updater, opener) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            currentBuild: "92",
            currentShortVersion: "7.0.12",
            fetcher: FixtureFetcher(result: .success(Self.appcast(build: "92", version: "7.0.12")))
        )
        updater.start()
        updater.setAutomaticallyChecksForUpdates(false)
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(opener.opened.isEmpty)
    }

    @Test func checkAndMenuValidationUseTheSameAvailabilityState() {
        let (updater, _) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            currentBuild: "92",
            currentShortVersion: "7.0.12",
            fetcher: FixtureFetcher(result: .success(Self.appcast(build: "92", version: "7.0.12")))
        )
        updater.start()
        let menuItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(AppUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )

        #expect(updater.validateMenuItem(menuItem))
        updater.checkForUpdates()
    }

    @Test func newerBuildShowsDownloadWithoutOpeningIt() async {
        let opener = RecordingOpener()
        let (updater, _) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            fetcher: FixtureFetcher(result: .success(Self.appcast(build: "11", version: "1.0.1"))),
            opener: opener
        )
        updater.start()
        updater.checkForUpdates()
        await waitForStatus(updater)
        guard case .available(let release) = updater.status else {
            Issue.record("expected available update, got \(updater.status)")
            return
        }
        #expect(release.shortVersion == "1.0.1")
        #expect(opener.opened.isEmpty)
        updater.openDownload()
        #expect(opener.opened == [release.downloadURL])
    }

    @Test func offlineCheckSurfacesAConnectionError() async {
        let (updater, _) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            fetcher: FixtureFetcher(result: .failure(URLError(.notConnectedToInternet)))
        )
        updater.start()
        updater.checkForUpdates()
        await waitForStatus(updater)
        guard case .failed(let message) = updater.status else {
            Issue.record("expected failed status, got \(updater.status)")
            return
        }
        #expect(message.contains("connection"))
    }

    @Test func malformedAppcastIsReported() async {
        let (updater, _) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            fetcher: FixtureFetcher(result: .success(Data("<not-xml".utf8)))
        )
        updater.start()
        updater.checkForUpdates()
        await waitForStatus(updater)
        guard case .failed = updater.status else {
            Issue.record("expected failed status, got \(updater.status)")
            return
        }
    }

    @Test func minimumSystemVersionBlocksDownload() async {
        let opener = RecordingOpener()
        let (updater, _) = makeUpdater(
            feedURL: "https://example.invalid/appcast.xml",
            fetcher: FixtureFetcher(result: .success(Self.appcast(build: "11", version: "1.0.1", minimum: "26.0"))),
            opener: opener
        )
        updater.start()
        updater.checkForUpdates()
        await waitForStatus(updater)
        guard case .unsupportedSystem = updater.status else {
            Issue.record("expected unsupported system, got \(updater.status)")
            return
        }
        updater.openDownload()
        #expect(opener.opened.isEmpty)
    }

    @Test func mainMenuMatchesTheBuildDistribution() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenuBuilder.buildMenu()
        let appMenu = try #require(mainMenu.items.first?.submenu)
        let updateItem = appMenu.items.first { $0.title == "Check for Updates…" }

#if MAC_APP_STORE
        #expect(updateItem == nil)
#else
        #expect(updateItem != nil)
        #expect(updateItem?.target === AppUpdater.shared)
#endif
    }

    @Test func appcastParserReadsLatestCompatibleItem() throws {
        let feed = try AppcastFeed.parse(xml: Self.appcast(build: "11", version: "1.0.1"))
        let evaluation = feed.evaluation(
            currentBuild: "10",
            currentShortVersion: "1.0.0",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        guard case .available(let release) = evaluation else {
            Issue.record("expected available, got \(evaluation)")
            return
        }
        #expect(release.build == "11")
        #expect(release.downloadURL.absoluteString.hasSuffix("VoxStudio.dmg"))
    }

    private static func appcast(build: String, version: String, minimum: String = "15.0") -> Data {
        Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                <channel>
                    <item>
                        <title>Version \(version)</title>
                        <sparkle:version>\(build)</sparkle:version>
                        <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                        <sparkle:minimumSystemVersion>\(minimum)</sparkle:minimumSystemVersion>
                        <enclosure url="https://example.invalid/VoxStudio.dmg" length="1" type="application/octet-stream"/>
                    </item>
                </channel>
            </rss>
            """.utf8
        )
    }
}
