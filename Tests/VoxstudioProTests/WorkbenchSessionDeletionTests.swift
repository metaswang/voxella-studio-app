import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Workbench session deletion", .serialized)
struct WorkbenchSessionDeletionTests {
    @Test func remoteOnlySessionUsesItsCloudSessionID() {
        let remoteID = UUID()
        let session = WorkbenchSession(
            id: remoteID,
            title: "Cloud session",
            createdAt: Date(),
            modifiedAt: Date(),
            state: .completed,
            source: .media,
            sessionType: .upload,
            transcriptionID: nil,
            dubID: nil,
            sourceURL: nil,
            outputURL: nil,
            transcript: nil,
            subtitleTrack: nil,
            translationTracks: [],
            selectedTranslationLanguageCode: nil,
            summaryMarkdown: nil,
            summaryTemplateID: nil,
            summaryTemplateName: nil,
            summaryState: nil,
            summaryErrorMessage: nil,
            sessionTag: nil,
            dubTranscript: nil,
            dubSubtitleTrack: nil,
            dubSegments: [],
            remoteSessionID: remoteID,
            cloudSyncError: nil
        )

        #expect(WorkbenchStore.sessionDeletionTarget(for: session) == .remote(remoteID))
    }

    @MainActor @Test func localCopyDeletionRemovesLinkedJobsWithoutCloudDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.wav")
        try Data("original media".utf8).write(to: source)
        let sync = DeletionCloudSync(failsDeletion: true)
        let snapshotURL = directory.appendingPathComponent("workbench.json")
        let store = WorkbenchStore(
            cloudSessionSync: sync, voxellaAPI: signedOutAPI(),
            persistenceURL: snapshotURL, isCloudMode: { false }
        )
        try await waitUntil { !store.isHydrating }

        var job = WorkbenchTranscriptionJob(sourcePath: source.path)
        job.state = .completed
        job.storage = .cloud
        job.remoteSessionID = UUID()
        var dub = WorkbenchDubJob()
        dub.sourceTranscriptionID = job.id
        dub.storage = .cloud
        dub.remoteSessionID = UUID()
        var olderDub = dub
        olderDub.id = UUID()
        olderDub.remoteSessionID = UUID()
        store.transcriptions = [job]
        store.dubs = [olderDub, dub]
        store.selectedSessionID = job.id
        store.route = .session
        let session = try #require(store.sessions.first)
        WorkbenchTipCenter.shared.hide()
        #expect(RecentSessionDeletionRequest.prepare(sessions: [session], store: store) == nil)
        try await waitUntil { !store.isDeletingSession(session) }

        #expect(store.transcriptions.isEmpty)
        #expect(store.dubs.isEmpty)
        #expect(store.selectedSessionID == nil)
        #expect(store.route == .recent)
        #expect(await sync.deletedIDs.isEmpty)
        #expect(WorkbenchTipCenter.shared.tip?.kind == .success)
        #expect(WorkbenchTipCenter.shared.tip?.message == "The local copy was deleted. The cloud session was kept.")
        WorkbenchTipCenter.shared.hide()
        #expect(FileManager.default.fileExists(atPath: source.path))
        try await store.saveMCPChanges()
        let saved = try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(contentsOf: snapshotURL))
        #expect(saved.transcriptions.isEmpty)
        #expect(saved.dubs.isEmpty)
    }

    @MainActor @Test func standaloneCloudDubCanDeleteItsLocalCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DeletionCloudSync(failsDeletion: true)
        let store = WorkbenchStore(
            cloudSessionSync: sync,
            voxellaAPI: signedOutAPI(),
            persistenceURL: directory.appendingPathComponent("workbench.json"),
            isCloudMode: { false }
        )
        try await waitUntil { !store.isHydrating }
        var dub = WorkbenchDubJob()
        dub.script = "A saved cloud voiceover"
        dub.storage = .cloud
        dub.remoteSessionID = UUID()
        store.dubs = [dub]
        let session = try #require(store.sessions.first)
        WorkbenchTipCenter.shared.hide()
        #expect(RecentSessionDeletionRequest.prepare(sessions: [session], store: store) == nil)
        try await waitUntil { !store.isDeletingSession(session) }
        #expect(store.dubs.isEmpty)
        #expect(await sync.deletedIDs.isEmpty)
        #expect(WorkbenchTipCenter.shared.tip?.kind == .success)
        WorkbenchTipCenter.shared.hide()
    }

    @MainActor @Test(arguments: [false, true])
    func fullDeletionStillRequiresCloudSuccess(failsDeletion: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DeletionCloudSync(failsDeletion: failsDeletion)
        let store = WorkbenchStore(
            cloudSessionSync: sync,
            voxellaAPI: signedOutAPI(),
            persistenceURL: directory.appendingPathComponent("workbench.json"),
            isCloudMode: { true }
        )
        try await waitUntil { !store.isHydrating }
        var job = WorkbenchTranscriptionJob(sourcePath: directory.appendingPathComponent("source.wav").path)
        job.storage = .cloud
        job.remoteSessionID = UUID()
        store.transcriptions = [job]
        let session = try #require(store.sessions.first)
        WorkbenchTipCenter.shared.hide()
        #expect(RecentSessionDeletionRequest.prepare(sessions: [session], store: store) == nil)
        try await waitUntil { !store.isDeletingSession(session) }
        #expect(await sync.deletedIDs == [try #require(job.remoteSessionID)])
        #expect(store.transcriptions.isEmpty == !failsDeletion)
        #expect(WorkbenchTipCenter.shared.tip?.kind == (failsDeletion ? .error : nil))
        WorkbenchTipCenter.shared.hide()
    }

    @MainActor @Test func bulkLocalDeletionSkipsConfirmationAndPreservesCloud() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DeletionCloudSync(failsDeletion: true)
        let store = WorkbenchStore(
            cloudSessionSync: sync, voxellaAPI: signedOutAPI(),
            persistenceURL: directory.appendingPathComponent("workbench.json"), isCloudMode: { false }
        )
        try await waitUntil { !store.isHydrating }
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/source.wav")
        job.storage = .cloud
        job.remoteSessionID = UUID()
        var other = job
        other.id = UUID()
        other.remoteSessionID = UUID()
        store.transcriptions = [job, other]
        let sessions = store.sessions
        #expect(RecentSessionDeletionRequest.prepare(sessions: sessions, store: store) == nil)
        try await waitUntil { sessions.allSatisfy { !store.isDeletingSession($0) } }
        #expect(store.transcriptions.isEmpty)
        #expect(await sync.deletedIDs.isEmpty)
        WorkbenchTipCenter.shared.hide()
        try await store.saveMCPChanges()
    }

    private func signedOutAPI() -> VoxellaAPIClient {
        VoxellaAPIClient(auth: VoxellaAuthService(
            loadRefresh: { nil }, saveRefresh: { _ in }, deleteRefresh: {}
        ))
    }

    @MainActor @Test func mixedSelectionDeletesCloudCopyWithoutIncludingItInConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DeletionCloudSync(failsDeletion: true)
        let store = WorkbenchStore(
            cloudSessionSync: sync, voxellaAPI: signedOutAPI(),
            persistenceURL: directory.appendingPathComponent("workbench.json"), isCloudMode: { false }
        )
        try await waitUntil { !store.isHydrating }
        let local = WorkbenchTranscriptionJob(sourcePath: "/tmp/local.wav")
        var cloud = WorkbenchTranscriptionJob(sourcePath: "/tmp/cloud.wav")
        cloud.storage = .cloud
        cloud.remoteSessionID = UUID()
        store.transcriptions = [local, cloud]
        let sessions = store.sessions
        let request = try #require(RecentSessionDeletionRequest.prepare(sessions: sessions, store: store))
        #expect(request.sessions.map(\.id) == [local.id])
        try await waitUntil { sessions.allSatisfy { !store.isDeletingSession($0) } }
        #expect(store.transcriptions.map(\.id) == [local.id])
        #expect(await sync.deletedIDs.isEmpty)
        WorkbenchTipCenter.shared.hide()
        try await store.saveMCPChanges()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

private actor DeletionCloudSync: CloudSessionSyncing {
    let failsDeletion: Bool
    private(set) var deletedIDs: [UUID] = []

    init(failsDeletion: Bool) { self.failsDeletion = failsDeletion }

    func sync(_ snapshot: CloudSessionSyncSnapshot) async throws {}

    func delete(remoteSessionID: UUID) async throws {
        deletedIDs.append(remoteSessionID)
        if failsDeletion { throw URLError(.notConnectedToInternet) }
    }
}
