import Foundation

enum OptionalSpeakerDiarization {
    static let unavailableMessage = "Speaker identification resources could not be prepared. The transcript keeps its text and timestamps; retry to add speaker labels."
    static let failedMessage = "Speaker recognition failed. Transcription is complete without speaker labels."

    /// Off and single-speaker requests never prepare the diarization model.
    static func requiresModel(requestedSpeakerCount: Int?) -> Bool {
        requestedSpeakerCount != 0 && requestedSpeakerCount != 1
    }

    /// Prepares the model on demand (license record, download, verification),
    /// then runs recognition. Preparation or recognition failure keeps the
    /// transcript without labels; cancellation always propagates.
    static func resolve(
        requestedSpeakerCount: Int?,
        speechRanges: [SpeechTimeRange],
        audioDuration: Double,
        isolation: isolated (any Actor)? = #isolation,
        prepare: () async throws -> Void,
        recognize: () async throws -> SpeakerActivityTimeline
    ) async throws -> SpeakerActivityTimeline {
        try Task.checkCancellation()
        if requestedSpeakerCount == 0 {
            return SpeakerActivityTimeline(
                intervals: [], probabilities: [], frameDuration: 0, speakerCapacity: 0,
                audioDuration: audioDuration,
                diagnostics: DiarizationDiagnostics(
                    backend: .disabled, elapsedSeconds: 0, processedChunks: 0,
                    detectedSpeakerCount: 0, requestedSpeakerCount: 0, warnings: []
                )
            )
        }
        if requestedSpeakerCount == 1 {
            return SpeakerActivityPostprocessor.singleSpeaker(speechRanges: speechRanges, audioDuration: audioDuration)
        }
        var warning = unavailableMessage
        do {
            try await prepare()
            try Task.checkCancellation()
            do {
                let timeline = try await recognize()
                try Task.checkCancellation()
                return timeline
            } catch {
                if isCancellation(error) { throw CancellationError() }
                try Task.checkCancellation()
                Log.transcription.warning(
                    "Optional speaker recognition failed; returning transcript without labels error=\(error.localizedDescription)"
                )
                warning = failedMessage
            }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            try Task.checkCancellation()
            Log.transcription.warning(
                "Speaker resources unavailable; returning transcript without labels error=\(error.localizedDescription)"
            )
        }
        return SpeakerActivityTimeline(
            intervals: [], probabilities: [], frameDuration: 0, speakerCapacity: 0,
            audioDuration: audioDuration,
            diagnostics: DiarizationDiagnostics(
                backend: .unavailable, elapsedSeconds: 0, processedChunks: 0,
                detectedSpeakerCount: 0, requestedSpeakerCount: requestedSpeakerCount, warnings: [warning]
            )
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Diarization cache identity: model, precision, revision and processing
    /// configuration. Identity matching is cached separately.
    static func cacheIdentity(requestedSpeakerCount: Int?, modelRevision: String?) -> String {
        if requestedSpeakerCount == 0 { return "disabled" }
        if requestedSpeakerCount == 1 { return "single" }
        return modelRevision.map { "nemotron3-int8@\($0)|\(processingIdentity)" } ?? "none"
    }

    /// Bump when chunking, thresholds or postprocessing change.
    static let processingIdentity = "offline-340+40|onset0.5|v1"
}
