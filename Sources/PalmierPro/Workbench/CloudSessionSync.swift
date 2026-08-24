import Foundation

enum CloudSessionContentKind: String, Sendable, Equatable {
    case transcription
    case dub
}

struct CloudSessionSyncSnapshot: Sendable, Equatable {
    let jobID: UUID
    let remoteSessionID: UUID
    let contentKind: CloudSessionContentKind
    let revision: Int
    let sourceLanguage: String?
    let result: TranscriptionResult
    let subtitleTrack: SubtitleTrack?
    let translationTracks: [WorkbenchTranslationTrack]
    let dubSegments: [DubSegmentPayload]
    let title: String?
    let summary: String?
    let summaryTemplateID: String?
    let summaryTemplateName: String?
    let summaryTemplateUserEdition: String?
    let sessionTag: String?
}

protocol CloudSessionSyncing: Sendable {
    func sync(_ snapshot: CloudSessionSyncSnapshot) async throws
    func delete(remoteSessionID: UUID) async throws
}

struct VoxellaCloudSessionSync: CloudSessionSyncing {
    private let client: VoxellaAPIClient

    init(client: VoxellaAPIClient = .shared) {
        self.client = client
    }

    func sync(_ snapshot: CloudSessionSyncSnapshot) async throws {
        let response = try await client.syncDesktopSession(snapshot)
        guard response.applied != false else {
            throw VoxellaAPIError.http(409, "VoxStudio Cloud has a newer edit for this session.")
        }
    }

    func delete(remoteSessionID: UUID) async throws {
        do {
            try await client.deleteSession(remoteSessionID)
        } catch VoxellaAPIError.http(404, _) {
            // A missing remote copy already satisfies the delete request.
        }
    }
}

extension TranscriptionResult {
    /// The cloud contract accepts either a complete valid timing pair or no timing.
    func clearingInvalidWordTimings() -> TranscriptionResult {
        let normalizedWords = words.map { word in
            guard let start = word.start,
                  let end = word.end,
                  start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start else {
                return TranscriptionWord(
                    text: word.text,
                    start: nil,
                    end: nil,
                    speaker: word.speaker,
                    speakerConfidence: word.speakerConfidence,
                    speakerBoundary: word.speakerBoundary
                )
            }
            return word
        }
        return TranscriptionResult(
            text: text,
            language: language,
            words: normalizedWords,
            segments: segments
        )
    }
}
