import Foundation

@MainActor
final class SessionIndexCoordinator {
    static let shared = SessionIndexCoordinator()

    private let store: SessionIndexStore
    #if BUNDLED_SPEECH
    private let embeddingProvider = WeMMEmbeddingProvider()
    #endif
    private var ingestTask: Task<Void, Never>?
    private var pending: [UUID: SessionIndexSnapshot] = [:]
    private var pendingCardPatches: [UUID: SessionIndexSnapshot] = [:]
    private var pendingSpeakerPatches: [UUID: [SessionSpeaker]] = [:]
    private var pendingRemovals: Set<UUID> = []
    private var pendingRetainIDs: Set<UUID>?
    private var embeddingQueue: [UUID] = []

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

    func ingest(_ job: WorkbenchTranscriptionJob) {
        guard let snapshot = SessionIndexSnapshot.from(job) else { return }
        pending[snapshot.sessionID] = snapshot
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

    func reconcile(_ jobs: [WorkbenchTranscriptionJob]) {
        var snapshots: [UUID: SessionIndexSnapshot] = [:]
        for job in jobs {
            guard let snapshot = SessionIndexSnapshot.from(job) else { continue }
            snapshots[snapshot.sessionID] = snapshot
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

    private var embeddingsAvailable: Bool {
        #if BUNDLED_SPEECH
        LocalModelManager.isInstalled(LocalModelManager.shared.descriptor(for: .weMMEmbedding2B4Bit))
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
    }

    private func enqueueEmbedding(_ sessionID: UUID) {
        guard !embeddingQueue.contains(sessionID) else { return }
        embeddingQueue.append(sessionID)
    }

    private func pump() {
        guard ingestTask == nil, hasWork else { return }
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
        for snapshot in snapshots {
            do {
                let freshness = try await store.freshness(sessionID: snapshot.sessionID)
                switch SessionIndexIngestAction.resolve(
                    freshness: freshness,
                    generation: snapshot.generation
                ) {
                case .skip:
                    continue
                case .embedOnly:
                    enqueueEmbedding(snapshot.sessionID)
                case .replace:
                    let clips = clipWindows(for: snapshot)
                    try await store.replaceLexical(snapshot: snapshot, clips: clips)
                    enqueueEmbedding(snapshot.sessionID)
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
                let mediaURL = URL(fileURLWithPath: mediaPath)
                let hasMedia = !mediaPath.isEmpty
                for unit in units {
                    try Task.checkCancellation()
                    switch unit.kind {
                    case .sessionCard, .transcriptChunk, .subtitleCue:
                        let vector = try await embeddingProvider.encodeText(unit.text)
                        try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector)
                    case .mediaClip:
                        guard let start = unit.start, let end = unit.end, hasMedia else {
                            if !unit.text.isEmpty {
                                let vector = try await embeddingProvider.encodeText(unit.text)
                                try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector)
                            }
                            continue
                        }
                        if unit.modality == .video || unit.modality == .mixed {
                            let video = try await embeddingProvider.encodeVideo(
                                url: mediaURL,
                                range: start ... end,
                                text: nil
                            )
                            try await store.upsertEmbedding(unitID: unit.id, modality: .video, vector: video)
                        }
                        if unit.modality == .mixed, !unit.text.isEmpty {
                            let mixed = try await embeddingProvider.encodeVideo(
                                url: mediaURL,
                                range: start ... end,
                                text: unit.text
                            )
                            try await store.upsertEmbedding(unitID: unit.id, modality: .mixed, vector: mixed)
                        }
                    }
                }
                try await store.markEmbeddingReady(sessionID, ready: true)
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio/Search/index.sqlite")
    }
}

extension SessionIndexSnapshot {
    static func from(_ job: WorkbenchTranscriptionJob) -> SessionIndexSnapshot? {
        guard job.state == .completed else { return nil }
        let transcript = job.result
        let cues = job.subtitleTrack?.cues ?? []
        let segments = transcript?.segments ?? []
        guard transcript != nil || !cues.isEmpty else { return nil }
        let duration = max(
            segments.map(\.end).max() ?? 0,
            cues.map(\.end).max() ?? 0
        )
        var translation: [Int: String] = [:]
        if let track = job.translationTracks.first?.track {
            for cue in track.cues {
                translation[cue.id] = cue.text
            }
        }
        return SessionIndexSnapshot(
            sessionID: job.id,
            title: job.sessionTitle,
            tag: job.sessionTag,
            summaryMarkdown: job.summaryMarkdown,
            language: transcript?.language ?? job.languageCode,
            duration: duration,
            hasVideo: Self.isVideo(job.sourcePath),
            mediaPath: job.sourcePath,
            sourceMTime: job.modifiedAt.timeIntervalSince1970,
            generation: Int(job.modifiedAt.timeIntervalSince1970),
            speakers: speakers(in: job),
            segments: segments,
            words: transcript?.words ?? [],
            cues: cues,
            translationByCueID: translation,
            shotBounds: []
        )
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
