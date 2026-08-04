import Foundation

extension EditorViewModel {
    func sessionDragPayload(sessionID: UUID) -> String {
        "voxella-session|\(sessionID.uuidString)"
    }

    func sessionDragPayload(from value: String) -> UUID? {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "voxella-session" else { return nil }
        return UUID(uuidString: parts[1])
    }

    func sessionSubtitleDragPayload(
        sessionID: UUID,
        scope: ClipSourceScope
    ) -> String {
        let scopeValue: String
        switch scope {
        case .source:
            scopeValue = "source"
        case .translation(let languageCode):
            scopeValue = "translation:\(languageCode)"
        case .dub:
            scopeValue = "dub"
        }
        return "voxella-session-subtitle|\(sessionID.uuidString)|\(scopeValue)"
    }

    func sessionSubtitleDragPayload(
        from value: String
    ) -> (sessionID: UUID, scope: ClipSourceScope)? {
        let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              parts[0] == "voxella-session-subtitle",
              let sessionID = UUID(uuidString: parts[1]) else {
            return nil
        }
        switch parts[2] {
        case "source":
            return (sessionID, .source)
        case "dub":
            return (sessionID, .dub)
        case let value where value.hasPrefix("translation:"):
            return (
                sessionID,
                .translation(languageCode: String(value.dropFirst("translation:".count)))
            )
        default:
            return nil
        }
    }

    func insertDraggedSessionSubtitle(
        payload: String,
        startFrame: Int
    ) {
        guard let decoded = sessionSubtitleDragPayload(from: payload),
              let session = WorkbenchStore.shared.sessions.first(where: { $0.id == decoded.sessionID })
        else {
            return
        }
        let track: SubtitleTrack?
        switch decoded.scope {
        case .source:
            track = session.subtitleTrack
        case .translation(let languageCode):
            track = session.translationTracks.first {
                $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
            }?.track
        case .dub:
            track = session.dubSubtitleTrack
        }
        guard let track else { return }
        insertSessionSubtitleTrack(session, track: track, scope: decoded.scope, startFrame: startFrame)
    }

    func insertSessionSubtitleTrack(
        _ session: WorkbenchSession,
        track: SubtitleTrack,
        scope: ClipSourceScope,
        startFrame: Int = 0
    ) {
        let cues = track.cues.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }
        guard !cues.isEmpty else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("This session has no timed subtitles."))
            return
        }
        if timeline.tracks.contains(where: { track in
            trackRoleMatches(track.role, scope: scope)
                && track.clips.contains {
                    $0.sourceSessionId == session.id && $0.sourceCueScope == scope
                }
        }) {
            mediaPanelToast = MediaPanelToast(message: L10n.string("This subtitle track is already on the timeline."))
            return
        }

        let trackRole: TrackRole
        let style: TextStyle
        switch scope {
        case .source:
            trackRole = .sourceSubtitles
            style = TextStyle()
        case .translation(let languageCode):
            trackRole = .translation(languageCode: languageCode)
            style = translationSubtitleStyle
        case .dub:
            trackRole = .dub
            style = TextStyle()
        }

        let groupID = "\(session.id.uuidString)-\(scope.contentKey)"
        let specs = cues.map { cue in
            TextClipSpec(
                trackIndex: 0,
                startFrame: startFrame + max(0, secondsToFrame(seconds: cue.start, fps: timeline.fps)),
                durationFrames: max(
                    1,
                    secondsToFrame(seconds: cue.end - cue.start, fps: timeline.fps)
                ),
                content: cue.text,
                style: style,
                transform: nil,
                captionGroupId: groupID,
                words: sessionWordTimings(for: cue, session: session),
                sourceSessionId: session.id,
                sourceCueId: cue.id,
                sourceCueScope: scope
            )
        }

        withTimelineSwap(actionName: subtitleTrackActionName(for: scope)) {
            timeline.tracks.insert(
                Track(type: .video, role: trackRole),
                at: min(0, timeline.tracks.count)
            )
            _ = placeTextClips(specs, clearExistingRegions: false, refreshVisuals: false)
        }
        notifyTimelineChanged(refreshVisuals: false)
    }

    func insertSessionMedia(_ session: WorkbenchSession, startFrame: Int? = nil) async {
        do {
            try await insertSessionMediaThrowing(session, startFrame: startFrame)
        } catch {
            if mediaPanelToast == nil {
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }

    func insertSessionMediaThrowing(
        _ session: WorkbenchSession,
        startFrame: Int? = nil
    ) async throws {
        guard let sourceURL = session.sourceURL else {
            try await insertSessionOutputMediaThrowing(session, startFrame: startFrame)
            return
        }

        guard let asset = addMediaAsset(from: sourceURL, finalize: false) else {
            throw WorkbenchEditorBridgeError.failedToPlaceSession
        }
        guard await finalizeImportedAsset(asset) else {
            let message = L10n.string("The session media could not be opened.")
            mediaPanelToast = MediaPanelToast(message: message)
            throw WorkbenchEditorBridgeError.failedToPlaceSession
        }

        let trackType: ClipType = asset.type == .audio ? .audio : .video
        let trackIndex = timeline.tracks.firstIndex(where: {
            $0.type == trackType && $0.role == .standard
        })
            ?? insertTrack(at: trackType == .audio ? timeline.tracks.count : 0, type: trackType)
        let resolvedStart = max(0, startFrame ?? currentFrame)
        // Keep A/V linked via createClips; never share that group with subtitle cues.
        let mediaClipIDs = addClipsReturningIDs(
            assets: [asset],
            trackIndex: trackIndex,
            startFrame: resolvedStart,
            forcedLinkGroupId: nil,
            sourceSessionId: session.id
        )
        guard !mediaClipIDs.isEmpty else {
            throw WorkbenchEditorBridgeError.failedToPlaceSession
        }

        if let sourceTrack = session.subtitleTrack
            ?? session.transcript.map(SubtitleTrack.fromTranscript) {
            insertSessionSubtitleTrack(
                session,
                track: sourceTrack,
                scope: .source,
                startFrame: resolvedStart
            )
        }
        for translation in session.translationTracks where !translation.track.cues.isEmpty {
            insertSessionSubtitleTrack(
                session,
                track: translation.track,
                scope: .translation(languageCode: translation.languageCode),
                startFrame: resolvedStart
            )
        }
    }

    func insertSessionOutputMedia(_ session: WorkbenchSession, startFrame: Int? = nil) async {
        do {
            try await insertSessionOutputMediaThrowing(session, startFrame: startFrame)
        } catch {
            if mediaPanelToast == nil {
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }

    func insertSessionOutputMediaThrowing(
        _ session: WorkbenchSession,
        startFrame: Int? = nil
    ) async throws {
        guard let outputURL = session.outputURL else {
            let message = L10n.string("This session has no generated audio.")
            mediaPanelToast = MediaPanelToast(message: message)
            throw WorkbenchEditorBridgeError.missingSessionMedia
        }
        guard let asset = addMediaAsset(from: outputURL, finalize: false),
              await finalizeImportedAsset(asset) else {
            let message = L10n.string("The generated audio could not be opened.")
            mediaPanelToast = MediaPanelToast(message: message)
            throw WorkbenchEditorBridgeError.failedToPlaceSession
        }
        let trackIndex = timeline.tracks.firstIndex(where: { $0.role == .dub })
            ?? insertTrack(at: timeline.tracks.count, type: .dub, role: .dub)
        addClips(
            assets: [asset],
            trackIndex: trackIndex,
            startFrame: max(0, startFrame ?? currentFrame)
        )
    }

    @discardableResult
    private func addClipsReturningIDs(
        assets: [MediaAsset],
        trackIndex: Int,
        startFrame: Int,
        forcedLinkGroupId: String?,
        sourceSessionId: UUID? = nil
    ) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex) else { return [] }
        let visualTrackId = timeline.tracks[trackIndex].id
        var created: [String] = []
        withTimelineSwap(actionName: "Add Clips") {
            let totalDur = assets.reduce(0) { $0 + clipDurationFrames(for: $1, segment: nil) }
            clearRegion(trackIndex: trackIndex, start: startFrame, end: startFrame + totalDur, prune: false)
            guard let resolvedTrackIndex = timeline.tracks.firstIndex(where: { $0.id == visualTrackId }) else {
                pruneEmptyTracks()
                return
            }
            created = createClips(
                from: assets,
                trackIndex: resolvedTrackIndex,
                startFrame: startFrame
            )
            if forcedLinkGroupId != nil || sourceSessionId != nil {
                for id in created {
                    guard let loc = findClip(id: id) else { continue }
                    if let forcedLinkGroupId {
                        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].linkGroupId = forcedLinkGroupId
                    }
                    if let sourceSessionId {
                        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].sourceSessionId = sourceSessionId
                    }
                }
            }
            sortClips(trackIndex: resolvedTrackIndex)
            pruneEmptyTracks()
        }
        return created
    }

    private var translationSubtitleStyle: TextStyle {
        var style = TextStyle()
        style.fontScale *= 0.82
        style.background.color.a *= 0.82
        return style
    }

    private func subtitleTrackActionName(for scope: ClipSourceScope) -> String {
        switch scope {
        case .source:
            return "Add Source Subtitles"
        case .translation(let languageCode):
            return "Add \(languageCode) Subtitles"
        case .dub:
            return "Add Dub Subtitles"
        }
    }

    private func trackRoleMatches(_ role: TrackRole, scope: ClipSourceScope) -> Bool {
        switch (role, scope) {
        case (.sourceSubtitles, .source), (.dub, .dub):
            return true
        case (.translation(let existing), .translation(let requested)):
            return existing.caseInsensitiveCompare(requested) == .orderedSame
        default:
            return false
        }
    }

    private func sessionWordTimings(
        for cue: SubtitleCue,
        session: WorkbenchSession
    ) -> [WordTiming]? {
        guard let words = session.transcript?.words else { return nil }
        let timed = words.compactMap { word -> WordTiming? in
            guard let start = word.start,
                  let end = word.end,
                  start.isFinite,
                  end.isFinite,
                  end > start,
                  end > cue.start,
                  start < cue.end
            else {
                return nil
            }
            let relativeStart = max(0, Int(((max(start, cue.start) - cue.start) * Double(timeline.fps)).rounded()))
            let relativeEnd = max(
                relativeStart + 1,
                Int(((min(end, cue.end) - cue.start) * Double(timeline.fps)).rounded())
            )
            guard relativeEnd > relativeStart else { return nil }
            return WordTiming(
                text: word.text,
                startFrame: relativeStart,
                endFrame: relativeEnd
            )
        }
        return timed.isEmpty ? nil : timed
    }
}

private extension ClipSourceScope {
    var contentKey: String {
        switch self {
        case .source:
            return "source"
        case .translation(let languageCode):
            return "translation-\(languageCode.lowercased())"
        case .dub:
            return "dub"
        }
    }
}
