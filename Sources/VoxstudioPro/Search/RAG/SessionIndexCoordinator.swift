import Foundation
import AVFoundation

@MainActor
final class SessionIndexCoordinator {
    static let shared = SessionIndexCoordinator()

    private let store: SessionIndexStore
    #if BUNDLED_SPEECH
    private let embeddingProvider = WeMMEmbeddingProvider.shared
    #endif
    private var ingestTask: Task<Void, Never>?
    private var pending: [UUID: SessionIndexSnapshot] = [:]
    private var forceReindexIDs: Set<UUID> = []
    private var pendingCardPatches: [UUID: SessionIndexSnapshot] = [:]
    private var pendingSpeakerPatches: [UUID: [SessionSpeaker]] = [:]
    private var pendingRemovals: Set<UUID> = []
    private var pendingRetainIDs: Set<UUID>?
    private var embeddingQueue: [UUID] = []
    private var graphQueue: Set<UUID> = []
    private var indexingSuspended = false

    private init() {
        let url = Self.indexURL
        do {
            store = try SessionIndexStore(url: url)
        } catch {
            Log.search.error("session index open failed error=\(error.localizedDescription)")
            store = try! SessionIndexStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("session-index-fallback.sqlite"))
        }
    }

    var searchService: SearchService {
        #if BUNDLED_SPEECH
        SearchService(store: store, embeddings: embeddingProvider)
        #else
        SearchService(store: store, embeddings: nil)
        #endif
    }

    func prewarmEmbeddings() async {
        #if BUNDLED_SPEECH
        do {
            try await embeddingProvider.prepare()
        } catch is CancellationError {
        } catch {
            Log.search.warning("search embedding prewarm failed error=\(error.localizedDescription)")
        }
        #endif
    }

    func ingest(_ job: WorkbenchTranscriptionJob, force: Bool = false) {
        guard let snapshot = SessionIndexSnapshot.from(job) else { return }
        pending[snapshot.sessionID] = snapshot
        if force { forceReindexIDs.insert(snapshot.sessionID) }
        pump()
    }

    func patchSessionCard(_ job: WorkbenchTranscriptionJob) {
        guard let snapshot = SessionIndexSnapshot.from(job) else { return }
        pendingCardPatches[snapshot.sessionID] = snapshot
        pump()
    }

    func patchSpeakers(_ job: WorkbenchTranscriptionJob) {
        guard SessionIndexSnapshot.from(job) != nil else { return }
        pendingSpeakerPatches[job.id] = SessionIndexSnapshot.speakers(in: job)
        pump()
    }

    func remove(_ sessionID: UUID) {
        pendingRemovals.insert(sessionID)
        pending[sessionID] = nil
        pendingCardPatches[sessionID] = nil
        pendingSpeakerPatches[sessionID] = nil
        pump()
    }

    /// Upsert cloud-origin sessions into the local index (login sync). Does not delete on logout.
    func syncCloudSessions(_ sessions: [WorkbenchSession], ownerUserID: String?) {
        for session in sessions {
            guard let snapshot = SessionIndexSnapshot.from(
                session: session,
                sourceOrigin: KnowledgeScopeSnapshot.origin(session),
                ownerUserID: ownerUserID
            ) else { continue }
            pending[snapshot.sessionID] = snapshot
        }
        pump()
    }

    /// P0: Unused. Reserved for logout/sync cleanup when cloud session retention policy is defined.
    /// Call when sign-out should prune stale cloud sessions not in the current server session list.
    func removeCloudSessions(except retainedIDs: Set<UUID>) {
        Task { [weak self] in
            guard let self else { return }
            let indexed = (try? await self.store.sessionIDs()) ?? []
            for id in indexed {
                guard !retainedIDs.contains(id) else { continue }
                guard (try? await self.store.sourceOrigin(sessionID: id)) == .cloud else { continue }
                await MainActor.run { self.remove(id) }
            }
        }
    }

    func reconcile(_ jobs: [WorkbenchTranscriptionJob], sessions: [WorkbenchSession] = []) {
        var snapshots: [UUID: SessionIndexSnapshot] = [:]
        for job in jobs {
            guard let snapshot = SessionIndexSnapshot.from(job) else { continue }
            snapshots[snapshot.sessionID] = snapshot
        }
        for session in sessions where session.source == .standaloneDub {
            if let snapshot = SessionIndexSnapshot.from(session: session, sourceOrigin: KnowledgeScopeSnapshot.origin(session), ownerUserID: AccountService.shared.userID?.uuidString) { snapshots[session.id] = snapshot }
        }
        pendingRetainIDs = Set(snapshots.keys)
        for (id, snapshot) in snapshots {
            pending[id] = snapshot
        }
        Log.search.notice(
            "session index reconcile jobs=\(jobs.count) indexable=\(snapshots.count)"
        )
        pump()
    }

    func resumeEmbeddings() {
        Task { [weak self] in
            guard let self else { return }
            let ids = (try? await self.store.sessionsNeedingEmbedding()) ?? []
            for id in ids { self.enqueueEmbedding(id) }
            self.pump()
        }
    }

    func pauseIndexing() {
        indexingSuspended = true
        ingestTask?.cancel()
    }

    func resumeIndexing() {
        indexingSuspended = false
        reconcile(WorkbenchStore.shared.transcriptions, sessions: WorkbenchStore.shared.sessions)
        syncCloudSessions(WorkbenchStore.shared.sessions.filter { KnowledgeScopeSnapshot.origin($0) == .cloud },
                          ownerUserID: AccountService.shared.userID?.uuidString)
        resumeEmbeddings()
        backfillKnowledgeGraph()
    }

    func backfillKnowledgeGraph() {
        guard KnowledgeGraphAvailability.canRun(.graphExtraction) else { return }
        let origins = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: AccountService.shared.isSignedIn
        )
        let owner = AccountService.shared.userID?.uuidString
        Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await self.store.graphSourcesNeedingRebuild(
                    sourceOrigins: origins,
                    cloudOwnerUserID: owner
                )
                guard KnowledgeGraphAvailability.canRun(.graphExtraction) else { return }
                self.graphQueue.formUnion(sources.map(\.sessionID))
                self.pump()
            } catch {
                Log.search.warning("knowledge graph backfill discovery failed error=\(error.localizedDescription)")
            }
        }
    }

    private var embeddingsAvailable: Bool {
        #if BUNDLED_SPEECH
        LocalModelManager.shared.state(for: SearchIndexConfig.modelID).isInstalled
        #else
        false
        #endif
    }

    private var hasWork: Bool {
        !pending.isEmpty
            || !pendingCardPatches.isEmpty
            || !pendingSpeakerPatches.isEmpty
            || !pendingRemovals.isEmpty
            || pendingRetainIDs != nil
            || (!embeddingQueue.isEmpty && embeddingsAvailable)
            || (!graphQueue.isEmpty && KnowledgeGraphAvailability.canRun(.graphExtraction))
    }

    private func enqueueEmbedding(_ sessionID: UUID) {
        guard !embeddingQueue.contains(sessionID) else { return }
        embeddingQueue.append(sessionID)
    }

    private func pump() {
        guard !indexingSuspended, ingestTask == nil, hasWork else { return }
        ingestTask = Task(priority: .utility) { [weak self] in
            await self?.drain()
            await MainActor.run { self?.ingestTask = nil; self?.pump() }
        }
    }

    private func drain() async {
        while ExportQueue.shared.isExportActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }

        if let retainIDs = pendingRetainIDs {
            pendingRetainIDs = nil
            do {
                let indexed = try await store.sessionIDs()
                for id in indexed where !retainIDs.contains(id) {
                    // Cloud rows stay until explicit remove (logout must not wipe them).
                    if (try? await store.sourceOrigin(sessionID: id)) == .cloud {
                        continue
                    }
                    pendingRemovals.insert(id)
                }
            } catch {
                Log.search.error(
                    "session index reconcile failed error=\(error.localizedDescription)"
                )
            }
        }

        let removals = pendingRemovals
        pendingRemovals.removeAll()
        for id in removals {
            try? await store.removeSession(id)
        }

        let snapshots = Array(pending.values)
        pending.removeAll()
        for var snapshot in snapshots {
            do {
                await snapshot.resolveVideoDurationIfNeeded()
                try Task.checkCancellation()
                let force = forceReindexIDs.remove(snapshot.sessionID) != nil
                let freshness = force ? nil : try await store.freshness(sessionID: snapshot.sessionID, knowledgeManifest: snapshot.knowledgeManifest, mediaManifest: snapshot.mediaManifest)
                switch SessionIndexIngestAction.resolve(
                    freshness: freshness,
                    generation: snapshot.generation
                ) {
                case .skip:
                    // A generation-equivalent row may still have stale owner or
                    // source metadata (notably pre-migration cloud rows).
                    try await store.patchSessionMetadata(snapshot: snapshot)
                    continue
                case .embedOnly:
                    try await store.patchSessionMetadata(snapshot: snapshot)
                    enqueueEmbedding(snapshot.sessionID)
                case .replace:
                    let oldManifest = try await store.laneManifest(sessionID: snapshot.sessionID, lane: "knowledge")
                    if (force || oldManifest != snapshot.knowledgeManifest), let body = snapshot.selectedBody {
                        snapshot.preparedChunks = await KnowledgeTextTokenizer.shared.chunks(for: body)
                    }
                    try Task.checkCancellation()
                    let clips = clipWindows(for: snapshot)
                    let knowledgeChanged = try await store.replaceLexical(snapshot: snapshot, clips: clips, force: force)
                    enqueueEmbedding(snapshot.sessionID)
                    if knowledgeChanged && KnowledgeGraphSettings.shared.isEnabled {
                        graphQueue.insert(snapshot.sessionID)
                    }
                }
            } catch {
                Log.search.error(
                    "session lexical ingest failed id=\(snapshot.sessionID.uuidString) error=\(error.localizedDescription)"
                )
            }
        }

        let cards = Array(pendingCardPatches.values)
        pendingCardPatches.removeAll()
        for snapshot in cards {
            try? await store.patchSessionCard(snapshot: snapshot)
            enqueueEmbedding(snapshot.sessionID)
        }

        let speakers = pendingSpeakerPatches
        pendingSpeakerPatches.removeAll()
        for (id, list) in speakers {
            try? await store.patchSpeakers(list, sessionID: id)
        }

        await embedPending()
        await ingestKnowledgeGraphPending()
    }

    private func embedPending() async {
        #if BUNDLED_SPEECH
        guard embeddingsAvailable else { return }
        let ids = embeddingQueue
        embeddingQueue.removeAll()
        for sessionID in ids {
            guard !Task.isCancelled else { return }
            do {
                let units = try await store.unitsNeedingEmbedding(sessionID: sessionID)
                let mediaPath = (try await store.sessionCard(id: sessionID))?.mediaPath ?? ""
                let mediaURL = URL(string: mediaPath).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil } ?? URL(fileURLWithPath: mediaPath)
                let hasMedia = !mediaPath.isEmpty && !mediaPath.hasPrefix("cloud://")
                for unit in units {
                    try Task.checkCancellation()
                    // A new edit may have removed/replaced this unit while inference yielded.
                    guard try await store.unitExists(id: unit.id, sessionID: sessionID, text: unit.text) else { continue }
                    for modality in try await store.missingEmbeddingModalities(for: unit) {
                        switch modality {
                        case .text:
                            guard !unit.text.isEmpty else { continue }
                            let vector = try await embeddingProvider.encodeText(unit.text)
                            try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector)
                        case .video, .mixed:
                            guard let start = unit.start, let end = unit.end, hasMedia else { continue }
                            let vector = try await embeddingProvider.encodeVideo(url: mediaURL, range: start ... end,
                                                                                 text: modality == .mixed ? unit.text : nil)
                            try await store.upsertEmbedding(unitID: unit.id, modality: modality, vector: vector)
                        }
                    }
                }
                let remaining = try await store.unitsNeedingEmbedding(sessionID: sessionID)
                try await store.markEmbeddingReady(sessionID, ready: remaining.isEmpty)
            } catch is CancellationError {
                return
            } catch {
                Log.search.error(
                    "session embedding ingest failed id=\(sessionID.uuidString) error=\(error.localizedDescription)"
                )
            }
        }
        #endif
    }

    private func ingestKnowledgeGraphPending() async {
        guard KnowledgeGraphAvailability.canRun(.graphExtraction) else { return }
        let sourceIDs = graphQueue
        graphQueue.removeAll()
        let ingestion = KnowledgeGraphIngestionService(store: store)
        for sessionID in sourceIDs {
            guard !Task.isCancelled,
                  KnowledgeGraphAvailability.canRun(.graphExtraction)
            else { return }
            do {
                guard let source = try await store.graphSource(sessionID: sessionID) else { continue }
                try await ingestion.rebuild(source)
            } catch is CancellationError {
                return
            } catch {
                Log.search.warning(
                    "knowledge graph ingest failed id=\(sessionID.uuidString) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func clipWindows(for snapshot: SessionIndexSnapshot) -> [CuePacker.Clip] {
        if !snapshot.cues.isEmpty {
            return CuePacker.pack(cues: snapshot.cues, shotBounds: snapshot.shotBounds)
        }
        if snapshot.hasVideo {
            return CuePacker.videoOnlyWindows(duration: snapshot.duration, shotBounds: snapshot.shotBounds)
        }
        return []
    }

    private static var indexURL: URL {
        AppSupportPaths.applicationSupport()
            .appendingPathComponent("Search/index.sqlite")
    }
}

extension SessionIndexSnapshot {
    mutating func resolveVideoDurationIfNeeded() async {
        guard hasVideo, cues.isEmpty, mediaDurationSec == nil,
              !mediaPath.isEmpty, !mediaPath.hasPrefix("cloud://") else { return }
        let url = URL(string: mediaPath).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            ?? URL(fileURLWithPath: mediaPath)
        guard let measured = try? await KnowledgeQATimeout.run(.seconds(5), operation: {
            try await AVURLAsset(url: url).load(.duration).seconds
        }), measured.isFinite, measured > 0 else { return }
        duration = measured; mediaDurationSec = measured; durationProvenance = "media_metadata"
    }

    static func from(_ job: WorkbenchTranscriptionJob) -> SessionIndexSnapshot? {
        guard job.state == .completed else { return nil }
        let transcript = job.result
        let cues = job.subtitleTrack?.cues ?? []
        let segments = transcript?.segments ?? []

        let duration = max(
            segments.map(\.end).max() ?? 0,
            cues.map(\.end).max() ?? 0
        )
        let origin = KnowledgeSourceOrigin.resolve(
            isCloudStorage: job.storage == .cloud,
            hasRemoteSessionID: job.remoteSessionID != nil
        )
        var snapshot = SessionIndexSnapshot(
            sessionID: job.id,
            title: job.sessionTitle,
            tag: job.sessionTag,
            summaryMarkdown: job.summaryMarkdown,
            language: transcript?.language ?? job.languageCode,
            duration: duration,
            durationProvenance: "transcript_extent; media_unknown",
            lastSpokenEndSec: segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.end).max(),
            transcribedStartSec: segments.map(\.start).min(), transcribedEndSec: segments.map(\.end).max(),
            hasVideo: Self.isVideo(job.sourcePath),
            mediaPath: job.sourcePath,
            sourceMTime: job.modifiedAt.timeIntervalSince1970,
            sourceCreatedAt: job.createdAt.timeIntervalSince1970,
            sourceModifiedAt: job.modifiedAt.timeIntervalSince1970,
            generation: SessionIndexSnapshot.generation(modifiedAt: job.modifiedAt),
            speakers: speakers(in: job),
            segments: segments,
            words: transcript?.words ?? [],
            cues: cues,
            shotBounds: [],
            sourceOrigin: origin,
            remoteSessionID: job.remoteSessionID,
            ownerUserID: nil,
            sessionType: job.isRecordedCapture
                ? .record
                : (job.netVideoSourceURL == nil ? .upload : .netVideo)
        )
        snapshot.body = KnowledgeTranscriptMaterial.from(transcript: transcript) ?? KnowledgeTranscriptMaterial.from(subtitles: job.subtitleTrack)
        snapshot.lastSpokenEndSec = snapshot.body?.spans.compactMap(\.end).max()
        snapshot.transcribedStartSec = snapshot.body?.spans.compactMap(\.start).min()
        snapshot.transcribedEndSec = snapshot.body?.spans.compactMap(\.end).max()
        return snapshot
    }

    /// Cloud Recent / opened remote session → local index with `source_origin=cloud`.
    static func from(
        session: WorkbenchSession,
        sourceOrigin: KnowledgeSourceOrigin = .cloud,
        ownerUserID: String?
    ) -> SessionIndexSnapshot? {
        let material = KnowledgeTranscriptMaterial.from(session)
        let transcript = KnowledgeTranscriptMaterial.displayTranscript(for: session)
        let cues = (session.source == .standaloneDub ? (session.subtitleTrack ?? session.dubSubtitleTrack) : session.subtitleTrack)?.cues ?? []
        let segments = material?.segments ?? []
        let summary = session.summaryMarkdown
        // List metadata may only have title/summary; still index a session card for Recent sync.
        let hasBody = transcript != nil || !cues.isEmpty || (summary?.isEmpty == false)
        let hasTitle = !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasBody || hasTitle else { return nil }
        let duration = max(
            session.duration ?? 0,
            segments.map(\.end).max() ?? 0,
            cues.map(\.end).max() ?? 0
        )
        let mediaPath = session.sourceURL.map { $0.isFileURL ? $0.path : $0.absoluteString }
            ?? session.outputURL.map { $0.isFileURL ? $0.path : $0.absoluteString }
            ?? session.remoteSourcePlaybackURL?.absoluteString
            ?? "cloud://\(session.remoteSessionID?.uuidString ?? session.id.uuidString)"
        var labels: [String] = []
        var seen = Set<String>()
        for label in (segments.compactMap(\.speaker) + cues.compactMap(\.speaker))
        where seen.insert(label).inserted {
            labels.append(label)
        }
        var snapshot = SessionIndexSnapshot(
            sessionID: session.id,
            title: session.title.isEmpty ? "Untitled session" : session.title,
            tag: session.sessionTag,
            summaryMarkdown: summary,
            language: transcript?.language,
            duration: duration,
            mediaDurationSec: session.durationHint.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            durationProvenance: session.durationHint == nil ? "transcript_extent; media_unknown" : "source_duration_hint",
            lastSpokenEndSec: segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.end).max(),
            transcribedStartSec: segments.map(\.start).min(), transcribedEndSec: segments.map(\.end).max(),
            hasVideo: session.remoteSourceHasVideo == true || Self.isVideo(mediaPath),
            mediaPath: mediaPath,
            sourceMTime: session.modifiedAt.timeIntervalSince1970,
            sourceCreatedAt: session.createdAt.timeIntervalSince1970,
            sourceModifiedAt: session.modifiedAt.timeIntervalSince1970,
            generation: SessionIndexSnapshot.generation(modifiedAt: session.modifiedAt),
            speakers: labels.map { SessionSpeaker(label: $0, displayName: $0) },
            segments: segments,
            words: transcript?.words ?? [],
            cues: cues,
            shotBounds: [],
            sourceOrigin: sourceOrigin,
            remoteSessionID: sourceOrigin == .cloud ? (session.remoteSessionID ?? session.id) : session.remoteSessionID,
            ownerUserID: ownerUserID,
            sessionType: session.sessionType
        )
        snapshot.body = material
        snapshot.lastSpokenEndSec = material?.spans.compactMap(\.end).max()
        snapshot.transcribedStartSec = material?.spans.compactMap(\.start).min()
        snapshot.transcribedEndSec = material?.spans.compactMap(\.end).max()
        return snapshot
    }

    static func speakers(in job: WorkbenchTranscriptionJob) -> [SessionSpeaker] {
        var labels: [String] = []
        var seen = Set<String>()
        let sources: [String?] =
            (job.result?.words.map(\.speaker) ?? [])
            + (job.result?.segments.map(\.speaker) ?? [])
            + (job.subtitleTrack?.cues.map(\.speaker) ?? [])
        for label in sources.compactMap({ $0 }) where seen.insert(label).inserted {
            labels.append(label)
        }
        return labels.map { SessionSpeaker(label: $0, displayName: $0) }
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]

    private static func isVideo(_ path: String) -> Bool {
        videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
