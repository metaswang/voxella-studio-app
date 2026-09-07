import Foundation

extension Notification.Name {
    static let listenTrackEnhanceDidUpdate = Notification.Name("voxella.listenTrackEnhanceDidUpdate")
}

struct ListenTrackEnhanceUpdate: Sendable {
    var masterURL: URL
    var listenURL: URL?
    var state: ListenEnhanceState
    var errorDescription: String?
}

/// Async post-stop listen-track jobs. Playback can start on master immediately;
/// when ready, observers switch to the listen URL.
actor ListenTrackEnhanceCoordinator {
    static let shared = ListenTrackEnhanceCoordinator()

    private var inFlight: [String: Task<ListenTrackEnhanceUpdate, Never>] = [:]
    private var latest: [String: ListenTrackEnhanceUpdate] = [:]

    func cachedUpdate(for masterURL: URL) -> ListenTrackEnhanceUpdate? {
        latest[key(for: masterURL)]
    }

    @discardableResult
    func enqueue(masterURL: URL, force: Bool = false) -> Task<ListenTrackEnhanceUpdate, Never> {
        let pathKey = key(for: masterURL)
        if !force, let existing = inFlight[pathKey] {
            return existing
        }
        if !force,
           let ready = latest[pathKey],
           ready.state == .ready,
           let listenURL = ready.listenURL,
           FileManager.default.fileExists(atPath: listenURL.path) {
            return Task { ready }
        }
        if !ListenEnhanceSettings.isEnabled {
            let skipped = ListenTrackEnhanceUpdate(
                masterURL: masterURL,
                listenURL: nil,
                state: .skipped,
                errorDescription: nil
            )
            latest[pathKey] = skipped
            return Task { skipped }
        }
        if !force, let existing = ListenTrackLocator.existingListenURL(forMaster: masterURL) {
            let ready = ListenTrackEnhanceUpdate(
                masterURL: masterURL,
                listenURL: existing,
                state: .ready,
                errorDescription: nil
            )
            latest[pathKey] = ready
            publish(ready)
            return Task { ready }
        }

        let pending = ListenTrackEnhanceUpdate(
            masterURL: masterURL,
            listenURL: nil,
            state: .pending,
            errorDescription: nil
        )
        latest[pathKey] = pending
        publish(pending)

        let task = Task<ListenTrackEnhanceUpdate, Never> {
            let update: ListenTrackEnhanceUpdate
            do {
                let result = try await ListenTrackEnhancer.enhance(masterURL: masterURL, force: force)
                update = ListenTrackEnhanceUpdate(
                    masterURL: masterURL,
                    listenURL: result.listenURL,
                    state: .ready,
                    errorDescription: nil
                )
            } catch is CancellationError {
                update = ListenTrackEnhanceUpdate(
                    masterURL: masterURL,
                    listenURL: nil,
                    state: .idle,
                    errorDescription: nil
                )
            } catch {
                Log.recording.warning(
                    "listen enhance failed master=\(masterURL.lastPathComponent) error=\(error.localizedDescription)"
                )
                update = ListenTrackEnhanceUpdate(
                    masterURL: masterURL,
                    listenURL: nil,
                    state: .failed,
                    errorDescription: error.localizedDescription
                )
            }
            await self.finish(key: pathKey, update: update)
            return update
        }
        inFlight[pathKey] = task
        return task
    }

    private func finish(key: String, update: ListenTrackEnhanceUpdate) {
        inFlight[key] = nil
        latest[key] = update
        publish(update)
    }

    private func publish(_ update: ListenTrackEnhanceUpdate) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .listenTrackEnhanceDidUpdate,
                object: nil,
                userInfo: [
                    "masterPath": update.masterURL.path,
                    "listenPath": update.listenURL?.path as Any,
                    "state": update.state.rawValue,
                ]
            )
            WorkbenchStore.shared.applyListenTrackUpdate(update)
        }
    }

    private func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
