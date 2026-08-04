import Foundation

enum EditorSessionProcessingState: Equatable, Sendable {
    case idle
    case processing
    case completed
    case failed(String)
}

enum EditorDubReferenceMode: String, CaseIterable, Identifiable, Sendable {
    case library
    case recording
    case timelineClip

    var id: String { rawValue }
}

extension EditorViewModel {
    /// Caption/translate track-header actions apply to library imports only.
    func showsEditorCaptionActions(on trackIndex: Int) -> Bool {
        guard timeline.tracks.indices.contains(trackIndex) else { return false }
        let track = timeline.tracks[trackIndex]
        guard track.role == .standard, track.type == .video || track.type.isAudio else { return false }
        guard let clip = track.clips.first(where: { $0.mediaType == .video || $0.mediaType.isAudio }) else {
            return true
        }
        return !isSessionSourcedMediaClip(clip)
    }

    /// Session-dragged media already carries Workbench subtitles; library imports do not.
    func isSessionSourcedMediaClip(_ clip: Clip) -> Bool {
        if clip.sourceSessionId != nil { return true }
        guard let groupId = clip.linkGroupId else { return false }
        let linked = timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId == groupId }
        if linked.contains(where: {
            ($0.mediaType == .video || $0.mediaType.isAudio) && $0.sourceSessionId != nil
        }) {
            return true
        }
        // Legacy session inserts stamped only cue text; treat linked session cues as session media.
        return linked.contains { $0.mediaType == .text && $0.sourceSessionId != nil }
    }

    func requestEditorTranslation(for trackIndex: Int) {
        guard showsEditorCaptionActions(on: trackIndex) else { return }
        guard let clip = firstProcessableClip(on: trackIndex) else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Add a video or audio clip before translating."))
            return
        }
        pendingEditorTranslationRequest = EditorTranslationRequest(clipId: clip.id)
    }

    func requestEditorDub(for trackIndex: Int) {
        guard let clip = firstProcessableClip(on: trackIndex) else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Add a video or audio clip before dubbing."))
            return
        }
        pendingEditorDubRequest = EditorDubRequest(clipId: clip.id)
    }

    func requestEditorDub() {
        if let selectedID = selectedClipIds.first,
           let location = findClip(id: selectedID),
           let clip = firstProcessableClip(on: location.trackIndex) {
            pendingEditorDubRequest = EditorDubRequest(clipId: clip.id)
            return
        }
        if let trackIndex = timeline.tracks.firstIndex(where: {
            $0.role == .standard && $0.clips.contains { $0.mediaType == .video || $0.mediaType.isAudio }
        }) {
            requestEditorDub(for: trackIndex)
            return
        }
        mediaPanelToast = MediaPanelToast(message: L10n.string("Add a video or audio clip before dubbing."))
    }

    func beginEditorTranscription(
        for clipId: String,
        targetLanguageCode: String? = nil
    ) {
        guard let location = findClip(id: clipId) else { return }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard !isSessionSourcedMediaClip(clip) else {
            mediaPanelToast = MediaPanelToast(
                message: L10n.string("This clip already comes from a session with subtitles.")
            )
            return
        }
        guard clip.mediaType == .video || clip.mediaType.isAudio,
              let asset = mediaAssetsById[clip.mediaRef] else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Select an imported video or audio clip first."))
            return
        }

        let language = targetLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = language?.isEmpty == false ? language : nil
        let options = LocalProcessingOptions(
            languageCode: nil,
            customTitle: "\(asset.name) Subtitles",
            speakerCount: .auto,
            enableTranslation: normalizedLanguage != nil,
            targetLanguageCode: normalizedLanguage,
            useLLMSubtitleProcessing: true
        )
        let store = WorkbenchStore.shared
        guard let batchID = store.beginTranscriptions(
            sourceURLs: [asset.url],
            options: options,
            openSessionWhenDone: false
        ) else {
            sessionProcessingStates[clipId] = .failed(
                store.transcriptionAdmissionError ?? L10n.string("Could not start transcription.")
            )
            return
        }

        let jobIDs = store.transcriptions
            .filter { $0.batchID == batchID }
            .map(\.id)
        guard let jobID = jobIDs.first else {
            sessionProcessingStates[clipId] = .failed(L10n.string("The transcription session was not created."))
            return
        }

        sessionProcessingTasks[clipId]?.cancel()
        sessionProcessingStates[clipId] = .processing
        let timelineID = activeTimelineId
        let startFrame = clip.startFrame
        let mediaRef = clip.mediaRef

        sessionProcessingTasks[clipId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let terminalJob = await self.waitForTranscription(jobID, in: store)
            guard !Task.isCancelled else { return }
            guard self.activeTimelineId == timelineID,
                  let currentLocation = self.findClip(id: clipId),
                  self.timeline.tracks[currentLocation.trackIndex].clips[currentLocation.clipIndex].mediaRef == mediaRef
            else {
                self.sessionProcessingTasks[clipId] = nil
                return
            }

            guard terminalJob?.state == .completed,
                  let session = store.sessions.first(where: { $0.id == jobID })
            else {
                let message = terminalJob?.errorMessage
                    ?? L10n.string("Transcription did not complete.")
                self.sessionProcessingStates[clipId] = .failed(message)
                self.sessionProcessingTasks[clipId] = nil
                return
            }

            for id in self.expandToLinkGroup([clipId]) {
                guard let loc = self.findClip(id: id) else { continue }
                let mediaType = self.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType
                guard mediaType == .video || mediaType.isAudio else { continue }
                self.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].sourceSessionId = session.id
            }
            if let sourceTrack = session.subtitleTrack
                ?? session.transcript.map(SubtitleTrack.fromTranscript) {
                self.insertSessionSubtitleTrack(
                    session,
                    track: sourceTrack,
                    scope: .source,
                    startFrame: startFrame
                )
            }
            for translation in session.translationTracks {
                self.insertSessionSubtitleTrack(
                    session,
                    track: translation.track,
                    scope: .translation(languageCode: translation.languageCode),
                    startFrame: startFrame
                )
            }
            self.sessionProcessingStates[clipId] = .completed
            self.mediaPanelToast = MediaPanelToast(
                message: L10n.string("Subtitles are ready."),
                kind: .success
            )
            self.sessionProcessingTasks[clipId] = nil
        }
    }

    func beginEditorTranslation(
        for clipId: String,
        targetLanguageCode: String
    ) {
        guard let location = findClip(id: clipId) else { return }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard !isSessionSourcedMediaClip(clip) else {
            mediaPanelToast = MediaPanelToast(
                message: L10n.string("This clip already comes from a session with subtitles.")
            )
            return
        }
        let normalizedLanguage = targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLanguage.isEmpty else { return }
        if let source = sourceSubtitleReference(for: clipId) {
            let store = WorkbenchStore.shared
            store.updateTranscription(source.sessionID) { job in
                job.targetLanguageCode = normalizedLanguage
            }
            store.runTranslation(source.sessionID)
            sessionProcessingTasks[clipId]?.cancel()
            sessionProcessingStates[clipId] = .processing
            let timelineID = activeTimelineId
            sessionProcessingTasks[clipId] = Task { @MainActor [weak self] in
                guard let self else { return }
                let job = await self.waitForTranscription(source.sessionID, in: store)
                guard !Task.isCancelled else { return }
                guard self.activeTimelineId == timelineID,
                      job?.state == .completed,
                      let session = store.sessions.first(where: { $0.id == source.sessionID })
                else {
                    self.sessionProcessingStates[clipId] = .failed(
                        job?.errorMessage ?? L10n.string("Translation did not complete.")
                    )
                    self.sessionProcessingTasks[clipId] = nil
                    return
                }
                for translation in session.translationTracks {
                    self.insertSessionSubtitleTrack(
                        session,
                        track: translation.track,
                        scope: .translation(languageCode: translation.languageCode),
                        startFrame: source.startFrame
                    )
                }
                self.sessionProcessingStates[clipId] = .completed
                self.mediaPanelToast = MediaPanelToast(
                    message: L10n.string("Translation is ready."),
                    kind: .success
                )
                self.sessionProcessingTasks[clipId] = nil
            }
        } else {
            beginEditorTranscription(for: clipId, targetLanguageCode: normalizedLanguage)
        }
    }

    func cancelEditorTranscription(for clipId: String) {
        sessionProcessingTasks[clipId]?.cancel()
        sessionProcessingTasks[clipId] = nil
        sessionProcessingStates[clipId] = .idle
    }

    func beginEditorDub(
        for clipId: String,
        script: String,
        referenceMode: EditorDubReferenceMode,
        referenceVoiceID: UUID?,
        recordedURL: URL?,
        referenceClipID: String?,
        referenceRange: ClosedRange<Double>
    ) {
        let normalizedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScript.isEmpty else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Enter a script before generating the dub."))
            return
        }
        guard let location = findClip(id: clipId) else { return }
        let sourceClip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let startFrame = sourceClip.startFrame
        let store = WorkbenchStore.shared
        let dubID = store.addDub(
            script: normalizedScript,
            title: "",
            openRoute: false
        )
        store.updateDub(dubID) { job in
            job.referenceVoiceID = referenceMode == .library ? referenceVoiceID : nil
            job.referenceAudioPath = referenceMode == .recording ? recordedURL?.path : nil
            job.referenceText = normalizedScript
        }

        sessionProcessingTasks[clipId]?.cancel()
        sessionProcessingStates[clipId] = .processing
        let sourceMediaURL: URL? = referenceClipID.flatMap { id in
            clipFor(id: id).flatMap { mediaAssetsById[$0.mediaRef]?.url }
        }
        let referenceClip = referenceClipID.flatMap(clipFor(id:))
        sessionProcessingTasks[clipId] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if referenceMode == .timelineClip,
                   referenceClip != nil,
                   let sourceMediaURL {
                    let trimmedSource = TrimmedSource(
                        sourceURL: sourceMediaURL,
                        trimStartFrame: max(
                            0,
                            Int((referenceRange.lowerBound * Double(timeline.fps)).rounded())
                        ),
                        trimEndFrame: 0,
                        sourceFramesConsumed: max(
                            1,
                            Int(((referenceRange.upperBound - referenceRange.lowerBound)
                                * Double(timeline.fps)).rounded())
                        ),
                        fps: timeline.fps
                    )
                    let extractedURL = try await AudioTrackExtractor.extract(
                        sourceURL: sourceMediaURL,
                        trimmedSource: trimmedSource
                    )
                    store.updateDub(dubID) { job in
                        job.referenceAudioPath = extractedURL.path
                        job.referenceText = normalizedScript
                    }
                }
                try Task.checkCancellation()
                store.runDub(dubID)
                guard let job = await self.waitForDub(dubID, in: store),
                      job.state == .completed,
                      let outputURL = job.outputURL else {
                    let message = store.dubs.first(where: { $0.id == dubID })?.errorMessage
                        ?? L10n.string("Dubbing did not complete.")
                    self.sessionProcessingStates[clipId] = .failed(message)
                    self.sessionProcessingTasks[clipId] = nil
                    return
                }
                guard let asset = self.addMediaAsset(from: outputURL, finalize: false),
                      await self.finalizeImportedAsset(asset) else {
                    self.sessionProcessingStates[clipId] = .failed(
                        L10n.string("The generated dub could not be imported.")
                    )
                    self.sessionProcessingTasks[clipId] = nil
                    return
                }
                let dubTrackIndex: Int
                if let existing = self.timeline.tracks.firstIndex(where: { $0.role == .dub }) {
                    dubTrackIndex = existing
                } else {
                    dubTrackIndex = self.insertTrack(
                        at: self.timeline.tracks.count,
                        type: .dub,
                        role: .dub
                    )
                }
                self.addClips(
                    assets: [asset],
                    trackIndex: dubTrackIndex,
                    startFrame: startFrame
                )
                self.sessionProcessingStates[clipId] = .completed
                self.mediaPanelToast = MediaPanelToast(
                    message: L10n.string("Dub audio is ready."),
                    kind: .success
                )
            } catch is CancellationError {
                self.sessionProcessingStates[clipId] = .idle
            } catch {
                self.sessionProcessingStates[clipId] = .failed(error.localizedDescription)
            }
            self.sessionProcessingTasks[clipId] = nil
        }
    }

    private func waitForTranscription(
        _ id: UUID,
        in store: WorkbenchStore
    ) async -> WorkbenchTranscriptionJob? {
        while !Task.isCancelled {
            guard let job = store.transcriptions.first(where: { $0.id == id }) else {
                return nil
            }
            switch job.state {
            case .completed, .failed, .cancelled:
                return job
            case .ready, .running, .cancelling:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }

    private func waitForDub(
        _ id: UUID,
        in store: WorkbenchStore
    ) async -> WorkbenchDubJob? {
        while !Task.isCancelled {
            guard let job = store.dubs.first(where: { $0.id == id }) else {
                return nil
            }
            switch job.state {
            case .completed, .failed, .cancelled:
                return job
            case .ready, .running, .cancelling:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }

    private func firstProcessableClip(on trackIndex: Int) -> Clip? {
        guard timeline.tracks.indices.contains(trackIndex) else { return nil }
        return timeline.tracks[trackIndex].clips.first {
            $0.mediaType == .video || $0.mediaType.isAudio
        }
    }

    private func sourceSubtitleReference(
        for clipID: String
    ) -> (sessionID: UUID, startFrame: Int)? {
        guard let location = findClip(id: clipID) else { return nil }
        let mediaClip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let candidate = timeline.tracks
            .filter { $0.role == .sourceSubtitles }
            .flatMap(\.clips)
            .first {
                $0.sourceSessionId != nil
                    && $0.mediaType == .text
                    && $0.startFrame < mediaClip.endFrame
                    && $0.endFrame > mediaClip.startFrame
            }
        guard let candidate, let sessionID = candidate.sourceSessionId else { return nil }
        return (sessionID, mediaClip.startFrame)
    }
}
