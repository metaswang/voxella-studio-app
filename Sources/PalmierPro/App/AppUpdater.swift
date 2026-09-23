import AppKit
import Foundation
import Observation

#if SPARKLE_UPDATES
import Sparkle
#endif

enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case unsupportedSystem(AppUpdateRelease)
    case failed(String)
}

@MainActor @Observable
final class AppUpdater: NSObject, NSMenuItemValidation {
    static let shared = AppUpdater()
    
    static let automaticCheckDefaultsKey = "voxstudio.updates.automatically-checks"
    static let lastCheckDefaultsKey = "voxstudio.updates.last-check"
    static let automaticCheckInterval: TimeInterval = 86_400
    
    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var status: AppUpdateStatus = .idle
    
#if SPARKLE_UPDATES && !MAC_APP_STORE
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
#else
    @ObservationIgnored private let feedURL: URL?
    @ObservationIgnored private let currentBuild: String
    @ObservationIgnored private let currentShortVersion: String
    @ObservationIgnored private let operatingSystemVersion: OperatingSystemVersion
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetcher: any AppUpdateFetching
    @ObservationIgnored private let opener: any AppUpdateOpening
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var latestRelease: AppUpdateRelease?
#endif
    
    override convenience init() {
#if SPARKLE_UPDATES && !MAC_APP_STORE
        self.init(sparkle: ())
#else
        self.init(
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            currentShortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            defaults: .standard,
            fetcher: URLSessionAppUpdateFetcher(),
            opener: WorkspaceAppUpdateOpener()
        )
#endif
    }
    
#if SPARKLE_UPDATES && !MAC_APP_STORE
    private init(sparkle: Void) {
        super.init()
        let defaults = UserDefaults.standard
        automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticCheckDefaultsKey) as? Bool ?? true
    }
#else
    init(
        feedURL: String?,
        currentBuild: String,
        currentShortVersion: String,
        operatingSystemVersion: OperatingSystemVersion,
        defaults: UserDefaults,
        fetcher: any AppUpdateFetching,
        opener: any AppUpdateOpening,
        now: @escaping () -> Date = Date.init
    ) {
        self.feedURL = feedURL.flatMap(URL.init(string:))
        self.currentBuild = currentBuild
        self.currentShortVersion = currentShortVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.defaults = defaults
        self.fetcher = fetcher
        self.opener = opener
        self.now = now
        super.init()
        automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticCheckDefaultsKey) as? Bool ?? true
    }
#endif
    
    func start() {
#if MAC_APP_STORE
        isAvailable = false
        canCheckForUpdates = false
#elseif SPARKLE_UPDATES
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        isAvailable = true
        canCheckForUpdates = true
#else
        guard Bundle.main.bundleURL.pathExtension == "app" || feedURL != nil else { return }
        guard feedURL != nil, !currentBuild.isEmpty else { return }
        isAvailable = true
        canCheckForUpdates = true
        if automaticallyChecksForUpdates {
            checkForUpdatesIfNeeded()
        }
#endif
    }
    
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
#if SPARKLE_UPDATES && !MAC_APP_STORE
        updaterController?.checkForUpdates(nil)
#else
        performCheck()
#endif
    }
    
    @objc func checkForUpdates(_ sender: Any?) {
        checkForUpdates()
    }
    
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: Self.automaticCheckDefaultsKey)
#if SPARKLE_UPDATES && !MAC_APP_STORE
        updaterController?.updater.automaticallyChecksForUpdates = enabled
#else
        if enabled {
            checkForUpdatesIfNeeded()
        }
#endif
    }
    
    func openDownload() {
#if SPARKLE_UPDATES && !MAC_APP_STORE
        // When Sparkle is linked, updates install in-app; no manual download
        updaterController?.checkForUpdates(nil)
#else
        guard let latestRelease else { return }
        opener.open(latestRelease.downloadURL)
#endif
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates(_:)) ? canCheckForUpdates : true
    }
    
#if !SPARKLE_UPDATES || MAC_APP_STORE
    private func checkForUpdatesIfNeeded() {
        let lastCheck = defaults.object(forKey: Self.lastCheckDefaultsKey) as? Date
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return
        }
        performCheck()
    }
    
    private func performCheck() {
        guard let feedURL, canCheckForUpdates else { return }
        checkTask?.cancel()
        status = .checking
        let fetcher = fetcher
        let currentBuild = currentBuild
        let currentShortVersion = currentShortVersion
        let operatingSystemVersion = operatingSystemVersion
        checkTask = Task { [weak self] in
            do {
                let data = try await fetcher.data(from: feedURL)
                let feed = try AppcastFeed.parse(xml: data)
                let evaluation = feed.evaluation(
                    currentBuild: currentBuild,
                    currentShortVersion: currentShortVersion,
                    operatingSystemVersion: operatingSystemVersion
                )
                guard !Task.isCancelled else { return }
                self?.apply(evaluation)
            } catch is CancellationError {
                return
            } catch let error as AppcastFeedError {
                guard !Task.isCancelled else { return }
                self?.status = .failed(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed("Couldn't check for updates. Check your connection and try again.")
            }
        }
    }
    
    private func apply(_ evaluation: AppUpdateEvaluation) {
        defaults.set(now(), forKey: Self.lastCheckDefaultsKey)
        switch evaluation {
        case .upToDate:
            latestRelease = nil
            status = .upToDate
        case .available(let release):
            latestRelease = release
            status = .available(release)
        case .unsupportedSystem(let release):
            latestRelease = nil
            status = .unsupportedSystem(release)
        }
    }
#endif
}

protocol AppUpdateFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionAppUpdateFetcher: AppUpdateFetching {
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

protocol AppUpdateOpening: Sendable {
    func open(_ url: URL)
}

struct WorkspaceAppUpdateOpener: AppUpdateOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
