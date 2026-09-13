import Foundation
import Testing
@testable import PalmierPro

@Suite("AppKit feature wall playback")
@MainActor
struct FeatureWallPlaybackTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func activeAppKitHostStartsWithoutASwiftUIScene() {
        let playback = FeatureWallPlayback()
        playback.appear(applicationActive: true, reduceMotion: false, at: origin)
        #expect(playback.isRunning)
        #expect(playback.elapsed(at: origin.addingTimeInterval(2)) == 2)
    }

    @Test func activationAfterPresentationStartsPlayback() {
        let playback = FeatureWallPlayback()
        playback.appear(applicationActive: false, reduceMotion: false, at: origin)
        #expect(!playback.isRunning)
        playback.setApplicationActive(true, at: origin.addingTimeInterval(4))
        #expect(playback.isRunning)
        #expect(playback.elapsed(at: origin.addingTimeInterval(6)) == 2)
    }

    @Test func backgroundTimeDoesNotAdvanceCards() {
        let playback = FeatureWallPlayback()
        playback.appear(applicationActive: true, reduceMotion: false, at: origin)
        playback.setApplicationActive(false, at: origin.addingTimeInterval(2))
        #expect(!playback.isRunning)
        #expect(playback.elapsed(at: origin.addingTimeInterval(20)) == 2)
        playback.setApplicationActive(true, at: origin.addingTimeInterval(20))
        #expect(playback.elapsed(at: origin.addingTimeInterval(23)) == 5)
    }

    @Test func manualPauseSurvivesReactivationAndResumesInPlace() {
        let playback = FeatureWallPlayback()
        playback.appear(applicationActive: true, reduceMotion: false, at: origin)
        playback.togglePause(at: origin.addingTimeInterval(2))
        playback.setApplicationActive(false, at: origin.addingTimeInterval(3))
        playback.setApplicationActive(true, at: origin.addingTimeInterval(4))
        #expect(!playback.isRunning)
        #expect(playback.elapsed(at: origin.addingTimeInterval(10)) == 2)
        playback.togglePause(at: origin.addingTimeInterval(10))
        #expect(playback.elapsed(at: origin.addingTimeInterval(11)) == 3)
    }

    @Test func reduceMotionAndDismissalStopPlayback() {
        let playback = FeatureWallPlayback()
        playback.appear(applicationActive: true, reduceMotion: true, at: origin)
        #expect(!playback.isRunning)
        playback.setReduceMotion(false, at: origin.addingTimeInterval(2))
        #expect(playback.isRunning)
        playback.disappear(at: origin.addingTimeInterval(4))
        playback.setApplicationActive(true, at: origin.addingTimeInterval(5))
        #expect(!playback.isRunning)
        #expect(playback.elapsed(at: origin.addingTimeInterval(10)) == 2)
    }
}
