import Testing
@testable import PalmierPro

@Suite("Audio playback coordination")
struct AudioPlaybackTests {
    @Test @MainActor
    func startingAnotherPreviewStopsTheActivePlayback() {
        let coordinator = AudioPlaybackCoordinator.shared
        var stopped: [String] = []

        coordinator.begin(id: "first") { stopped.append("first") }
        coordinator.begin(id: "second") { stopped.append("second") }
        coordinator.end(id: "second")

        #expect(stopped == ["first"])
    }
}
