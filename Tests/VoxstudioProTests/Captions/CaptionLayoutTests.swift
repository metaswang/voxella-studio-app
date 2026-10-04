import AppKit
import CoreImage
import CoreText
import ImageIO
import Testing
@testable import VoxstudioPro

@Suite("Caption source layout")
@MainActor
struct CaptionLayoutTests {
    private let source = CaptionSourceContext(audioTrackId: "audio", placementId: "placement")

    private func caption(_ id: String, text: String, order: Int, source: CaptionSourceContext? = nil) -> Clip {
        var clip = Fixtures.clip(id: id, mediaRef: "", mediaType: .text, start: 0, duration: 300)
        clip.textContent = text
        clip.textStyle = EditorViewModel.CaptionRequest.defaultLocalStyle
        clip.captionGroupId = id
        clip.captionLayout = CaptionLayoutBinding(source: source ?? self.source, order: order)
        clip.sourcePlacementId = (source ?? self.source).placementId
        return clip
    }

    private func fixture() -> Timeline {
        Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [caption("zh", text: "当身体提醒你放慢速度时", order: 1)]),
            Fixtures.videoTrack(clips: [caption("ja", text: "体が減速を求めるとき", order: 2)]),
            Fixtures.videoTrack(clips: [caption("en", text: "When your body asks you to slow down", order: 0)]),
        ])
    }

    private func envelope(_ clip: Clip, _ timeline: Timeline) -> ClosedRange<Double> {
        let g = CaptionLayoutEngine.geometry(for: clip, width: timeline.width, height: timeline.height)
        let mid = clip.transform.centerY * Double(timeline.height)
        return (mid - Double(g.boxSize.height) / 2 - g.outsetTop)...(mid + Double(g.boxSize.height) / 2 + g.outsetBottom)
    }

    @Test(arguments: [(1920, 1080), (1080, 1920), (1080, 1080), (1280, 720), (3840, 2160)])
    func subtitlesFitSafelyWithStableLanguageOrder(width: Int, height: Int) {
        var t = fixture(); t.width = width; t.height = height
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        let clips = t.tracks.flatMap(\.clips).sorted { $0.captionLayout!.order < $1.captionLayout!.order }
        let envelopes = clips.map { envelope($0, t) }
        #expect(abs(envelopes[0].upperBound - Double(height) * 0.95) < 0.01)
        let gap = 16 * Double(height) / 1080
        for i in 1..<envelopes.count {
            #expect(envelopes[i - 1].lowerBound - envelopes[i].upperBound >= gap - 0.01)
        }
        #expect(envelopes.last!.lowerBound >= Double(height) * 0.05)
        #expect(clips.allSatisfy { $0.transform.width <= 0.9 })
    }

    @Test func eachLaneUsesItsTallestCueAndDoesNotCollapseWhenHidden() {
        var t = fixture()
        var longer = t.tracks[0].clips[0]
        longer.id = "later"; longer.startFrame = 300
        longer.textContent = "第一行字幕\n第二行字幕\n第三行字幕"
        t.tracks[0].clips.append(longer)
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        let short = envelope(t.tracks[0].clips[0], t)
        let tall = envelope(t.tracks[0].clips[1], t)
        #expect(abs(short.upperBound - tall.upperBound) < 0.01)
        let positions = t.tracks.flatMap(\.clips).map(\.transform)
        t.tracks[0].hidden = true
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        #expect(positions == t.tracks.flatMap(\.clips).map(\.transform))
    }

    @Test func unrelatedAudioTracksAreNotMovedEvenWhenTheyOverlap() {
        var t = fixture()
        let other = caption("other", text: "Other audio", order: 0, source: .init(audioTrackId: "audio2", placementId: "placement2"))
        t.tracks.append(Fixtures.videoTrack(clips: [other]))
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        #expect(t.tracks.last!.clips[0] == other)
    }

    @Test func manualSiblingIsPreservedAndAvoided() {
        var t = fixture()
        t.tracks[0].clips[0].captionLayout?.automatic = false
        t.tracks[0].clips[0].transform = Transform(center: (0.5, 0.9), width: 0.5, height: 0.05)
        let manual = t.tracks[0].clips[0]
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        #expect(t.tracks[0].clips[0] == manual)
        #expect(envelope(t.tracks[2].clips[0], t).upperBound < 0.875 * Double(t.height))
    }

    @Test func overflowDoesNotPartiallyRepositionAnyTrack() {
        var t = fixture()
        t.tracks[0].clips[0].textContent = Array(repeating: "A very tall subtitle", count: 40).joined(separator: "\n")
        let before = t
        #expect(!CaptionLayoutEngine.arrange(&t, source: source))
        #expect(t == before)
    }

    @Test func geometryIncludesDecorationAndAnimation() {
        let plain = caption("styled", text: "Caption", order: 0)
        var styled = plain
        styled.textStyle?.background.enabled = true
        styled.textStyle?.background.offsetY = 20
        styled.textStyle?.background.outlineWidth = 6
        styled.textStyle?.background.paddingY = 8
        styled.textAnimation = TextAnimation(preset: .slideUp)
        let a = CaptionLayoutEngine.geometry(for: plain, width: 1920, height: 1080)
        let b = CaptionLayoutEngine.geometry(for: styled, width: 1920, height: 1080)
        #expect(b.height > a.height + 54)
    }

    @Test func textEditingReflowsSiblingsAndUndoRestoresTheEntireLayout() {
        let editor = EditorViewModel()
        let manager = UndoManager(); editor.undo.attach(manager)
        var t = fixture(); t.id = editor.activeTimelineId
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        editor.timeline = t
        editor.applyTextContent(clipId: "en", content: "First line\nSecond line\nThird line")
        editor.commitTextContent(clipId: "en", content: "First line\nSecond line\nThird line")
        let changed = editor.timeline
        #expect(changed.tracks[0].clips[0].transform.centerY < t.tracks[0].clips[0].transform.centerY)
        #expect(editor.undo.undoLatest() != nil)
        #expect(editor.timeline == t)
        manager.redo()
        #expect(editor.timeline == changed)
    }

    @Test func spatialEditingBecomesManualAndResetRestoresAutomatic() {
        let editor = EditorViewModel()
        var t = fixture(); t.id = editor.activeTimelineId
        #expect(CaptionLayoutEngine.arrange(&t, source: source)); editor.timeline = t
        editor.commitTransform(clipId: "en", newTransform: Transform(center: (0.4, 0.4), width: 0.5, height: 0.05))
        #expect(editor.clipFor(id: "en")?.captionLayout?.automatic == false)
        editor.resetCaptionPositions(clipIds: ["en"])
        #expect(editor.clipFor(id: "en")?.captionLayout?.automatic == true)
        #expect(editor.clipFor(id: "en")?.transform.centerX == 0.5)
    }

    @Test func bindingsSurviveSaveAndTimelineDuplication() throws {
        var t = fixture()
        t.tracks.append(Fixtures.audioTrack(id: "audio", clips: []))
        #expect(try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(t)) == t)
        t.regenerateIds()
        let bindings = t.tracks.flatMap(\.clips).compactMap(\.captionLayout)
        #expect(bindings.allSatisfy { $0.source.audioTrackId == t.tracks.last!.id })
        #expect(Set(bindings.map { $0.source.placementId }).count == 1)
        #expect(bindings[0].source.placementId != source.placementId)
    }

    @Test func migrationWorksWithoutLoadedSessionAndPreservesCustomPlacement() {
        let editor = EditorViewModel()
        let sessionID = UUID()
        var audio = Fixtures.clip(id: "media", mediaType: .audio, start: 0, duration: 300)
        audio.sourceSessionId = sessionID
        var legacy = caption("legacy", text: "Old caption", order: 0)
        legacy.captionLayout = nil; legacy.sourcePlacementId = nil
        legacy.sourceSessionId = sessionID; legacy.sourceCueId = 0; legacy.sourceCueScope = .source
        legacy.textStyle = TextStyle()
        let natural = TextLayout.naturalSize(content: legacy.textContent!, style: legacy.textStyle!, maxWidth: 1920 * 0.9, canvasHeight: 1080)
        legacy.transform = Transform(center: (0.5, 0.5), width: natural.width / 1920, height: natural.height / 1080)
        var custom = legacy; custom.id = "custom"; custom.captionGroupId = "custom"
        custom.transform.centerX = 0.3; custom.transform.centerY = 0.2
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [legacy, custom]), Fixtures.audioTrack(id: "audio", clips: [audio])]
        editor.repairLegacyCaptionLayouts()
        #expect(editor.clipFor(id: "legacy")!.transform.centerY > 0.8)
        #expect(editor.clipFor(id: "legacy")!.textStyle?.fontSize == 96)
        #expect(editor.clipFor(id: "custom")!.transform == custom.transform)
        let after = editor.timeline
        editor.repairLegacyCaptionLayouts()
        #expect(editor.timeline == after)
    }

    private func session() -> WorkbenchSession {
        let sourceTrack = SubtitleTrack(sourceLanguage: "en", language: "en", cues: [
            SubtitleCue(id: 0, sourceIDs: [0], text: "When your body asks you to slow down", start: 0, end: 10, speaker: nil),
        ])
        return WorkbenchSession(id: UUID(), title: "Layout fixture", createdAt: Date(), modifiedAt: Date(),
            state: .completed, source: .media, sessionType: .upload, transcriptionID: nil, dubID: nil,
            sourceURL: nil, outputURL: nil, transcript: nil, subtitleTrack: sourceTrack, translationTracks: [],
            selectedTranslationLanguageCode: nil, summaryMarkdown: nil, summaryTemplateID: nil,
            summaryTemplateName: nil, summaryState: nil, summaryErrorMessage: nil, sessionTag: nil,
            dubTranscript: nil, dubSubtitleTrack: nil, dubSegments: [], remoteSessionID: nil, cloudSyncError: nil)
    }

    @Test func sessionInsertionAddsLanguagesAboveTheSourceWithSharedAudioIdentity() {
        let editor = EditorViewModel()
        let session = session()
        var audio = Fixtures.clip(id: "audio-clip", mediaType: .audio, start: 0, duration: 300)
        audio.sourceSessionId = session.id
        editor.timeline.tracks = [Fixtures.audioTrack(id: "audio", clips: [audio])]
        editor.insertSessionSubtitleTrack(session, track: session.subtitleTrack!, scope: .source)
        let original = editor.timeline.tracks.flatMap(\.clips).first { $0.mediaType == .text }!
        #expect(original.textStyle?.fontSize == 48)
        #expect(original.transform.centerY > 0.9)
        for (language, text) in [("zh", "当身体提醒你放慢速度时"), ("ja", "体が減速を求めるとき"), ("fr", "Quand votre corps vous demande de ralentir")] {
            let track = SubtitleTrack(sourceLanguage: "en", language: language, cues: [SubtitleCue(id: 0, sourceIDs: [0], text: text, start: 0, end: 10, speaker: nil)])
            editor.insertSessionSubtitleTrack(session, track: track, scope: .translation(languageCode: language))
        }
        let clips = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
        #expect(clips.count == 4)
        #expect(Set(clips.compactMap { $0.captionLayout?.source }).count == 1)
        #expect(editor.clipFor(id: original.id)?.transform == original.transform)
        #expect(clips.filter { $0.sourceCueScope != .source }.allSatisfy { $0.textStyle?.fontScale == 0.82 })
        editor.insertSessionSubtitleTrack(session, track: session.subtitleTrack!, scope: .source)
        let afterDuplicate = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
        #expect(afterDuplicate.count == 4)
    }

    @Test func sameSessionOnDifferentAudioTracksGetsIndependentCaptionGroups() {
        let editor = EditorViewModel()
        let session = session()
        var a = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 300)
        var b = Fixtures.clip(id: "b", mediaType: .audio, start: 600, duration: 300)
        a.sourceSessionId = session.id; b.sourceSessionId = session.id
        editor.timeline.tracks = [Fixtures.audioTrack(id: "a1", clips: [a]), Fixtures.audioTrack(id: "a2", clips: [b])]
        editor.insertSessionSubtitleTrack(session, track: session.subtitleTrack!, scope: .source, startFrame: 0)
        editor.insertSessionSubtitleTrack(session, track: session.subtitleTrack!, scope: .source, startFrame: 600)
        let clips = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
        #expect(clips.count == 2)
        #expect(Set(clips.compactMap { $0.captionLayout?.source.audioTrackId }) == ["a1", "a2"])
        #expect(Set(clips.compactMap { $0.captionGroupId }).count == 2)
    }

    @Test func ambiguousLegacySessionNeverMergesDifferentAudioTracks() {
        let editor = EditorViewModel()
        let sessionID = UUID()
        var a = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 300)
        var b = a; b.id = "b"
        a.sourceSessionId = sessionID; b.sourceSessionId = sessionID
        var legacy = caption("ambiguous", text: "Caption", order: 0)
        legacy.captionLayout = nil; legacy.sourcePlacementId = nil
        legacy.sourceSessionId = sessionID; legacy.sourceCueScope = .source
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [legacy]), Fixtures.audioTrack(id: "a1", clips: [a]), Fixtures.audioTrack(id: "a2", clips: [b])]
        editor.repairLegacyCaptionLayouts()
        #expect(editor.clipFor(id: "ambiguous")?.captionLayout == nil)
        #expect(editor.clipFor(id: "ambiguous")?.transform == legacy.transform)
    }

    @Test func actualRenderedPixelsHaveSafeMarginsAndSeparateLanguages() throws {
        var t = fixture(); t.width = 960; t.height = 540
        #expect(CaptionLayoutEngine.arrange(&t, source: source))
        let size = CGSize(width: t.width, height: t.height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var composed = CIImage(color: CIColor(red: 0.12, green: 0.15, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: size))
        var ranges: [ClosedRange<Int>] = []
        for clip in t.tracks.flatMap(\.clips).sorted(by: { $0.captionLayout!.order < $1.captionLayout!.order }) {
            let image = try #require(TextFrameRenderer.image(clip: clip, frame: 30, renderSize: size))
            var pixels = [UInt8](repeating: 0, count: t.width * t.height * 4)
            context.render(image, toBitmap: &pixels, rowBytes: t.width * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
            var ys: [Int] = []
            for y in 0..<t.height {
                if (0..<t.width).contains(where: { pixels[(y * t.width + $0) * 4 + 3] > 32 }) { ys.append(y) }
            }
            #expect(!ys.isEmpty)
            ranges.append(ys.min()!...ys.max()!)
            composed = image.composited(over: composed)
        }
        #expect(ranges[0].upperBound <= t.height - 27)
        for i in 1..<ranges.count { #expect(ranges[i - 1].lowerBound - ranges[i].upperBound >= 8) }
        let cg = try #require(context.createCGImage(composed, from: CGRect(origin: .zero, size: size)))
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/voxstudio-caption-layout-after.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        // A disposable project lets the requested model verify the signed app's UI.
        let folder = URL(fileURLWithPath: "/tmp/VoxStudioCaptionLayout.voxella", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectFile(timelines: [t], activeTimelineId: t.id, openTimelineIds: [t.id])).write(to: folder.appendingPathComponent(Project.timelineFilename))
    }
}
