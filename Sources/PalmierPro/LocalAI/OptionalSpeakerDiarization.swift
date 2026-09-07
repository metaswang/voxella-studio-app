import Foundation

enum OptionalSpeakerDiarization {
    static let unavailableMessage = "Speaker model not installed. Transcription will include timestamps without speaker labels."
    static let failedMessage = "Speaker recognition failed. Transcription is complete without speaker labels."

    static func resolve(
        requestedSpeakerCount: Int?,
        isInstalled: Bool,
        speechRanges: [SpeechTimeRange],
        audioDuration: Double,
        isolation: isolated (any Actor)? = #isolation,
        recognize: () async throws -> SpeakerActivityTimeline
    ) async throws -> SpeakerActivityTimeline {
        try Task.checkCancellation()
        if requestedSpeakerCount == 1 {
            return SpeakerActivityPostprocessor.singleSpeaker(speechRanges: speechRanges, audioDuration: audioDuration)
        }
        var warning = unavailableMessage
        if isInstalled {
            do {
                let timeline = try await recognize()
                try Task.checkCancellation()
                return timeline
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                Log.transcription.warning("Optional speaker recognition failed; returning transcript without labels")
                warning = failedMessage
            }
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

    static func cacheIdentity(requestedSpeakerCount: Int?, modelRevision: String?) -> String {
        if requestedSpeakerCount == 1 { return "single" }
        return modelRevision.map { "sortformer@\($0)" } ?? "none"
    }
}
