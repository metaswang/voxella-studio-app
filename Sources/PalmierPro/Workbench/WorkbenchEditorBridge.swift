import Foundation

@MainActor
enum WorkbenchEditorBridge {
    static func openTranscript(_ job: WorkbenchTranscriptionJob) async throws {
        guard let original = job.displayedResult else { throw LocalAIError.emptyTranscript }
        let transcript: TranscriptionResult
        if job.currentTrack == .translation {
            transcript = original
        } else {
            let edited = job.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited.isEmpty || edited == original.text {
                transcript = original
            } else {
                transcript = try await LocalSpeechPipeline.shared.alignScript(
                    sourceURL: job.sourceURL,
                    text: edited,
                    languageCode: job.languageCode,
                    speakerCount: job.speakerCount.count,
                    anchor: original
                )
            }
        }

        let project = try await AppState.shared.createProject(named: availableProjectName(for: job))
        let editor = project.editorViewModel

        guard let asset = editor.addMediaAsset(from: job.sourceURL, finalize: false),
              await editor.finalizeImportedAsset(asset) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if editor.timeline.tracks.isEmpty {
            editor.timeline.tracks.append(Track(type: asset.type == .audio ? .audio : .video))
        }
        let targetTrack = editor.timeline.tracks.firstIndex {
            asset.type == .audio ? $0.type == .audio : $0.type == .video
        } ?? 0
        editor.addClips(assets: [asset], trackIndex: targetTrack, startFrame: 0)

        let sourceDuration = editor.timeline.tracks
            .flatMap(\.clips)
            .first { $0.mediaRef == asset.id }
            .map { Double($0.durationFrames) / Double(editor.timeline.fps) }
            ?? asset.duration
        let editorTranscript = transcript.fittingTimestamps(to: sourceDuration)
        await TranscriptCache.shared.storeLocalTranscript(
            editorTranscript,
            for: job.sourceURL,
            configuration: .init(
                languageCode: job.languageCode,
                speakerCount: job.speakerCount.count
            )
        )

        _ = try await editor.generateCaptions(for: EditorViewModel.CaptionRequest(
            sourceClipIds: [],
            autoDetect: false,
            maxWords: 7,
            provider: .local
        ))
        project.updateChangeCount(.changeDone)
        AppState.shared.presentEditor(for: project)
    }

    private static func availableProjectName(for job: WorkbenchTranscriptionJob) -> String {
        let base = job.displayName + " – Captioned"
        let candidate = Project.storageDirectory
            .appendingPathComponent(base)
            .appendingPathExtension(Project.fileExtension)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return base }
        return "\(base) \(Date().formatted(.dateTime.month().day().hour().minute().second()))"
    }
}
