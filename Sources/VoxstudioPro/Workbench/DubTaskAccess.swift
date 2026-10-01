import Foundation

struct DubTaskRequest: Sendable {
    var jobID: UUID
    var script: String
    var segments: [DubSegmentPayload]
    var language: String
    var model: DubModelChoice
    var referenceVoiceID: UUID?
    var reference: DubVoiceReference?
    var speakerReferences: [String: DubVoiceReference]
    var segmentReferences: [Int: DubVoiceReference]
    var referenceAudioID: UUID?
    var referenceAudioR2Key: String?
    var referenceText: String
    var placement: TaskPlacement
    var remoteSessionID: UUID?
    var generationID: String
    var clientRequestID: String
    var title: String?
    var cacheURL: URL
    var hasSubtitleModel: Bool
    var syncCloudResultOnly = false
    var resumeRemoteSession = false

    var localFlowRequest: MediaFlowRequest {
        MediaFlowRequest(
            id: jobID,
            input: .script(script),
            steps: WorkbenchMediaFlowPlanner.dubSteps(
                payload: DubFlowPayload(
                    segments: segments,
                    language: language,
                    model: model,
                    reference: reference,
                    speakerReferences: speakerReferences,
                    segmentReferences: segmentReferences,
                    timelineMode: .automatic,
                    seed: DubSeed.deterministic(
                        language: language,
                        text: "\(jobID.uuidString)\n\(script)"
                    ),
                    xvecOnly: false
                ),
                hasAPIKey: hasSubtitleModel
            )
        )
    }
}

enum DubTaskEvent: Sendable {
    case media(MediaJobEvent)
    case remoteSession(id: UUID, generationID: String)
    case cloudSyncPending(localPath: String, message: String, generationID: String)
    case cloudSyncCompleted(remoteResultVersion: String?, generationID: String)
    case failure(message: String, generationID: String)
}

protocol DubTaskAccessing: Sendable {
    func events(for request: DubTaskRequest) -> AsyncStream<DubTaskEvent>
    func cancel(_ id: UUID) async throws
}

struct LocalDubTaskAccess: DubTaskAccessing {
    var executor: any MediaJobEventSource = MediaFlowExecutor.shared

    func events(for request: DubTaskRequest) -> AsyncStream<DubTaskEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in executor.events(for: request.localFlowRequest) {
                    if Task.isCancelled { break }
                    continuation.yield(.media(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel(_ id: UUID) async throws {}
}

struct RoutedDubTaskAccess: DubTaskAccessing {
    var local: any DubTaskAccessing
    var cloud: any DubTaskAccessing

    init(
        local: any DubTaskAccessing = LocalDubTaskAccess(),
        cloud: any DubTaskAccessing = CloudDubTaskAccess()
    ) {
        self.local = local
        self.cloud = cloud
    }

    func events(for request: DubTaskRequest) -> AsyncStream<DubTaskEvent> {
        let access = request.placement.compute == .cloud || request.placement.storage == .cloud
            ? cloud
            : local
        return access.events(for: request)
    }

    func cancel(_ id: UUID) async throws {
        try await local.cancel(id)
        try await cloud.cancel(id)
    }
}
