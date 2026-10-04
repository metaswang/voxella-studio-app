import Foundation

extension EditorViewModel {
    func captionSourceContext(for clipID: String, create: Bool = true) -> CaptionSourceContext? {
        guard let loc = findClip(id: clipID) else { return nil }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        if let binding = clip.captionLayout { return binding.source }
        let linked = expandToLinkGroup([clipID])
        let audio = timeline.tracks.enumerated().flatMap { ti, track in
            track.clips.filter { linked.contains($0.id) && $0.mediaType.isAudio }.map { (ti, $0) }
        }
        guard audio.count <= 1 else { return nil }
        let source = audio.first ?? (loc.trackIndex, clip)
        guard source.1.mediaType.isAudio || source.1.mediaType == .video else { return nil }
        let placement = source.1.sourcePlacementId ?? clip.sourcePlacementId ?? (create ? UUID().uuidString : "")
        guard !placement.isEmpty else { return nil }
        if create {
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices where linked.contains(timeline.tracks[ti].clips[ci].id) {
                    timeline.tracks[ti].clips[ci].sourcePlacementId = placement
                }
            }
        }
        return CaptionSourceContext(audioTrackId: timeline.tracks[source.0].id, placementId: placement)
    }

    func sessionCaptionSource(sessionID: UUID, startFrame: Int, scope: ClipSourceScope) -> CaptionSourceContext? {
        guard scope != .dub else { return nil }
        let audio = timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType.isAudio && $0.sourceSessionId == sessionID && $0.startFrame == startFrame
        }
        let candidates = audio.isEmpty ? timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType == .video && $0.sourceSessionId == sessionID && $0.startFrame == startFrame
        } : audio
        guard candidates.count == 1 else { return nil }
        return captionSourceContext(for: candidates[0].id)
    }

    func prepareCaptionEdit(before: Clip, after: inout Clip) {
        guard after.captionLayout != nil else { return }
        let fittedContent = before.textContent != after.textContent || before.textStyle != after.textStyle
        if (!fittedContent && before.transform != after.transform) || after.hasTransformAnimation {
            after.captionLayout?.automatic = false
        }
    }

    func commitCaptionEditIfNeeded(clipIds: [String], actionName: String, _ modify: (inout Clip) -> Void) -> Bool {
        guard clipIds.contains(where: { clipFor(id: $0)?.captionLayout != nil }) else { return false }
        let before = captionEditBefore ?? timeline
        captionEditBefore = nil
        for id in clipIds {
            guard let loc = findClip(id: id) else { continue }
            var clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let previous = clip
            modify(&clip)
            prepareCaptionEdit(before: previous, after: &clip)
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
            dragBefore.removeValue(forKey: id)
        }
        guard reflowCaptionLayouts() else {
            timeline = before
            videoEngine?.refreshVisuals()
            return true
        }
        if timeline != before {
            registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
            notifyTimelineChanged()
        }
        return true
    }

    @discardableResult
    func reflowCaptionLayouts() -> Bool {
        var updated = timeline
        // Track IDs can change after moving media, duplication or decompose-nest.
        var audioTracks: [String: Set<String>] = [:]
        for track in updated.tracks {
            for clip in track.clips where clip.mediaType.isAudio {
                if let placement = clip.sourcePlacementId { audioTracks[placement, default: []].insert(track.id) }
            }
        }
        for ti in updated.tracks.indices {
            for ci in updated.tracks[ti].clips.indices {
                if let binding = updated.tracks[ti].clips[ci].captionLayout,
                   let tracks = audioTracks[binding.source.placementId], tracks.count == 1, let track = tracks.first {
                    updated.tracks[ti].clips[ci].captionLayout?.source.audioTrackId = track
                }
            }
        }
        let sources = Set(updated.tracks.flatMap(\.clips).compactMap { $0.captionLayout?.source })
        var success = true
        for source in sources {
            if !CaptionLayoutEngine.arrange(&updated, source: source) { success = false }
        }
        if updated != timeline { timeline = updated }
        if !success {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Subtitles are too tall to arrange. Reduce the font size or the number of languages."))
        }
        return success
    }

    func resetCaptionPositions(clipIds: [String]) {
        withTimelineSwap(actionName: "Reset Subtitle Layout") {
            let before = timeline
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices where clipIds.contains(timeline.tracks[ti].clips[ci].id) {
                    if timeline.tracks[ti].clips[ci].captionLayout != nil {
                        timeline.tracks[ti].clips[ci].captionLayout?.automatic = true
                        timeline.tracks[ti].clips[ci].positionTrack = nil
                        timeline.tracks[ti].clips[ci].scaleTrack = nil
                        timeline.tracks[ti].clips[ci].rotationTrack = nil
                        timeline.tracks[ti].clips[ci].transform.rotation = 0
                        timeline.tracks[ti].clips[ci].transform.flipHorizontal = false
                        timeline.tracks[ti].clips[ci].transform.flipVertical = false
                    } else {
                        timeline.tracks[ti].clips[ci].transform.centerX = 0.5
                        timeline.tracks[ti].clips[ci].transform.centerY = 0.5
                        timeline.tracks[ti].clips[ci].positionTrack = nil
                    }
                }
            }
            if !reflowCaptionLayouts() { timeline = before }
        }
    }

    func arrangeCaptions(forTrackId trackID: String) {
        let clips = timeline.tracks.first(where: { $0.id == trackID })?.clips ?? []
        let sources = Set(clips.compactMap { $0.captionLayout?.source }).union(
            timeline.tracks.flatMap(\.clips).compactMap { $0.captionLayout?.source }.filter { $0.audioTrackId == trackID })
        let ids = timeline.tracks.flatMap(\.clips).filter {
            $0.captionLayout.map { sources.contains($0.source) } ?? false
        }.map(\.id)
        resetCaptionPositions(clipIds: ids)
    }

    func associateSelectedCaptions(withAudioTrack trackID: String) {
        guard let track = timeline.tracks.first(where: { $0.id == trackID }) else { return }
        let selected = timeline.tracks.flatMap(\.clips).filter { selectedClipIds.contains($0.id) && $0.mediaType == .text && $0.captionGroupId != nil }
        guard let first = selected.min(by: { $0.startFrame < $1.startFrame }) else { return }
        let sources = track.clips.filter { $0.contains(timelineFrame: first.startFrame) }
        guard sources.count == 1 else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Select an audio track with one source clip at the subtitle start."))
            return
        }
        withTimelineSwap(actionName: "Associate Subtitle Source") {
            let before = timeline
            guard let source = captionSourceContext(for: sources[0].id) else { return }
            var order = 1
            for ti in timeline.tracks.indices.reversed() {
                let isSource = timeline.tracks[ti].role == .sourceSubtitles
                var touched = false
                for ci in timeline.tracks[ti].clips.indices where selectedClipIds.contains(timeline.tracks[ti].clips[ci].id) && timeline.tracks[ti].clips[ci].captionGroupId != nil {
                    timeline.tracks[ti].clips[ci].sourcePlacementId = source.placementId
                    timeline.tracks[ti].clips[ci].captionLayout = CaptionLayoutBinding(source: source, order: isSource ? 0 : order)
                    touched = true
                }
                if touched && !isSource { order += 1 }
            }
            if !reflowCaptionLayouts() { timeline = before }
        }
    }

    /// Conservative migration: only unique media placement matches are eligible.
    func repairLegacyCaptionLayouts() {
        let active = activeTimelineId
        for index in timelines.indices {
            activeTimelineId = timelines[index].id
            let before = timeline
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices {
                    var clip = timeline.tracks[ti].clips[ci]
                    guard clip.mediaType == .text, clip.captionLayout == nil,
                          let sessionID = clip.sourceSessionId, let scope = clip.sourceCueScope,
                          scope != .dub else { continue }
                    let session = WorkbenchStore.shared.sessions.first(where: { $0.id == sessionID })
                    let cues: [SubtitleCue]
                    switch scope {
                    case .source: cues = session?.subtitleTrack?.cues ?? []
                    case .translation(let language): cues = session?.translationTracks.first { $0.languageCode.caseInsensitiveCompare(language) == .orderedSame }?.track.cues ?? []
                    case .dub: cues = []
                    }
                    let cue = cues.first(where: { $0.id == clip.sourceCueId })
                    let offset = cue.map { clip.startFrame - secondsToFrame(seconds: $0.start, fps: timeline.fps) }
                    let audio = timeline.tracks.flatMap(\.clips).filter { $0.mediaType.isAudio && $0.sourceSessionId == sessionID }
                    let candidates = audio.isEmpty ? timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .video && $0.sourceSessionId == sessionID } : audio
                    let matched = offset.map { value in candidates.filter { $0.startFrame == value } } ?? candidates
                    guard matched.count == 1, let source = captionSourceContext(for: matched[0].id) else { continue }
                    let natural = TextLayout.naturalSize(content: clip.textContent ?? "", style: clip.textStyle ?? TextStyle(),
                        maxWidth: Double(timeline.width) * 0.9, canvasHeight: Double(timeline.height))
                    let isDefault = abs(clip.transform.centerX - 0.5) * Double(timeline.width) <= 1
                        && abs(clip.transform.centerY - 0.5) * Double(timeline.height) <= 1
                        && abs(clip.transform.width * Double(timeline.width) - natural.width) <= 1
                        && abs(clip.transform.height * Double(timeline.height) - natural.height) <= 1
                        && !clip.hasTransformAnimation && clip.transform.rotation == 0
                        && !clip.transform.flipHorizontal && !clip.transform.flipVertical
                    let order: Int
                    if case .translation(let language) = scope {
                        order = 1 + (session?.translationTracks.firstIndex { $0.languageCode.caseInsensitiveCompare(language) == .orderedSame } ?? ti)
                    } else { order = 0 }
                    clip.sourcePlacementId = source.placementId
                    clip.captionLayout = CaptionLayoutBinding(source: source, order: order, automatic: isDefault)
                    timeline.tracks[ti].clips[ci] = clip
                }
            }
            _ = reflowCaptionLayouts()
            if timeline != before {
                registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Improve Subtitle Layout")
            }
        }
        activeTimelineId = active
    }
}
