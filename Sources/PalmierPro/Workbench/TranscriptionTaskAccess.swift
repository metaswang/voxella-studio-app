import Foundation

struct TranscriptionSourcePreview: Sendable, Equatable {
    let type: String
    let platform: String
    let sourceURL: URL
    let videoID: String

    var payload: [String: String] {
        [
            "type": type,
            "platform": platform,
            "source_url": sourceURL.absoluteString,
            "video_id": videoID,
        ]
    }
}

struct TranscriptionTaskRequest: Sendable {
    var jobID: UUID
    var sourceURL: URL
    var originalFilename: String
    var mimeType: String
    var sizeBytes: Int64?
    var durationHintSec: Double?
    var options: TranscriptionProcessingOptions
    var placement: TranscriptionPlacement
    var flowRequest: MediaFlowRequest
    var remoteSessionID: UUID?
    var shouldReuseRemoteSession: Bool
    var sourcePreview: TranscriptionSourcePreview?
    var uploadURL: URL?

    var resolvedUploadURL: URL { uploadURL ?? sourceURL }
}

struct TranscriptionResultSyncRequest: Sendable {
    var jobID: UUID
    var remoteSessionID: UUID?
    var sourceURL: URL
    var originalFilename: String
    var mimeType: String
    var sizeBytes: Int64?
    var options: TranscriptionProcessingOptions
    var placement: TranscriptionPlacement
    var result: TranscriptionResult
    var subtitleTrack: SubtitleTrack?
    var translationTracks: [WorkbenchTranslationTrack]
    var title: String? = nil
    var summary: String? = nil
    var sessionTag: String? = nil
    var sourcePreview: TranscriptionSourcePreview? = nil
}

protocol TranscriptionTaskAccessing: Sendable {
    func events(for request: TranscriptionTaskRequest) -> AsyncStream<MediaJobEvent>
    func cancel(_ id: UUID) async throws
    func persistCloudCopyIfNeeded(_ request: TranscriptionResultSyncRequest) async throws -> UUID?
    func confirmEphemeralDeletionIfNeeded(remoteSessionID: UUID) async throws
}

struct LocalTranscriptionTaskAccess: TranscriptionTaskAccessing {
    var executor: any MediaJobEventSource = MediaFlowExecutor.shared

    func events(for request: TranscriptionTaskRequest) -> AsyncStream<MediaJobEvent> {
        executor.events(for: request.flowRequest)
    }

    func cancel(_ id: UUID) async throws {}

    func persistCloudCopyIfNeeded(_ request: TranscriptionResultSyncRequest) async throws -> UUID? {
        nil
    }

    func confirmEphemeralDeletionIfNeeded(remoteSessionID: UUID) async throws {}
}

struct RoutedTranscriptionTaskAccess: TranscriptionTaskAccessing {
    var local: any TranscriptionTaskAccessing
    var cloud: any TranscriptionTaskAccessing

    init(
        local: any TranscriptionTaskAccessing = LocalTranscriptionTaskAccess(),
        cloud: any TranscriptionTaskAccessing = CloudTranscriptionTaskAccess()
    ) {
        self.local = local
        self.cloud = cloud
    }

    func events(for request: TranscriptionTaskRequest) -> AsyncStream<MediaJobEvent> {
        access(for: request.placement).events(for: request)
    }

    func cancel(_ id: UUID) async throws {
        try await local.cancel(id)
        try await cloud.cancel(id)
    }

    func persistCloudCopyIfNeeded(_ request: TranscriptionResultSyncRequest) async throws -> UUID? {
        guard TranscriptionPlacementRouter.shouldSyncLocalResults(request.placement) else {
            return request.remoteSessionID
        }
        return try await cloud.persistCloudCopyIfNeeded(request)
    }

    func confirmEphemeralDeletionIfNeeded(remoteSessionID: UUID) async throws {
        try await cloud.confirmEphemeralDeletionIfNeeded(remoteSessionID: remoteSessionID)
    }

    private func access(for placement: TranscriptionPlacement) -> any TranscriptionTaskAccessing {
        TranscriptionPlacementRouter.shouldStartCloudPipeline(placement) ? cloud : local
    }
}
