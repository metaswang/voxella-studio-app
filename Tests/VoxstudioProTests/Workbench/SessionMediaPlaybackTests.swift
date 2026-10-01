import Foundation
import Testing
@testable import VoxstudioPro

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
        playback.selectSubtitleMode(.translation("zh-Hans"))

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

    @Test func missingTranslationFallsBackAndRestoresWhenTracksReturn() {
        let playback = SessionPlaybackController()
        let original = Self.track(language: "en", text: "Hello")
        let translation = WorkbenchTranslationTrack(
            languageCode: "zh-Hans", track: Self.track(language: "zh-Hans", text: "你好")
        )
        playback.configureSubtitles(subtitleTrack: original, translationTracks: [translation])
        playback.selectSubtitleMode(.translation("zh-Hans"))
        playback.configureSubtitles(subtitleTrack: original, translationTracks: [])

        #expect(playback.subtitleMode == .original)
        #expect(playback.activeSubtitleText(at: 1) == "Hello")
        playback.configureSubtitles(subtitleTrack: original, translationTracks: [translation])
        #expect(playback.subtitleMode == .translation("zh-Hans"))
        #expect(playback.activeSubtitleText(at: 1) == "你好")
    }

    @Test func subtitlesArrivingAfterMediaLoadAreEnabled() async {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(subtitleTrack: nil, translationTracks: [])
        await playback.load(url: nil, showsVideoCanvas: false)
        #expect(playback.subtitleMode == .off)

        playback.configureSubtitles(
            subtitleTrack: Self.track(language: "en", text: "Hello"), translationTracks: []
        )
        #expect(playback.subtitleMode == .original)
        #expect(playback.activeSubtitleText(at: 1) == "Hello")
    }

    @Test func explicitOffSurvivesTrackChangesAndReload() async {
        let playback = SessionPlaybackController()
        let original = Self.track(language: "en", text: "Hello")
        playback.configureSubtitles(subtitleTrack: original, translationTracks: [])
        playback.selectSubtitleMode(.off)
        playback.configureSubtitles(subtitleTrack: nil, translationTracks: [])
        playback.configureSubtitles(subtitleTrack: original, translationTracks: [])
        await playback.load(url: nil, showsVideoCanvas: false)

        #expect(playback.subtitleMode == .off)
        #expect(playback.activeSubtitleText(at: 1) == nil)
        playback.toggleSubtitles()
        #expect(playback.subtitleMode == .original)
    }

    @Test func translationOnlyTracksUseAnAvailableLanguage() {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: nil,
            translationTracks: [WorkbenchTranslationTrack(
                languageCode: "zh-Hans", track: Self.track(language: "zh-Hans", text: "你好")
            )]
        )
        #expect(playback.subtitleMode == .translation("zh-Hans"))
        #expect(playback.activeSubtitleText(at: 1) == "你好")
    }

    @Test func selectedTranslationSurvivesReload() async {
        let playback = SessionPlaybackController()
        playback.configureSubtitles(
            subtitleTrack: Self.track(language: "en", text: "Hello"),
            translationTracks: [WorkbenchTranslationTrack(
                languageCode: "zh-Hans", track: Self.track(language: "zh-Hans", text: "你好")
            )]
        )
        playback.selectSubtitleMode(.translation("zh-Hans"))
        await playback.load(url: nil, showsVideoCanvas: false)
        #expect(playback.subtitleMode == .translation("zh-Hans"))
    }

    private static func track(language: String, text: String) -> SubtitleTrack {
        SubtitleTrack(
            sourceLanguage: language, language: language,
            cues: [Self.cue(id: 1, text: text, start: 0, end: 2)]
        )
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
