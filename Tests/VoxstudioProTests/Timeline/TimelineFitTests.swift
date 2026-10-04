import Testing
@testable import VoxstudioPro

@Suite("Timeline default fit")
@MainActor
struct TimelineFitTests {
    @Test func defaultFitsTheFullDurationInsteadOfUsingMinimumZoom() {
        let editor = EditorViewModel()
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 18000)])]
        editor.updateTimelineViewport(width: 1200)
        #expect(abs(editor.zoomScale * 18000 - 1140) < 0.01)
        #expect(editor.zoomScale > editor.minZoomScale * 2)
        #expect(editor.timelineScrollRestoreX == 0)
    }

    @Test func resizeAndFirstImportFollowFitUntilUserZooms() {
        let editor = EditorViewModel()
        editor.updateTimelineViewport(width: 1200)
        #expect(editor.zoomScale == Defaults.pixelsPerFrame)
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 9000)])]
        editor.updateTimelineViewport(width: 1200)
        #expect(editor.timelineAutoFit)
        editor.updateTimelineViewport(width: 600)
        #expect(abs(editor.zoomScale * 9000 - 570) < 0.01)
        editor.zoomScale *= 2
        let manual = editor.zoomScale
        editor.updateTimelineViewport(width: 1000)
        #expect(!editor.timelineAutoFit)
        #expect(editor.zoomScale == manual)
        editor.fitTimelineToViewport()
        #expect(editor.timelineAutoFit)
        #expect(abs(editor.zoomScale * 9000 - 950) < 0.01)
    }

    @Test func savedManualZoomSurvivesReopeningAndSwitching() {
        let editor = EditorViewModel()
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 18000)])]
        editor.updateTimelineViewport(width: 1200)
        editor.zoomScale = 2
        let file = editor.projectFileSnapshot()
        let restored = EditorViewModel(); restored.applyProjectFile(file)
        restored.updateTimelineViewport(width: 1200)
        #expect(restored.zoomScale == 2)
        #expect(!restored.timelineAutoFit)
    }

    @Test func legacyMinimumMigratesToFitButLegacyManualZoomRemains() {
        let editor = EditorViewModel()
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 18000)])])
        let oldMinimum = (1200 - Double(Layout.trackHeaderWidth)) / (18000 * Zoom.fitAllBuffer)
        editor.applyProjectFile(ProjectFile(timelines: [timeline], viewStates: [timeline.id: TimelineViewState(zoomScale: oldMinimum)]))
        editor.updateTimelineViewport(width: 1200)
        #expect(editor.timelineAutoFit)
        #expect(abs(editor.zoomScale * 18000 - 1140) < 0.01)
        timeline.id = "manual"
        editor.applyProjectFile(ProjectFile(timelines: [timeline], viewStates: [timeline.id: TimelineViewState(zoomScale: 2)]))
        #expect(editor.zoomScale == 2)
        #expect(!editor.timelineAutoFit)
    }
}
