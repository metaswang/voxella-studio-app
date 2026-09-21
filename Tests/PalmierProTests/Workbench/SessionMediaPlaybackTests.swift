import Foundation
import Testing
@testable import PalmierPro

@Suite("Session media playback subtitles")
@MainActor
struct SessionMediaPlaybackTests {
    @Test func seekBarKeepsEndpointThumbsInsideTheHitTarget() {
        let width: CGFloat = 100
        let thumbSize: CGFloat = 12

        #expect(SessionPlaybackSeekBar.thumbPosition(for: 0, width: width, thumbSize: thumbSize) == 6)
        #expect(SessionPlaybackSeekBar.thumbPosition(for: 1, width: width, thumbSize: thumbSize) == 94)
        #expect(SessionPlaybackSeekBar.normalizedProgress(at: 6, width: width, thumbSize: thumbSize) == 0)
        #expect(SessionPlaybackSeekBar.normalizedProgress(at: 50, width: width, thumbSize: thumbSize) == 0.5)
        #expect(SessionPlaybackSeekBar.normalizedProgress(at: 94, width: width, thumbSize: thumbSize) == 1)
    }

    @Test func returnsTheCueAtItsStartAndUntilItsEnd() {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: SubtitleTrack(
                sourceLanguage: "en",
                language: "en",
                cues: [Self.cue(id: 1, text: "Hello", start: 1, end: 2)]
            ),
            translationTracks: []
        )

        #expect(playback.activeSubtitleText(at: 1) == "Hello")
        #expect(playback.activeSubtitleText(at: 1.99) == "Hello")
        #expect(playback.activeSubtitleText(at: 2) == nil)
    }

    @Test func returnsNoTextDuringCueGapsOrForEmptyCues() {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: SubtitleTrack(
                sourceLanguage: "en",
                language: "en",
                cues: [
                    Self.cue(id: 1, text: "First", start: 0, end: 1),
                    Self.cue(id: 2, text: "   ", start: 2, end: 3),
                    Self.cue(id: 3, text: "Third", start: 4, end: 5),
                ]
            ),
            translationTracks: []
        )

        #expect(playback.activeSubtitleText(at: 1.5) == nil)
        #expect(playback.activeSubtitleText(at: 2.5) == nil)
        #expect(playback.activeSubtitleText(at: 4.5) == "Third")
    }

    @Test func usesTheSelectedTranslationTrack() {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: SubtitleTrack(
                sourceLanguage: "en",
                language: "en",
                cues: [Self.cue(id: 1, text: "Hello", start: 0, end: 2)]
            ),
            translationTracks: [
                WorkbenchTranslationTrack(
                    languageCode: "zh-Hans",
                    track: SubtitleTrack(
                        sourceLanguage: "zh-Hans",
                        language: "zh-Hans",
                        cues: [Self.cue(id: 2, text: "你好", start: 0, end: 2)]
                    )
                ),
            ]
        )
        playback.subtitleMode = .translation("zh-Hans")

        #expect(playback.activeSubtitleText(at: 1) == "你好")
    }

    @Test func ccToggleRestoresTheSelectedTranslationTrack() {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: SubtitleTrack(
                sourceLanguage: "en",
                language: "en",
                cues: [Self.cue(id: 1, text: "Hello", start: 0, end: 2)]
            ),
            translationTracks: [
                WorkbenchTranslationTrack(
                    languageCode: "zh-Hans",
                    track: SubtitleTrack(
                        sourceLanguage: "zh-Hans",
                        language: "zh-Hans",
                        cues: [Self.cue(id: 2, text: "你好", start: 0, end: 2)]
                    )
                ),
            ]
        )
        playback.selectSubtitleMode(.translation("zh-Hans"))

        playback.toggleSubtitles()
        #expect(playback.subtitleMode == .off)
        #expect(playback.activeSubtitleText(at: 1) == nil)

        playback.toggleSubtitles()
        #expect(playback.subtitleMode == .translation("zh-Hans"))
        #expect(playback.activeSubtitleText(at: 1) == "你好")
    }

    private static func cue(id: Int, text: String, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(
            id: id,
            sourceIDs: [],
            text: text,
            start: start,
            end: end,
            speaker: nil
        )
    }
}
