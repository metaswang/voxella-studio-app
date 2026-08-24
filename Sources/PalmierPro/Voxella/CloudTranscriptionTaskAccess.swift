import AVFoundation
import Foundation

struct CloudTranscriptionTaskAccess: TranscriptionTaskAccessing {
    var client: VoxellaAPIClient = .shared
    var prepareCloudAccess: @Sendable () async -> CloudAccessPreparation

    private static let remoteIDs = RemoteSessionMap()

    init(
        client: VoxellaAPIClient = .shared,
        prepareCloudAccess: @escaping @Sendable () async -> CloudAccessPreparation = CloudTaskAccessDefaults.prepare
    ) {
        self.client = client
        self.prepareCloudAccess = prepareCloudAccess
    }

    func events(for request: TranscriptionTaskRequest) -> AsyncStream<MediaJobEvent> {
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
        guard let session = await Self.remoteIDs.requestCancellation(for: id) else { return }
        try await Self.cancelRemoteSession(session, client: client)
    }

    func persistCloudCopyIfNeeded(_ request: TranscriptionResultSyncRequest) async throws -> UUID? {
        try await requireCloudAccessIfNeeded(request.placement)
        if let remoteSessionID = request.remoteSessionID {
            do {
                let detail = try await client.sessionDetail(remoteSessionID)
                if CloudResultSyncPolicy.destination(
                    for: detail.options?.clientCompute
                ) == .updateExisting {
                    try Task.checkCancellation()
                    if detail.isClientResultMediaPipeline, !detail.mediaReady {
                        try await Self.waitForMediaPreparation(
                            client: client,
                            sessionID: remoteSessionID
                        )
                    }
                    try Task.checkCancellation()
                    try await client.submitLocalResults(
                        sessionID: remoteSessionID,
                        result: request.result,
                        subtitleTrack: request.subtitleTrack,
                        translationTracks: request.translationTracks,
                        title: request.title,
                        summary: request.summary,
                        sessionTag: request.sessionTag,
                        sourcePreview: request.sourcePreview?.payload
                    )
                    return remoteSessionID
                }
            } catch VoxellaAPIError.http(404, _) {
                // A deleted cloud copy must be replaced, never revived or overwritten.
            }
        }
        let created = try await uploadMedia(
            jobID: request.jobID,
            sourceURL: request.sourceURL,
            originalFilename: request.originalFilename,
            mimeType: request.mimeType,
            sizeBytes: request.sizeBytes,
            options: request.options,
            placement: request.placement,
            remoteSessionID: request.remoteSessionID,
            startPipeline: false,
            prepareMedia: true,
            sourcePreview: request.sourcePreview,
            clientRequestID: "desktop-local-results-\(request.jobID.uuidString.lowercased())",
            onSessionCreated: { remoteID in
                let cancellationRequested = await Self.remoteIDs.set(
                    .init(id: remoteID, cancellationMode: .deleteAfterCancellation),
                    for: request.jobID
                )
                if cancellationRequested {
                    try await Self.cancelRemoteSession(
                        .init(id: remoteID, cancellationMode: .deleteAfterCancellation),
                        client: client
                    )
                    throw VoxellaAPIError.cancelled
                }
            },
            onProgress: { _, _ in }
        )
        do {
            try Task.checkCancellation()
            try await Self.waitForMediaPreparation(
                client: client,
                sessionID: created.sessionID
            )
            try Task.checkCancellation()
            try await client.submitLocalResults(
                sessionID: created.sessionID,
                result: request.result,
                subtitleTrack: request.subtitleTrack,
                translationTracks: request.translationTracks,
                title: request.title,
                summary: request.summary,
                sessionTag: request.sessionTag,
                sourcePreview: request.sourcePreview?.payload
            )
            await Self.remoteIDs.remove(request.jobID)
            return created.sessionID
        } catch {
            await Self.remoteIDs.remove(request.jobID)
            do {
                try await Self.cancelRemoteSession(
                    .init(id: created.sessionID, cancellationMode: .deleteAfterCancellation),
                    client: client
                )
            } catch {
                Log.transcription.warning(
                    "cloud copy cleanup failed id=\(VoxellaAPIConfiguration.apiIdentifier(created.sessionID)) error=\(error.localizedDescription)",
                    telemetry: "Cloud copy cleanup failed",
                    data: ["sessionID": VoxellaAPIConfiguration.apiIdentifier(created.sessionID)]
                )
            }
            throw error
        }
    }

    func confirmEphemeralDeletionIfNeeded(remoteSessionID: UUID) async throws {
        try await client.confirmEphemeralCompletion(sessionID: remoteSessionID)
    }

    private static func run(
        request: TranscriptionTaskRequest,
        client: VoxellaAPIClient,
        prepareCloudAccess: @Sendable () async -> CloudAccessPreparation,
        continuation: AsyncStream<MediaJobEvent>.Continuation
    ) async {
        let yieldProgress: @Sendable (MediaJobStatus, String, Double, String) -> Void = { status, step, progress, message in
            continuation.yield(.progress(MediaJobProgressEvent(
                jobID: request.jobID,
                stage: .transcription,
                status: status,
                step: step,
                progress: progress,
                stageProgress: progress,
                message: message
            )))
        }

        if request.placement.needsAuthentication {
            switch await prepareCloudAccess() {
            case .ready:
                break
            case .cancelled:
                yieldProgress(.cancelled, "cancelled", 0, "Cancelled — ready to retry")
                continuation.finish()
                return
            case .failed(let message):
                yieldProgress(.failed, "cloud_access", 0, message)
                continuation.finish()
                return
            }
        }

        do {
            yieldProgress(.started, "flow_started", 0.02, "Preparing VoxStudio Cloud…")
            let remoteID: UUID
            var expectedWorkflowRunID: String?
            let runStartedAt = Date()
            var runAlreadyStarted = false
            if request.shouldReuseRemoteSession, let existingRemoteID = request.remoteSessionID {
                remoteID = existingRemoteID
                let cancellationRequested = await remoteIDs.set(
                    .init(id: remoteID, cancellationMode: .preserveSession),
                    for: request.jobID
                )
                yieldProgress(
                    .processing,
                    "bind_remote_session",
                    0.06,
                    "Re-transcribing in VoxStudio Cloud… \(VoxellaAPIConfiguration.apiIdentifier(remoteID))"
                )
                if cancellationRequested {
                    try await cancelRemoteSession(
                        .init(id: remoteID, cancellationMode: .preserveSession),
                        client: client
                    )
                    throw VoxellaAPIError.cancelled
                }
                let regenerated = try await client.regenerateTranscript(
                    sessionID: remoteID,
                    options: request.options
                )
                expectedWorkflowRunID = regenerated.queuedJobID
                runAlreadyStarted = isActiveRunStatus(regenerated.status)
            } else {
                let cancellationMode: RemoteSessionCancellationMode =
                    TranscriptionPlacementRouter.shouldPreserveRemoteSessionAfterCancellation(request.placement)
                        ? .preserveSession
                        : .deleteAfterCancellation
                let uploaded = try await uploadMedia(
                    jobID: request.jobID,
                    sourceURL: request.sourceURL,
                    originalFilename: request.originalFilename,
                    mimeType: request.mimeType,
                    sizeBytes: request.sizeBytes,
                    durationHintSec: request.durationHintSec,
                    options: request.options,
                    placement: request.placement,
                    remoteSessionID: request.remoteSessionID,
                    startPipeline: true,
                    prepareMedia: false,
                    sourcePreview: request.sourcePreview,
                    client: client,
                    clientRequestID: request.jobID.uuidString.lowercased(),
                    onSessionCreated: { remoteID in
                        let cancellationRequested = await remoteIDs.set(
                            .init(id: remoteID, cancellationMode: cancellationMode),
                            for: request.jobID
                        )
                        yieldProgress(
                            .processing,
                            "bind_remote_session",
                            0.06,
                            "Uploading to VoxStudio Cloud… \(VoxellaAPIConfiguration.apiIdentifier(remoteID))"
                        )
                        if cancellationRequested {
                            try await cancelRemoteSession(
                                .init(id: remoteID, cancellationMode: cancellationMode),
                                client: client
                            )
                            throw VoxellaAPIError.cancelled
                        }
                    }
                ) { progress, message in
                    yieldProgress(.processing, "upload", progress, message)
                }
                remoteID = uploaded.sessionID
                expectedWorkflowRunID = uploaded.workflowRunID
            }
            try await waitUntilProcessed(
                client: client,
                sessionID: remoteID,
                jobID: request.jobID,
                runStartedAt: runStartedAt,
                requiresFreshRun: request.shouldReuseRemoteSession,
                runAlreadyStarted: runAlreadyStarted,
                expectedWorkflowRunID: expectedWorkflowRunID
            ) { event in
                continuation.yield(event)
            }

            let segments = try await client.transcriptSegments(remoteID)
            let cues = try await client.subtitleCues(remoteID)
            let result = transcriptionResult(from: segments, language: request.options.languageCode)
            continuation.yield(.artifact(.transcription(
                result,
                DiarizationDiagnostics(
                    backend: .singleSpeaker,
                    elapsedSeconds: 0,
                    processedChunks: 0,
                    detectedSpeakerCount: Set(segments.compactMap(\.speakerLabel)).count,
                    requestedSpeakerCount: request.options.speakerCount.count,
                    warnings: []
                ),
                TranscriptionAlignmentDiagnostics(
                    trimmedHallucinatedSpanCount: 0,
                    rejectedAlignmentChunkCount: 0,
                    retriedAlignmentChunkCount: 0,
                    estimatedUnitCount: 0,
                    longestRejectedUnitDuration: nil,
                    removedDuplicatePrefixes: 0,
                    removedDuplicateSuffixes: 0,
                    removedContainedSpans: 0,
                    atomicSegmentFallbackCount: 0,
                    reconciledBoundaryCount: 0,
                    unresolvedBoundaryCount: 0,
                    retriedUncoveredRangeCount: 0,
                    retriedUncoveredSpeechSeconds: 0,
                    retriedUncoveredAcceptedCount: 0,
                    retriedUncoveredKeptFirstPassCount: 0,
                    rawLexicalUnitCount: 0,
                    qualityLexicalUnitCount: 0,
                    ownershipLexicalUnitCount: 0,
                    alignmentLexicalUnitCount: 0,
                    retryLexicalUnitCount: 0,
                    finalLexicalUnitCount: 0
                )
            )))
            if !cues.isEmpty {
                continuation.yield(.artifact(.subtitles(
                    SubtitleTrack(
                        sourceLanguage: request.options.languageCode,
                        language: request.options.languageCode,
                        cues: cues.enumerated().map { index, cue in
                            SubtitleCue(
                                id: index,
                                sourceIDs: [index],
                                text: cue.text,
                                start: cue.startS,
                                end: cue.endS,
                                speaker: cue.speakerLabel
                            )
                        }
                    ),
                    rebuiltSegments: result.segments
                )))
            }
            if TranscriptionPlacementRouter.shouldConfirmEphemeralDelete(request.placement) {
                try await client.confirmEphemeralCompletion(sessionID: remoteID)
            }
            yieldProgress(.completed, "flow_completed", 1, "Transcript ready")
            await remoteIDs.remove(request.jobID)
            continuation.finish()
        } catch is CancellationError {
            yieldProgress(.cancelled, "cancelled", 0, "Cancelled — ready to retry")
            await remoteIDs.remove(request.jobID)
            continuation.finish()
        } catch VoxellaAPIError.cancelled {
            yieldProgress(.cancelled, "cancelled", 0, "Cancelled — ready to retry")
            await remoteIDs.remove(request.jobID)
            continuation.finish()
        } catch {
            yieldProgress(.failed, "failed", 0, error.localizedDescription)
            await remoteIDs.remove(request.jobID)
            continuation.finish()
        }
    }

    private func requireCloudAccessIfNeeded(_ placement: TranscriptionPlacement) async throws {
        guard placement.needsAuthentication else { return }
        switch await prepareCloudAccess() {
        case .ready:
            return
        case .cancelled:
            throw CancellationError()
        case .failed(let message):
            throw CloudTaskAccessError(message: message)
        }
    }

    private func uploadMedia(
        jobID: UUID,
        sourceURL: URL,
        originalFilename: String,
        mimeType: String,
        sizeBytes: Int64?,
        durationHintSec: Double? = nil,
        options: TranscriptionProcessingOptions,
        placement: TranscriptionPlacement,
        remoteSessionID: UUID?,
        startPipeline: Bool,
        prepareMedia: Bool = false,
        sourcePreview: TranscriptionSourcePreview? = nil,
        clientRequestID: String,
        onSessionCreated: @escaping @Sendable (UUID) async throws -> Void,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> VoxellaCloudUploadOutcome {
        try await Self.uploadMedia(
            jobID: jobID,
            sourceURL: sourceURL,
            originalFilename: originalFilename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            durationHintSec: durationHintSec,
            options: options,
            placement: placement,
            remoteSessionID: remoteSessionID,
            startPipeline: startPipeline,
            prepareMedia: prepareMedia,
            sourcePreview: sourcePreview,
            client: client,
            clientRequestID: clientRequestID,
            onSessionCreated: onSessionCreated,
            onProgress: onProgress
        )
    }

    private static func uploadMedia(
        jobID: UUID,
        sourceURL: URL,
        originalFilename: String,
        mimeType: String,
        sizeBytes: Int64?,
        durationHintSec: Double? = nil,
        options: TranscriptionProcessingOptions,
        placement: TranscriptionPlacement,
        remoteSessionID: UUID?,
        startPipeline: Bool,
        prepareMedia: Bool,
        sourcePreview: TranscriptionSourcePreview?,
        client: VoxellaAPIClient,
        clientRequestID: String,
        onSessionCreated: @escaping @Sendable (UUID) async throws -> Void,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> VoxellaCloudUploadOutcome {
        let actualSize = try await fileSize(sourceURL)
        try Task.checkCancellation()
        if let sizeBytes, sizeBytes != actualSize {
            throw VoxellaAPIError.http(0, "The media file changed before upload.")
        }
        let durationSec = await mediaDurationSeconds(url: sourceURL, hint: durationHintSec)
        let created = try await client.createSession(
            filename: originalFilename,
            mimeType: mimeType,
            sizeBytes: actualSize,
            durationHintSec: durationSec,
            options: options,
            placement: placement,
            clientRequestID: clientRequestID
        )
        try await onSessionCreated(created.sessionID)
        try Task.checkCancellation()
        onProgress(0.08, "Uploading media…")
        let useMultipart = (created.resumable?.partCount ?? 0) > 1
        if useMultipart, let resumable = created.resumable {
            let partSize = max(resumable.partSizeBytes, 1)
            let partCount = resumable.partCount
            guard partCount > 0, actualSize > 0 else {
                throw VoxellaAPIError.http(0, "VoxStudio returned an invalid upload plan.")
            }
            let partSize64 = Int64(partSize)
            let expectedPartCount = ((actualSize - 1) / partSize64) + 1
            guard Int64(partCount) == expectedPartCount else {
                throw VoxellaAPIError.http(0, "VoxStudio returned an upload plan that does not match the media.")
            }
            var completedParts = try await client.uploadStatus(uploadID: resumable.uploadID).parts
            for part in 1...partCount {
                if Task.isCancelled { throw VoxellaAPIError.cancelled }
                let start = Int64(part - 1) * partSize64
                let end = min(actualSize, start + partSize64)
                let expectedLength = Int(end - start)
                if completedParts.contains(where: {
                    $0.partNumber == part && $0.etag?.isEmpty == false && $0.sizeBytes == expectedLength
                }) {
                    onProgress(
                        0.08 + 0.08 * Double(part) / Double(partCount),
                        "Uploading media…"
                    )
                    continue
                }
                let chunk = try await readFilePart(
                    sourceURL,
                    offset: start,
                    length: expectedLength
                )
                try await uploadPart(
                    client: client,
                    uploadID: resumable.uploadID,
                    partNumber: part,
                    chunk: chunk
                )
                completedParts = try await client.uploadStatus(uploadID: resumable.uploadID).parts
                onProgress(0.08 + 0.08 * Double(part) / Double(partCount), "Uploading media…")
            }
            completedParts = try await client.uploadStatus(uploadID: resumable.uploadID).parts
            guard (1...partCount).allSatisfy({ part in
                completedParts.contains {
                    $0.partNumber == part && $0.etag?.isEmpty == false
                }
            }) else {
                throw VoxellaAPIError.http(0, "VoxStudio could not verify every uploaded media part.")
            }
            try await client.completeResumableUpload(uploadID: resumable.uploadID)
        } else if let signed = created.upload, let url = URL(string: signed.signedURL) {
            _ = try await client.putFile(
                sourceURL,
                to: url,
                method: signed.method,
                headers: signed.headers,
                contentType: mimeType
            )
        } else if let resumable = created.resumable {
            guard actualSize <= Int64(Int.max) else {
                throw VoxellaAPIError.http(0, "The media file is too large for this upload plan.")
            }
            let chunk = try await readFilePart(sourceURL, offset: 0, length: Int(actualSize))
            try await uploadPart(
                client: client,
                uploadID: resumable.uploadID,
                partNumber: 1,
                chunk: chunk
            )
            try await client.completeResumableUpload(uploadID: resumable.uploadID)
        } else {
            throw VoxellaAPIError.missingUploadURL
        }
        guard try await fileSize(sourceURL) == actualSize else {
            throw VoxellaAPIError.http(0, "The media file changed during upload.")
        }
        let completed = try await client.completeSessionUpload(
            sessionID: created.sessionID,
            durationSec: durationSec,
            sizeBytes: actualSize,
            mimeType: mimeType,
            filename: originalFilename,
            startPipeline: startPipeline,
            prepareMedia: prepareMedia,
            sourcePreview: sourcePreview?.payload
        )
        if startPipeline {
            try await confirmPipelineStarted(
                client: client,
                sessionID: created.sessionID,
                completeStatus: completed.status
            )
        }
        _ = remoteSessionID
        return VoxellaCloudUploadOutcome(
            sessionID: created.sessionID,
            workflowRunID: completed.queuedJobID
        )
    }

    private static func waitForMediaPreparation(
        client: VoxellaAPIClient,
        sessionID: UUID,
        timeout: Duration = .seconds(600)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let detail = try await client.sessionDetail(sessionID)
            let status = (detail.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if detail.mediaReady || (detail.resultReady == true && status == "completed") {
                return
            }
            if status == "failed" || status == "stopped" {
                throw VoxellaAPIError.http(
                    409,
                    detail.message ?? "VoxStudio could not prepare the uploaded media."
                )
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VoxellaAPIError.http(408, "VoxStudio media preparation timed out.")
    }

    private static func fileSize(_ sourceURL: URL) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            guard let number = attributes[.size] as? NSNumber,
                  number.int64Value >= 0
            else {
                throw VoxellaAPIError.http(0, "The media file size could not be read.")
            }
            return number.int64Value
        }.value
    }

    private static func readFilePart(
        _ sourceURL: URL,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw VoxellaAPIError.http(0, "The media upload range is invalid.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else {
                throw VoxellaAPIError.http(0, "The media file changed while it was being uploaded.")
            }
            return data
        }.value
    }

    private static func uploadPart(
        client: VoxellaAPIClient,
        uploadID: UUID,
        partNumber: Int,
        chunk: Data
    ) async throws {
        var lastError: Error?
        for _ in 0..<3 {
            if Task.isCancelled { throw VoxellaAPIError.cancelled }
            let partURL = try await client.partURL(uploadID: uploadID, partNumber: partNumber)
            guard let url = URL(string: partURL.signedURL) else {
                throw VoxellaAPIError.missingUploadURL
            }
            do {
                let etag = try await client.putData(
                    chunk,
                    to: url,
                    method: partURL.method,
                    headers: partURL.headers,
                    contentType: nil
                )
                if let etag, !etag.isEmpty {
                    return
                }
                let status = try await client.uploadStatus(uploadID: uploadID)
                if status.parts.contains(where: {
                    $0.partNumber == partNumber && $0.etag?.isEmpty == false
                }) {
                    return
                }
                throw VoxellaAPIError.http(0, "VoxStudio did not confirm the uploaded media part.")
            } catch {
                lastError = error
            }
        }
        throw lastError ?? VoxellaAPIError.http(0, "Upload part failed.")
    }

    private static func mediaDurationSeconds(url: URL, hint: Double?) async -> Double? {
        if let hint, hint.isFinite, hint > 0 { return hint }
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func confirmPipelineStarted(
        client: VoxellaAPIClient,
        sessionID: UUID,
        completeStatus: String?
    ) async throws {
        var status = normalizedStatus(completeStatus)
        if status == "created" || status.isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            let detail = try await client.sessionDetail(sessionID)
            try throwIfTerminal(detail)
            status = normalizedStatus(detail.status)
        }
        guard status != "created" else {
            throw VoxellaAPIError.http(0, "VoxStudio did not start processing after upload.")
        }
    }

    private static func waitUntilProcessed(
        client: VoxellaAPIClient,
        sessionID: UUID,
        jobID: UUID,
        runStartedAt: Date,
        requiresFreshRun: Bool,
        runAlreadyStarted: Bool,
        expectedWorkflowRunID: String?,
        yield: @escaping @Sendable (MediaJobEvent) -> Void
    ) async throws {
        let progressMapper = CloudProgressMapper(jobID: jobID)
        let runObservation = CloudRunObservation(
            requiresFreshRun: requiresFreshRun,
            alreadyStarted: runAlreadyStarted,
            expectedWorkflowRunID: expectedWorkflowRunID
        )
        let initial = try await client.sessionDetail(sessionID)
        await runObservation.observe(
            status: initial.status,
            stage: initial.currentStage,
            workflowRunID: initial.activeWorkflowRunID
        )
        if !requiresFreshRun {
            try throwIfTerminal(initial)
        }
        if await runObservation.canAcceptReady,
           VoxellaSessionReadiness.isResultReady(
               status: initial.status,
               currentStage: initial.currentStage,
               resultReady: initial.resultReady
           ) {
            return
        }
        if !requiresFreshRun || !isTerminalStatus(initial.status) {
            yield(.progress(await progressMapper.progress(for: mapDetailEvent(initial))))
        }
        if !requiresFreshRun, normalizedStatus(initial.status) == "created" {
            throw VoxellaAPIError.http(0, "VoxStudio did not start processing after upload.")
        }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await event in await client.events(sessionID: sessionID, runStartedAt: runStartedAt) {
                        try Task.checkCancellation()
                        if let timestamp = event.timestampMilliseconds,
                           timestamp < Int(runStartedAt.timeIntervalSince1970 * 1_000) {
                            continue
                        }
                        if let balance = event.balance {
                            await MainActor.run {
                                AccountService.shared.updateCloudAvailableCredits(balance)
                            }
                        }
                        if event.isInternalConnectionEvent { continue }
                        let eventIsCurrent = event.timestampMilliseconds.map {
                            $0 >= Int(runStartedAt.timeIntervalSince1970 * 1_000)
                        } ?? (expectedWorkflowRunID != nil && event.workflowRunID == expectedWorkflowRunID)
                        await runObservation.observe(
                            status: event.status,
                            stage: event.stage,
                            workflowRunID: event.workflowRunID,
                            isCurrentEvent: eventIsCurrent
                        )
                        if isTerminalStatus(event.status),
                           !(await runObservation.canAcceptReady) {
                            continue
                        }
                        if isReadySessionSnapshot(event) {
                            guard await runObservation.canAcceptReady else { continue }
                            return true
                        }
                        let mapped = await progressMapper.progress(for: event)
                        yield(.progress(mapped))
                        switch mapped.status {
                        case .failed: throw CloudWaitError.failed(mapped.message)
                        case .cancelled: throw VoxellaAPIError.cancelled
                        case .started, .processing, .completed: break
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch VoxellaAPIError.cancelled {
                    throw VoxellaAPIError.cancelled
                } catch CloudWaitError.failed(let message) {
                    throw CloudWaitError.failed(message)
                } catch {
                    // Polling remains authoritative when the SSE connection cannot be kept open.
                    return false
                }
                return false
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(2))
                    try Task.checkCancellation()
                    let detail = try await client.sessionDetail(sessionID)
                    await runObservation.observe(
                        status: detail.status,
                        stage: detail.currentStage,
                        workflowRunID: detail.activeWorkflowRunID
                    )
                    if await runObservation.canAcceptReady {
                        try throwIfTerminal(detail)
                    }
                    if await runObservation.canAcceptReady,
                       VoxellaSessionReadiness.isResultReady(
                        status: detail.status,
                        currentStage: detail.currentStage,
                        resultReady: detail.resultReady
                    ) {
                        return true
                    }
                    let mapped = await progressMapper.progress(for: mapDetailEvent(detail))
                    yield(.progress(mapped))
                }
            }
            while let finished = try await group.next() {
                if finished {
                    group.cancelAll()
                    return
                }
            }
        }
        let detail = try await client.sessionDetail(sessionID)
        try throwIfTerminal(detail)
        guard VoxellaSessionReadiness.isResultReady(
            status: detail.status,
            currentStage: detail.currentStage,
            resultReady: detail.resultReady
        ) else {
            throw VoxellaAPIError.http(500, "Cloud transcription did not produce a ready result.")
        }
    }

    private static func throwIfTerminal(_ detail: VoxellaSessionDetail) throws {
        switch normalizedStatus(detail.status) {
        case "failed", "error":
            let message = detail.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VoxellaAPIError.http(500, message.isEmpty ? "Cloud transcription failed." : message)
        case "stopped", "cancelled", "canceled":
            throw VoxellaAPIError.cancelled
        default:
            break
        }
    }

    private static func normalizedStatus(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isTerminalStatus(_ value: String?) -> Bool {
        ["completed", "complete", "failed", "error", "stopped", "cancelled", "canceled"]
            .contains(normalizedStatus(value))
    }

    private static func isActiveRunStatus(_ value: String?) -> Bool {
        switch normalizedStatus(value) {
        case "started", "queued", "upload", "processing", "preprocess", "normalize", "transcribe", "postprocess", "dub":
            true
        default:
            false
        }
    }

    private static func mapDetailEvent(_ detail: VoxellaSessionDetail) -> VoxellaSSEEvent {
        var data: [String: VoxellaJSONValue] = [:]
        if let stage = detail.currentStage { data["stage"] = .string(stage) }
        if let status = detail.status { data["status"] = .string(status) }
        if let resultReady = detail.resultReady { data["result_ready"] = .bool(resultReady) }
        if let message = detail.message { data["message"] = .string(message) }
        if let chunkCount = detail.artifacts?["chunk_count"]?.numberValue {
            data["chunk_count"] = .number(chunkCount)
        }
        if let totalChunks = detail.artifacts?["total_chunks"]?.numberValue {
            data["total_chunks"] = .number(totalChunks)
        }
        if let completedChunks = detail.artifacts?["completed_chunks"]?.numberValue {
            data["completed_chunks"] = .number(completedChunks)
        }
        return VoxellaSSEEvent(event: "session_state", data: data)
    }

    static func progress(for event: VoxellaSSEEvent, jobID: UUID) -> MediaJobProgressEvent {
        let statusToken = normalizedStatus(event.status)
        let status: MediaJobStatus = switch statusToken {
        case "failed", "error" where !event.isFailOpenDiarizationDegradation:
            .failed
        case "stopped", "cancelled", "canceled":
            .cancelled
        case "completed", "complete":
            .processing
        default:
            .processing
        }
        let stageToken = event.stage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let eventToken = event.eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stageProgress: Double = switch stageToken.isEmpty ? eventToken : stageToken {
        case "upload": 0.2
        case "video_encode": 0.28
        case "preprocess": 0.35
        case "normalize": 0.42
        case "diarization": 0.5
        case "transcribe": 0.7
        case "postprocess": 0.9
        default: 0.45
        }
        let progress = normalizedProgress(event.progress) ?? stageProgress
        return MediaJobProgressEvent(
            jobID: jobID,
            stage: .transcription,
            status: status,
            step: event.stage ?? event.event,
            progress: status == .completed ? 1 : progress,
            stageProgress: stageProgress,
            current: event.completedChunks ?? event.chunkIndex.map { $0 + 1 },
            total: event.totalChunks,
            message: cloudMessage(for: event, stage: stageToken, eventName: eventToken)
        )
    }

    private static func cloudMessage(
        for event: VoxellaSSEEvent,
        stage: String,
        eventName: String
    ) -> String {
        if event.isFailOpenDiarizationDegradation {
            return "Speaker identification was unavailable; continuing transcription."
        }
        if let message = event.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty,
           message.lowercased() != stage,
           message.lowercased() != eventName {
            return message
        }
        let status = normalizedStatus(event.status)
        switch (stage.isEmpty ? eventName : stage, status) {
        case ("upload", "started"), ("upload", "processing"):
            return "Uploading media to VoxStudio Cloud…"
        case ("upload", "completed"):
            return "Media uploaded. Preparing cloud transcription…"
        case ("video_encode", "started"), ("video_encode", "processing"):
            return "Preparing video for cloud transcription…"
        case ("video_encode", "completed"):
            return "Video is ready for cloud transcription."
        case ("preprocess", "started"), ("preprocess", "processing"),
             ("normalize", "started"), ("normalize", "processing"):
            return "VoxStudio Cloud is preparing the media."
        case ("normalize", "completed"):
            return "Cloud audio preparation is complete."
        case ("transcribe", "started"), ("transcribe", "processing"),
             (_, _) where eventName.contains("transcribe"):
            return "VoxStudio Cloud is recognizing speech."
        case ("postprocess", "started"), ("postprocess", "processing"):
            return "VoxStudio Cloud is assembling the transcript and subtitles."
        case ("postprocess", "completed"):
            return "Cloud transcript assembly is complete."
        case (_, "failed"), (_, "error"):
            return "VoxStudio Cloud could not complete this stage."
        case (_, "stopped"), (_, "cancelled"), (_, "canceled"):
            return "VoxStudio Cloud processing was cancelled."
        default:
            return "Processing in VoxStudio Cloud…"
        }
    }

    private static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if (0...1).contains(value) { return value }
        if (0...100).contains(value) { return value / 100 }
        return nil
    }

    private static func cancelRemoteSession(
        _ session: RemoteSession,
        client: VoxellaAPIClient
    ) async throws {
        var cancelError: Error?
        for attempt in 0..<3 {
            do {
                try await client.cancelSession(
                    session.id,
                    preserveSession: session.cancellationMode == .preserveSession
                )
                cancelError = nil
                break
            } catch VoxellaAPIError.http(404, _) {
                cancelError = nil
                break
            } catch {
                cancelError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                }
            }
        }
        if let cancelError { throw cancelError }
        if session.cancellationMode == .deleteAfterCancellation {
            do {
                try await client.deleteSession(session.id)
            } catch VoxellaAPIError.http(404, _) {
                return
            } catch {
                Log.transcription.warning(
                    "cloud session cleanup failed id=\(VoxellaAPIConfiguration.apiIdentifier(session.id)) error=\(error.localizedDescription)",
                    telemetry: "Cloud session cleanup failed",
                    data: ["sessionID": VoxellaAPIConfiguration.apiIdentifier(session.id)]
                )
            }
        }
    }

    private static func isReadySessionSnapshot(_ event: VoxellaSSEEvent) -> Bool {
        let eventName = event.eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard eventName == "session_state" || eventName == "session" else { return false }
        return VoxellaSessionReadiness.isResultReady(
            status: event.status,
            currentStage: event.stage,
            resultReady: event.resultReady
        )
    }

    private static func transcriptionResult(
        from segments: [VoxellaTranscriptSegment],
        language: String?
    ) -> TranscriptionResult {
        let words = segments.flatMap { segment in
            segment.words.map {
                TranscriptionWord(
                    text: $0.word,
                    start: $0.startS,
                    end: $0.endS,
                    speaker: $0.speaker ?? segment.speakerLabel
                )
            }
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: language,
            words: words,
            segments: segments.map {
                TranscriptionSegment(
                    text: $0.text,
                    start: $0.startS,
                    end: $0.endS,
                    speaker: $0.speakerLabel
                )
            }
        )
    }
}

private struct CloudTaskAccessError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private enum CloudWaitError: Error {
    case failed(String)
}

private actor CloudRunObservation {
    private var hasStarted: Bool
    private let expectedWorkflowRunID: String?

    init(
        requiresFreshRun: Bool,
        alreadyStarted: Bool,
        expectedWorkflowRunID: String?
    ) {
        self.hasStarted = alreadyStarted || !requiresFreshRun
        self.expectedWorkflowRunID = expectedWorkflowRunID
    }

    func observe(
        status: String?,
        stage: String?,
        workflowRunID: String? = nil,
        isCurrentEvent: Bool = false
    ) {
        guard !hasStarted else { return }
        let normalizedStatus = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedStage = (stage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasTerminalStatus = ["completed", "complete", "failed", "error", "stopped", "cancelled", "canceled"].contains(normalizedStatus)
        let matchesExpectedRun = expectedWorkflowRunID != nil && workflowRunID == expectedWorkflowRunID
        if matchesExpectedRun {
            hasStarted = true
            return
        }
        if expectedWorkflowRunID != nil {
            return
        }
        if ["started", "queued", "processing"].contains(normalizedStatus)
            || (!hasTerminalStatus && ["upload", "video_encode", "preprocess", "normalize", "transcribe", "postprocess", "dub"].contains(normalizedStage))
            || (isCurrentEvent && ["completed", "complete", "failed", "error", "stopped", "cancelled", "canceled"].contains(normalizedStatus)) {
            hasStarted = true
        }
    }

    var canAcceptReady: Bool { hasStarted }
}

actor CloudProgressMapper {
    private let jobID: UUID
    private var completedChunkIndexes: Set<Int> = []
    private var completedTaskEvents = 0
    private var totalChunks: Int?
    private var highestCompletedChunks = 0
    private var highestProgress = 0.06

    init(jobID: UUID) {
        self.jobID = jobID
    }

    func progress(for event: VoxellaSSEEvent) -> MediaJobProgressEvent {
        if let total = event.totalChunks, total > 0 {
            totalChunks = total
        }
        let eventName = event.eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stage = (event.stage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isTranscribing = stage == "transcribe" || eventName.contains("transcribe")
        if eventName == "transcribe_chunk_completed", let index = event.chunkIndex {
            completedChunkIndexes.insert(index)
        } else if isTranscribing,
                  eventName == "task_completed",
                  event.completedChunks == nil,
                  event.chunkIndex == nil {
            completedTaskEvents += 1
        }

        var mapped = CloudTranscriptionTaskAccess.progress(for: event, jobID: jobID)
        if isTranscribing, let totalChunks, totalChunks > 0 {
            let completed = max(
                event.completedChunks ?? 0,
                max(completedChunkIndexes.count, completedTaskEvents)
            )
            highestCompletedChunks = max(highestCompletedChunks, completed)
            let fraction = min(1, Double(highestCompletedChunks) / Double(totalChunks))
            // The web wait page allocates roughly 35–75% to transcription chunks.
            mapped.progress = 0.35 + 0.40 * fraction
            mapped.stageProgress = fraction
            mapped.current = min(highestCompletedChunks, totalChunks)
            mapped.total = totalChunks
            mapped.message = "Transcribing in VoxStudio Cloud · \(mapped.current ?? 0) of \(totalChunks) segments"
        } else if isTranscribing, event.progress == nil {
            // Keep the first transcription event at the web wait page's stage boundary.
            mapped.progress = 0.35
            mapped.stageProgress = 0
        }
        highestProgress = max(highestProgress, mapped.progress)
        mapped.progress = highestProgress
        return mapped
    }
}

private enum RemoteSessionCancellationMode: Sendable, Equatable {
    case preserveSession
    case deleteAfterCancellation
}

private struct RemoteSession: Sendable {
    let id: UUID
    let cancellationMode: RemoteSessionCancellationMode
}

private actor RemoteSessionMap {
    private var values: [UUID: RemoteSession] = [:]
    private var cancellationRequested: Set<UUID> = []

    func set(_ session: RemoteSession, for jobID: UUID) -> Bool {
        values[jobID] = session
        return cancellationRequested.remove(jobID) != nil
    }

    func requestCancellation(for jobID: UUID) -> RemoteSession? {
        guard let session = values.removeValue(forKey: jobID) else {
            cancellationRequested.insert(jobID)
            return nil
        }
        return session
    }

    func remove(_ jobID: UUID) {
        values.removeValue(forKey: jobID)
        cancellationRequested.remove(jobID)
    }
}
