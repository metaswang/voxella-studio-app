import Foundation

@MainActor
final class AudioPlaybackCoordinator {
    static let shared = AudioPlaybackCoordinator()

    private var activeID: String?
    private var stopActivePlayback: (() -> Void)?

    func begin(id: String, stop: @escaping () -> Void) {
        guard activeID != id else { return }
        stopActivePlayback?()
        activeID = id
        stopActivePlayback = stop
    }

    func end(id: String) {
        guard activeID == id else { return }
        activeID = nil
        stopActivePlayback = nil
    }
}
