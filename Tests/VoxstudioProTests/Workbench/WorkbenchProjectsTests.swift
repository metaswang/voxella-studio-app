import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Home session projects") @MainActor
struct WorkbenchProjectsTests {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("projects.json")
    }

    private func session() throws -> WorkbenchSession {
        let job = WorkbenchTranscriptionJob(sourcePath: "/tmp/import.mp3")
        return try #require(WorkbenchStore.localSessions(transcriptions: [job], dubs: []).first)
    }

    @Test func foldersAndMembershipSurviveReloadWithoutChangingSessions() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkbenchProjectsStore(fileURL: file)
        let session = try session()
        let id = try store.create(name: "  Launch  ", session: session)
        try store.rename(id, name: "Product launch")
        let loaded = WorkbenchProjectsStore(fileURL: file)
        #expect(loaded.project(for: session)?.name == "Product launch")
        #expect(loaded.project(for: session)?.id == id)
        #expect(loaded.sessions(in: loaded.projects[0], from: [session]).map(\.id) == [session.id])
        try loaded.remove(id)
        #expect(loaded.projects.isEmpty)
        #expect(session.sessionType == .upload)
        #expect(session.sourceURL?.path == "/tmp/import.mp3")
    }

    @Test func movingAndCreatingAProjectAreExclusiveAndKeepUnloadedMembers() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkbenchProjectsStore(fileURL: file)
        let first = try session(), second = try session()
        let a = try store.create(name: "A", session: first)
        let b = try store.create(name: "B")
        try store.move(second, to: a)
        try store.move(first, to: b)
        #expect(store.projects.first { $0.id == a }?.sessions.map(\.id) == [second.id])
        #expect(store.project(for: first)?.id == b)
        try store.synchronizeIdentities(with: [])
        #expect(store.project(for: second)?.id == a)
        let c = try store.create(name: "C", session: first)
        #expect(store.project(for: first)?.id == c)
        #expect(store.projects.first { $0.id == b }?.sessions.isEmpty == true)
        try store.move(first, to: nil)
        #expect(store.project(for: first) == nil)
    }

    @Test func cloudIdentityAddedAfterMoveRemainsInItsProject() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkbenchProjectsStore(fileURL: file)
        var local = try session()
        let id = try store.create(name: "Synced", session: local)
        local.remoteSessionID = UUID()
        try store.synchronizeIdentities(with: [local])
        var remote = local
        remote.id = try #require(local.remoteSessionID)
        remote.transcriptionID = nil
        let loaded = WorkbenchProjectsStore(fileURL: file)
        #expect(loaded.project(for: remote)?.id == id)
        #expect(loaded.sessions(in: loaded.projects[0], from: [remote]).count == 1)
    }

    @Test func corruptMetadataCannotBeOverwrittenByAnEmptyWorkspace() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = Data("not valid project metadata".utf8)
        try original.write(to: file)
        let store = WorkbenchProjectsStore(fileURL: file)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.create(name: "New") }
        #expect(try Data(contentsOf: file) == original)
        #expect(store.projects.isEmpty)
    }

    @Test func invalidNamesAndWriteFailuresLeaveTheInMemoryStateIntact() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkbenchProjectsStore(fileURL: file)
        #expect(throws: (any Error).self) { try store.create(name: " \n ") }
        let id = try store.create(name: "Keep")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.rename(id, name: "Changed") }
        #expect(store.projects.first?.name == "Keep")
    }

    @Test func projectCreationRegistersWholeBatchWithoutRemovingAnythingFromRecents() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let projects = WorkbenchProjectsStore(fileURL: file)
        let projectID = try projects.create(name: "Project")
        let jobs = [WorkbenchTranscriptionJob(sourcePath: "/tmp/one.mp3"), WorkbenchTranscriptionJob(sourcePath: "/tmp/two.mp3")]
        let recents = WorkbenchStore.localSessions(transcriptions: jobs, dubs: [])
        try projects.addNewSessions(jobs.map(\.id), to: projectID)
        let loaded = WorkbenchProjectsStore(fileURL: file)
        #expect(Set(loaded.sessions(in: loaded.projects[0], from: recents).map(\.id)) == Set(jobs.map(\.id)))
        #expect(recents.count == 2)
        #expect(recents.allSatisfy { loaded.project(for: $0)?.id == projectID })
    }

    @Test func emptyVoiceoverAndUnloadedMeetingCanBeRegisteredBeforeCatalogHydration() throws {
        let file = try location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let projects = WorkbenchProjectsStore(fileURL: file)
        let projectID = try projects.create(name: "Created here")
        let draftID = UUID(), meetingID = UUID()
        try projects.addNewSessions([draftID], to: projectID)
        try projects.addNewSessions([meetingID], to: projectID, remoteOnly: true)
        let loaded = WorkbenchProjectsStore(fileURL: file)
        #expect(Set(loaded.projects[0].sessions.map(\.id)) == [draftID, meetingID])
        #expect(loaded.projects[0].sessions.first { $0.id == meetingID }?.remoteSessionID == meetingID)
        try loaded.addNewSessions([meetingID, meetingID], to: projectID, remoteOnly: true)
        #expect(loaded.projects[0].sessions.count == 2)
        try loaded.remove(projectID)
        try loaded.addNewSessions([UUID()], to: projectID)
        #expect(loaded.projects.isEmpty)
    }

    @Test func recordingDestinationIsFrozenAndSurvivesRecoveryWhileNormalRequestsClearIt() throws {
        let projectID = UUID()
        let request = LocalRecordingRequest(mode: .audioOnly, applicationBundleIdentifier: nil,
                                            startImmediately: false, purpose: .recording, sessionProjectID: projectID)
        let frozen = request.configuration(from: RecordingCaptureConfiguration())
        var next = frozen
        next.sessionProjectID = UUID()
        #expect(frozen.sessionProjectID == projectID)
        let normal = LocalRecordingRequest(mode: .display, applicationBundleIdentifier: nil, startImmediately: false)
        #expect(normal.configuration(from: next).sessionProjectID == nil)
        let manifest = RecordingSessionManifest(sessionID: UUID().uuidString, startedAt: .now,
            outputPath: "/tmp/recording.mp4", mode: "display", backend: "sck", status: RecordingSessionManifest.pendingImport,
            recordingKind: .screen, sessionProjectID: frozen.sessionProjectID)
        let decoded = try JSONDecoder().decode(RecordingSessionManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded.sessionProjectID == projectID)
        #expect(decoded.recordingKind == .screen)
    }
}
