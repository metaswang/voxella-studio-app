import Foundation

@MainActor
@Observable
final class VisualModelLoader {
    static let shared = VisualModelLoader()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var enabled = SearchIndexConfig.enabled
    private var transition: Task<Void, Never>?

    var state: State {
        #if BUNDLED_SPEECH
        switch LocalModelManager.shared.state(for: SearchIndexConfig.modelID) {
        case .notInstalled: .notInstalled
        case .queued: .preparing
        case .downloading(let fraction, _), .verifying(let fraction, _): .downloading(fraction)
        case .installed:
            MLXRuntime.isAvailable ? .ready : .failed(MLXRuntime.Unavailable().localizedDescription)
        case .failed(let message): .failed(message)
        }
        #else
        .failed(MLXRuntime.Unavailable().localizedDescription)
        #endif
    }

    var isReady: Bool { state == .ready }
    var embedder: VisualEmbedder? { enabled && isReady ? .weMM : nil }

    private init() {}

    func prepare() async {
        await LocalModelManager.shared.waitForInstallationRefresh()
    }

    func download() {
        LocalModelManager.shared.download(SearchIndexConfig.modelID)
    }

    func cancelDownload() {
        LocalModelManager.shared.cancel(SearchIndexConfig.modelID)
    }

    func setEnabled(_ value: Bool) {
        SearchIndexConfig.enabled = value
        enabled = value
        let previous = transition
        transition = Task {
            await previous?.value
            if enabled {
                await prepare()
                SearchIndexCoordinator.sweepAll()
            } else {
                await SearchIndexCoordinator.cancelAll()
            }
        }
    }
}
