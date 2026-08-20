import Foundation

private struct RemoteDubCancellation: Sendable {
    let sessionID: UUID
    let preserveSession: Bool
}

private enum CloudDubWaitError: Error {
    case failed(String)
}

private actor RemoteDubSessionMap {
    private var sessions: [UUID: RemoteDubCancellation] = [:]
    private var pendingCancellations: Set<UUID> = []

    func bind(_ value: RemoteDubCancellation, to jobID: UUID) -> Bool {
        if pendingCancellations.remove(jobID) != nil {
            return true
        }
        sessions[jobID] = value
        return false
    }

    func requestCancellation(for jobID: UUID) -> RemoteDubCancellation? {
        guard let session = sessions[jobID] else {
            pendingCancellations.insert(jobID)
            return nil
        }
        return session
    }

    func remove(_ jobID: UUID) {
        sessions.removeValue(forKey: jobID)
        pendingCancellations.remove(jobID)
    }
}

struct CloudDubTaskAccess: DubTaskAccessing {
    var client: VoxellaAPIClient = .shared
    var prepareCloudAccess: @Sendable () async -> CloudAccessPreparation

    private static let remoteSessions = RemoteDubSessionMap()

    init(
        client: VoxellaAPIClient = .shared,
        prepareCloudAccess: @escaping @Sendable () async -> CloudAccessPreparation = CloudTaskAccessDefaults.prepare
    ) {
        self.client = client
        self.prepareCloudAccess = prepareCloudAccess
    }

    func events(for request: DubTaskRequest) -> AsyncStream<DubTaskEvent> {
        AsyncStream { continuation in
            let task = Task {
                await Self.run(
                    request: request,
                    client: client,
                    prepareCloudAccess: prepareCloudAccess,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel(_ id: UUID) async throws {
        guard let remote = await Self.remoteSessions.requestCancellation(for: id) else { return }
        try await client.cancelSession(remote.sessionID, preserveSession: remote.preserveSession)
        if !remote.preserveSession {
            try await client.deleteSession(remote.sessionID)
        }
    }

    private static func run(
        request: DubTaskRequest,
        client: VoxellaAPIClient,
        prepareCloudAccess: @Sendable () async -> CloudAccessPreparation,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async {
        if request.placement.needsAuthentication {
            switch await prepareCloudAccess() {
            case .ready:
                break
            case .cancelled:
                await yieldCancelled(request: request, continuation: continuation)
                await remoteSessions.remove(request.jobID)
                continuation.finish()
                return
            case .failed(let message):
                continuation.yield(.failure(message: message, generationID: request.generationID))
                continuation.yield(.media(.progress(Self.progress(
                    request: request,
                    stage: .dubAssembly,
                    status: .failed,
                    step: "cloud_access",
                    progress: 0,
                    message: message
                ))))
                await remoteSessions.remove(request.jobID)
                continuation.finish()
                return
            }
        }

        do {
            if request.placement.compute == .local {
                if request.syncCloudResultOnly {
                    try await runHybridSyncOnly(
                        request: request,
                        client: client,
                        continuation: continuation
                    )
                } else {
                    try await runHybrid(
                        request: request,
                        client: client,
                        continuation: continuation
                    )
                }
            } else {
                try await runCloud(
                    request: request,
                    client: client,
                    continuation: continuation
                )
            }
        } catch is CancellationError {
            await yieldCancelled(request: request, continuation: continuation)
        } catch VoxellaAPIError.cancelled {
            await yieldCancelled(request: request, continuation: continuation)
        } catch {
            continuation.yield(.failure(message: error.localizedDescription, generationID: request.generationID))
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .failed,
                step: "failed",
                progress: 0,
                message: error.localizedDescription
            ))))
        }
        await remoteSessions.remove(request.jobID)
        continuation.finish()
    }

    private static func yieldCancelled(
        request: DubTaskRequest,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async {
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .cancelled,
            step: "cancelled",
            progress: 0,
            message: "Cancelled — ready to retry"
        ))))
        await remoteSessions.remove(request.jobID)
    }

    private static func runCloud(
        request: DubTaskRequest,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws {
        let preserve = request.placement.storage == .cloud
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubPreprocessing,
            status: .started,
            step: "preparing",
            progress: request.resumeRemoteSession ? 0.04 : 0.02,
            message: request.resumeRemoteSession
                ? "Reconnecting to VoxStudio Cloud…"
                : "Preparing VoxStudio Cloud…"
        ))))
        let remoteSessionID: UUID
        if request.resumeRemoteSession {
            guard let existingID = request.remoteSessionID else {
                throw VoxellaAPIError.http(409, "The cloud session for this dub is unavailable.")
            }
            let detail = try await client.sessionDetail(existingID, includeDubSegments: true)
            try validateResumedSession(detail, for: request)
            remoteSessionID = existingID
        } else {
            guard let referenceKey = request.referenceAudioR2Key,
                  !referenceKey.isEmpty else {
                throw VoxellaAPIError.http(422, "A cloud voice reference is required for this dub.")
            }
            let created = try await client.createDubSession(
                sessionID: request.remoteSessionID,
                regenerate: request.remoteSessionID != nil,
                language: request.language,
                script: request.script,
                segments: request.segments,
                referenceAudioID: request.referenceAudioID,
                referenceAudioR2Key: referenceKey,
                referenceText: request.referenceText,
                model: request.model,
                placement: request.placement,
                generationID: request.generationID,
                clientRequestID: request.clientRequestID,
                title: request.title
            )
            try validatePlacement(created, for: request)
            remoteSessionID = created.sessionID
        }
        let cancelledBeforeBind = await remoteSessions.bind(
            RemoteDubCancellation(sessionID: remoteSessionID, preserveSession: preserve),
            to: request.jobID
        )
        continuation.yield(.remoteSession(id: remoteSessionID, generationID: request.generationID))
        if cancelledBeforeBind {
            try await client.cancelSession(remoteSessionID, preserveSession: preserve)
            if !preserve { try await client.deleteSession(remoteSessionID) }
            throw VoxellaAPIError.cancelled
        }
        let detail = try await waitForCompletion(
            request: request,
            sessionID: remoteSessionID,
            client: client,
            continuation: continuation
        )
        let output = try await downloadDubResult(
            request: request,
            sessionID: remoteSessionID,
            detail: detail,
            client: client,
            continuation: continuation
        )
        continuation.yield(.media(.artifact(.dub(output))))
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .processing,
            step: "finalizing",
            progress: 0.98,
            message: "Finalizing"
        ))))
        if !preserve {
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .processing,
                step: "cleanup",
                progress: 0.99,
                message: "Cleaning up temporary cloud session…"
            ))))
            try await client.cancelSession(remoteSessionID, preserveSession: false)
            try await client.deleteSession(remoteSessionID)
        }
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .completed,
            step: "completed",
            progress: 1,
            message: "Completed"
        ))))
    }

    private static func runHybrid(
        request: DubTaskRequest,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws {
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubPreprocessing,
            status: .started,
            step: "creating_cloud_session",
            progress: 0.02,
            message: request.resumeRemoteSession
                ? "Reconnecting to the editable cloud session…"
                : "Creating an editable cloud session…"
        ))))
        let remoteSessionID: UUID
        if request.resumeRemoteSession {
            guard let existingID = request.remoteSessionID else {
                throw VoxellaAPIError.http(409, "The cloud session for this dub is unavailable.")
            }
            let detail = try await client.sessionDetail(existingID, includeDubSegments: true)
            try validateResumedSession(detail, for: request)
            remoteSessionID = existingID
        } else {
            guard let referenceKey = request.referenceAudioR2Key,
                  !referenceKey.isEmpty else {
                throw VoxellaAPIError.http(422, "A cloud voice reference is required for this dub.")
            }
            let created = try await client.createDubSession(
                sessionID: request.remoteSessionID,
                regenerate: request.remoteSessionID != nil,
                language: request.language,
                script: request.script,
                segments: request.segments,
                referenceAudioID: request.referenceAudioID,
                referenceAudioR2Key: referenceKey,
                referenceText: request.referenceText,
                model: request.model,
                placement: request.placement,
                generationID: request.generationID,
                clientRequestID: request.clientRequestID,
                title: request.title
            )
            try validatePlacement(created, for: request)
            remoteSessionID = created.sessionID
        }
        let cancelledBeforeBind = await remoteSessions.bind(
            RemoteDubCancellation(sessionID: remoteSessionID, preserveSession: true),
            to: request.jobID
        )
        continuation.yield(.remoteSession(id: remoteSessionID, generationID: request.generationID))
        if cancelledBeforeBind {
            try await client.cancelSession(remoteSessionID, preserveSession: true)
            throw VoxellaAPIError.cancelled
        }

        var output: DubFlowResult?
        let local = LocalDubTaskAccess()
        for await event in local.events(for: request) {
            try Task.checkCancellation()
            switch event {
            case .media(.artifact(.dub(let result))):
                let cached = try await stageLocalResult(result, at: request.cacheURL)
                output = cached
                continuation.yield(.media(.artifact(.dub(cached))))
            case .media(.progress(let progress)) where progress.status == .completed:
                continuation.yield(.media(.progress(Self.progress(
                    request: request,
                    stage: .dubAssembly,
                    status: .processing,
                    step: "sync_prepare",
                    progress: 0.82,
                    message: "Saving result to VoxStudio Cloud…"
                ))))
            default:
                continuation.yield(event)
            }
        }
        try Task.checkCancellation()
        guard let output else {
            throw VoxellaAPIError.http(0, "The local dub did not produce an audio result.")
        }
        try await syncHybridResult(
                request: request,
                output: output,
                sessionID: remoteSessionID,
            client: client,
            continuation: continuation
        )
    }

    private static func runHybridSyncOnly(
        request: DubTaskRequest,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws {
        guard let sessionID = request.remoteSessionID else {
            throw VoxellaAPIError.http(409, "The cloud session for this local result is unavailable.")
        }
        let cancelledBeforeBind = await remoteSessions.bind(
            RemoteDubCancellation(sessionID: sessionID, preserveSession: true),
            to: request.jobID
        )
        continuation.yield(.remoteSession(id: sessionID, generationID: request.generationID))
        if cancelledBeforeBind {
            try await client.cancelSession(sessionID, preserveSession: true)
            throw VoxellaAPIError.cancelled
        }
        try Task.checkCancellation()
        let output = DubFlowResult(
            outputURL: request.cacheURL,
            segments: request.segments.compactMap { segment in
                guard let start = segment.start, let end = segment.end, end > start else { return nil }
                return DubRenderedSegment(
                    index: segment.index,
                    text: segment.text,
                    start: start,
                    end: end,
                    speaker: segment.speaker,
                    sourceSubtitleID: segment.sourceSubtitleID
                )
            }
        )
        try await syncHybridResult(
            request: request,
            output: output,
            sessionID: sessionID,
            client: client,
            continuation: continuation
        )
    }

    private static func syncHybridResult(
        request: DubTaskRequest,
        output: DubFlowResult,
        sessionID: UUID,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws {
        do {
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .processing,
                step: "upload",
                progress: 0.86,
                message: "Uploading result to VoxStudio Cloud…"
            ))))
            let sync = try await uploadLocalResult(
                request: request,
                output: output,
                sessionID: sessionID,
                client: client,
                continuation: continuation
            )
            continuation.yield(.cloudSyncCompleted(
                remoteResultVersion: sync.generationID,
                generationID: request.generationID
            ))
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .completed,
                step: "completed",
                progress: 1,
                message: "Completed · saved to VoxStudio Cloud"
            ))))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            continuation.yield(.cloudSyncPending(
                localPath: output.outputURL.path,
                message: error.localizedDescription,
                generationID: request.generationID
            ))
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .completed,
                step: "local_completed_cloud_sync_pending",
                progress: 1,
                message: "Completed locally · cloud sync pending"
            ))))
        }
    }

    private static func stageLocalResult(
        _ result: DubFlowResult,
        at destination: URL
    ) async throws -> DubFlowResult {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw VoxellaAPIError.http(0, "The local dub result is empty or unavailable.")
            }
            try FileIO.moveReplacingDestination(from: result.outputURL, to: destination)
            let installed = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard let installedSize = installed[.size] as? NSNumber, installedSize.int64Value == size.int64Value else {
                throw VoxellaAPIError.http(0, "The local dub result changed while it was being staged.")
            }
        }.value
        return DubFlowResult(outputURL: destination, segments: result.segments)
    }

    private static func waitForCompletion(
        request: DubTaskRequest,
        sessionID: UUID,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws -> VoxellaSessionDetail {
        let runStartedAt = Date()
        var reconnectAttempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let initial = try await client.sessionDetail(sessionID, includeDubSegments: true)
                try throwIfTerminal(initial)
                if isReady(initial) {
                    return yieldFinalizing(initial, request: request, continuation: continuation)
                }

                if let progress = progressEvent(
                    event: snapshotEvent(from: initial),
                    request: request
                ) {
                    continuation.yield(.media(.progress(progress)))
                }

                let completed: VoxellaSessionDetail? = try await withThrowingTaskGroup(of: VoxellaSessionDetail?.self) { group in
                    group.addTask {
                        do {
                            let eventStream = await client.events(
                                sessionID: sessionID,
                                runStartedAt: runStartedAt
                            )
                            for try await event in eventStream {
                                try Task.checkCancellation()
                                if let timestamp = event.timestampMilliseconds,
                                   timestamp < Int(runStartedAt.timeIntervalSince1970 * 1_000) {
                                    continue
                                }
                                if let generationID = event.generationID,
                                   generationID != request.generationID {
                                    continue
                                }
                                if let balance = event.balance, balance.isFinite {
                                    await MainActor.run {
                                        AccountService.shared.updateCloudAvailableCredits(balance)
                                    }
                                }
                                if event.isInternalConnectionEvent { continue }
                                if let progress = progressEvent(event: event, request: request) {
                                    continuation.yield(.media(.progress(progress)))
                                    switch progress.status {
                                    case .failed:
                                        throw CloudDubWaitError.failed(progress.message)
                                    case .cancelled:
                                        throw VoxellaAPIError.cancelled
                                    case .started, .processing, .completed:
                                        break
                                    }
                                }
                                guard isFinalCandidate(event) else { continue }
                                let reconciled = try await client.sessionDetail(
                                    sessionID,
                                    includeDubSegments: true
                                )
                                try throwIfTerminal(reconciled)
                                if isReady(reconciled) { return reconciled }
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch VoxellaAPIError.cancelled {
                            throw VoxellaAPIError.cancelled
                        } catch CloudDubWaitError.failed(let message) {
                            throw CloudDubWaitError.failed(message)
                        } catch {
                            // The polling task remains authoritative when SSE disconnects.
                            return nil
                        }
                        return nil
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(2))
                            try Task.checkCancellation()
                            let snapshot = try await client.sessionDetail(
                                sessionID,
                                includeDubSegments: true
                            )
                            try throwIfTerminal(snapshot)
                            if isReady(snapshot) { return snapshot }
                        }
                    }
                    while let result = try await group.next() {
                        if let result {
                            group.cancelAll()
                            return result
                        }
                    }
                    return nil
                }
                if let completed {
                    return yieldFinalizing(completed, request: request, continuation: continuation)
                }
                reconnectAttempt = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch VoxellaAPIError.cancelled {
                throw VoxellaAPIError.cancelled
            } catch CloudDubWaitError.failed(let message) {
                throw VoxellaAPIError.http(409, message)
            } catch {
                reconnectAttempt += 1
                if reconnectAttempt > 6 { throw error }
            }
            try await Task.sleep(for: .seconds(Double(min(3, max(1, reconnectAttempt)))))
        }
    }

    static func isReady(_ detail: VoxellaSessionDetail) -> Bool {
        VoxellaSessionReadiness.isResultReady(
            status: detail.status,
            currentStage: detail.currentStage,
            resultReady: detail.resultReady
        )
    }

    private static func throwIfTerminal(_ detail: VoxellaSessionDetail) throws {
        switch normalizedStatus(detail.status) {
        case "failed", "error":
            let message = detail.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CloudDubWaitError.failed(
                message.isEmpty ? "The cloud dub failed." : message
            )
        case "stopped", "cancelled", "canceled":
            throw VoxellaAPIError.cancelled
        default:
            break
        }
    }

    private static func normalizedStatus(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func yieldFinalizing(
        _ detail: VoxellaSessionDetail,
        request: DubTaskRequest,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) -> VoxellaSessionDetail {
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .processing,
            step: "finalizing",
            progress: 0.96,
            message: "Finalizing"
        ))))
        return detail
    }

    private static func snapshotEvent(from detail: VoxellaSessionDetail) -> VoxellaSSEEvent {
        var data: [String: VoxellaJSONValue] = [
            "event": .string("session_state"),
        ]
        if let stage = detail.currentStage { data["stage"] = .string(stage) }
        if let status = detail.status { data["status"] = .string(status) }
        if let resultReady = detail.resultReady { data["result_ready"] = .bool(resultReady) }
        if let message = detail.message { data["message"] = .string(message) }
        return VoxellaSSEEvent(event: "session_state", data: data)
    }

    private static func validatePlacement(
        _ response: VoxellaDubSessionCreateResponse,
        for request: DubTaskRequest
    ) throws {
        guard response.hasPlacementMetadata,
              response.hasGenerationMetadata,
              let expectedScope = request.placement.remotePersistenceScope,
              let expectedCompute = TranscriptionPlacementRouter.remoteClientCompute(request.placement),
              response.persistenceScope == expectedScope,
              response.clientCompute == expectedCompute,
              response.generationID == request.generationID else {
            throw VoxellaAPIError.http(
                409,
                "VoxStudio Cloud needs an updated app and service before this dub can continue."
            )
        }
    }

    private static func validateResumedSession(
        _ detail: VoxellaSessionDetail,
        for request: DubTaskRequest
    ) throws {
        guard detail.generationID == request.generationID else {
            throw VoxellaAPIError.http(409, "The cloud dub session belongs to a different generation.")
        }
    }

    private static func isFinalCandidate(_ event: VoxellaSSEEvent) -> Bool {
        let name = event.eventName.lowercased()
        if name == "session_state" && event.status?.lowercased() == "completed" { return true }
        return event.producer?.lowercased() == "api_consumer"
            && event.commitPhase?.lowercased() == "committed"
    }

    private static func progressEvent(
        event: VoxellaSSEEvent,
        request: DubTaskRequest
    ) -> MediaJobProgressEvent? {
        let name = event.eventName.lowercased()
        guard !event.isInternalConnectionEvent || name == "balance_update" else { return nil }
        if name == "balance_update" { return nil }
        let status: MediaJobStatus = switch name {
        case "dub_failed": .failed
        case "session_cancelled": .cancelled
        default: .processing
        }
        let stage: MediaFlowStage
        let step: String
        let message: String
        switch name {
        case "session_state":
            stage = .dubPreprocessing
            step = event.step ?? event.stage ?? "queued"
            message = event.message ?? "Queued"
        case "dub_started", "dub_script_started", "dub_script_completed", "dub_reference_ready":
            stage = .dubSynthesis
            step = event.step ?? name
            let current = event.scriptIndex.map { $0 + 1 }
            let total = event.scriptTotal
            if let current, let total, total > 0 {
                message = "Synthesizing \(current)/\(total)"
            } else {
                message = event.message ?? "Synthesizing"
            }
            return Self.progress(
                request: request,
                stage: stage,
                status: status,
                step: step,
                progress: normalizedProgress(event.progress),
                stageProgress: normalizedProgress(event.stageProgress ?? event.progress),
                current: current,
                total: total,
                message: message
            )
        case "dub_alignment_started", "dub_alignment_completed", "alignment_started", "alignment_completed":
            stage = .alignment
            step = event.step ?? name
            message = event.message ?? "Aligning audio"
        case "dub_upload_started", "dub_upload_completed":
            stage = .dubAssembly
            step = event.step ?? name
            message = event.message ?? "Saving result"
        case "dub_completed":
            stage = .dubAssembly
            step = event.step ?? "finalizing"
            message = "Finalizing"
        case "dub_failed":
            stage = .dubAssembly
            step = event.step ?? "failed"
            message = event.message ?? event.failureReason ?? "Cloud dubbing failed."
        case "session_cancelled":
            stage = .dubAssembly
            step = "cancelled"
            message = event.message ?? "Cancelled — ready to retry"
        default:
            stage = .dubPreprocessing
            step = event.step ?? event.stage ?? name
            message = event.message ?? "Preparing"
        }
        return Self.progress(
            request: request,
            stage: stage,
            status: status,
            step: step,
            progress: normalizedProgress(event.progress),
            stageProgress: normalizedProgress(event.stageProgress ?? event.progress),
            message: message
        )
    }

    private static func downloadDubResult(
        request: DubTaskRequest,
        sessionID: UUID,
        detail: VoxellaSessionDetail,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws -> DubFlowResult {
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .processing,
            step: "download",
            progress: 0.94,
            message: "Saving result"
        ))))
        let playback = try await client.dubAudioPlaybackURL(sessionID: sessionID)
        guard let url = URL(string: playback.url) else { throw VoxellaAPIError.missingUploadURL }
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoxellaAPIError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "The cloud dub result could not be downloaded.")
        }
        try Task.checkCancellation()
        let segments = renderedSegments(from: detail.dubSegments, fallback: request.segments)
        try await Task.detached(priority: .utility) {
            _ = try FileIO.moveReplacingDestination(from: downloadedURL, to: request.cacheURL)
        }.value
        continuation.yield(.media(.progress(Self.progress(
            request: request,
            stage: .dubAssembly,
            status: .processing,
            step: "cache_installed",
            progress: 0.97,
            message: "Result saved on This Mac"
        ))))
        return DubFlowResult(outputURL: request.cacheURL, segments: segments)
    }

    private static func uploadLocalResult(
        request: DubTaskRequest,
        output: DubFlowResult,
        sessionID: UUID,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation
    ) async throws -> VoxellaDubClientResultResponse {
        let size = try await fileSize(output.outputURL)
        let mimeType = mimeType(for: output.outputURL)
        let upload = try await client.prepareDubClientResultUpload(
            sessionID: sessionID,
            generationID: request.generationID,
            filename: output.outputURL.lastPathComponent,
            contentType: mimeType,
            sizeBytes: size,
            clientUploadID: "\(request.clientRequestID)-result"
        )
        try await uploadFile(
            output.outputURL,
            size: size,
            uploadID: upload.uploadID,
            partSize: upload.partSizeBytes,
            partCount: upload.partCount,
            client: client,
            continuation: continuation,
            request: request
        )
        let duration = output.segments.map(\.end).max() ?? 0.01
        return try await client.submitDubClientResult(
            sessionID: sessionID,
            uploadID: upload.uploadID,
            generationID: request.generationID,
            durationSeconds: max(duration, 0.01),
            mimeType: mimeType,
            segments: output.segments,
            resultID: request.generationID
        )
    }

    private static func uploadFile(
        _ url: URL,
        size: Int64,
        uploadID: UUID,
        partSize: Int,
        partCount: Int,
        client: VoxellaAPIClient,
        continuation: AsyncStream<DubTaskEvent>.Continuation,
        request: DubTaskRequest
    ) async throws {
        guard size > 0, partSize > 0, partCount > 0 else {
            throw VoxellaAPIError.http(0, "VoxStudio returned an invalid result upload plan.")
        }
        let expectedParts = Int((size - 1) / Int64(partSize) + 1)
        guard expectedParts == partCount else {
            throw VoxellaAPIError.http(0, "The result upload plan does not match the local file.")
        }
        var completed = try await client.uploadStatus(uploadID: uploadID).parts
        for part in 1...partCount {
            try Task.checkCancellation()
            let start = Int64(part - 1) * Int64(partSize)
            let length = Int(min(Int64(partSize), size - start))
            if completed.contains(where: { $0.partNumber == part && $0.etag?.isEmpty == false && $0.sizeBytes == length }) {
                continue
            }
            let data = try await Task.detached(priority: .utility) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                let data = try handle.read(upToCount: length) ?? Data()
                guard data.count == length else {
                    throw VoxellaAPIError.http(0, "The local result changed during upload.")
                }
                return data
            }.value
            let partURL = try await client.partURL(uploadID: uploadID, partNumber: part)
            guard let signedURL = URL(string: partURL.signedURL) else { throw VoxellaAPIError.missingUploadURL }
            _ = try await client.putData(
                data,
                to: signedURL,
                method: partURL.method,
                headers: partURL.headers
            )
            completed = try await client.uploadStatus(uploadID: uploadID).parts
            continuation.yield(.media(.progress(Self.progress(
                request: request,
                stage: .dubAssembly,
                status: .processing,
                step: "upload",
                progress: 0.86 + 0.10 * Double(part) / Double(partCount),
                message: "Saving result · part \(part)/\(partCount)"
            ))))
        }
        try await client.completeResumableUpload(uploadID: uploadID)
    }

    private static func renderedSegments(
        from remote: [VoxellaDubSegment],
        fallback: [DubSegmentPayload]
    ) -> [DubRenderedSegment] {
        if !remote.isEmpty {
            return remote.enumerated().compactMap { offset, segment in
                guard segment.endS > segment.startS else { return nil }
                return DubRenderedSegment(
                    index: segment.index,
                    text: segment.text,
                    start: segment.startS,
                    end: segment.endS,
                    speaker: segment.speakerLabel,
                    sourceSubtitleID: segment.sourceSubtitleID
                )
            }
        }
        return fallback.enumerated().compactMap { offset, segment in
            guard let start = segment.start, let end = segment.end, end > start else { return nil }
            return DubRenderedSegment(
                index: offset,
                text: segment.text,
                start: start,
                end: end,
                speaker: segment.speaker,
                sourceSubtitleID: segment.sourceSubtitleID
            )
        }
    }

    private static func progress(
        request: DubTaskRequest,
        stage: MediaFlowStage,
        status: MediaJobStatus,
        step: String,
        progress: Double,
        stageProgress: Double? = nil,
        current: Int? = nil,
        total: Int? = nil,
        message: String
    ) -> MediaJobProgressEvent {
        MediaJobProgressEvent(
            jobID: request.jobID,
            stage: stage,
            status: status,
            step: step,
            progress: normalizedProgress(progress),
            stageProgress: normalizedProgress(stageProgress ?? progress),
            current: current,
            total: total,
            message: message
        )
    }

    private static func normalizedProgress(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value > 1 ? value / 100 : value))
    }

    private static func fileSize(_ url: URL) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw VoxellaAPIError.http(0, "The local result file is empty or unavailable.")
            }
            return size.int64Value
        }.value
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}
