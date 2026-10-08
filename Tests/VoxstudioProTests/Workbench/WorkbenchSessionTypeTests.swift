import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Session source classification")
struct WorkbenchSessionTypeTests {
    @Test(arguments: [WorkbenchRecordingKind.audio, .screen, .meeting])
    @MainActor func recordingIdentitySurvivesJobRoundTripAndProjection(kind: WorkbenchRecordingKind) throws {
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/audio.m4a")
        job.isRecordedCapture = true
        job.recordingKind = kind
        job.state = .completed
        job.result = .init(text: "Meeting transcript", language: "en", words: [], segments: [.init(text: "Meeting transcript", start: 0, end: 2)])
        let restored = try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: JSONEncoder().encode(job))
        let session = try #require(WorkbenchStore.localSessions(transcriptions: [restored], dubs: []).first)
        #expect(session.sessionType == kind.sessionType)
        #expect(KnowledgeSourceType.from(sessionType: session.sessionType) == (kind == .meeting ? .meeting : .recording))
        #expect(restored.recordingKind == kind)
        #expect(SessionIndexSnapshot.from(restored)?.sessionType == kind.sessionType)
    }

    @Test func oldJobsRemainDecodableAndImportedVideoIsNotARecording() throws {
        let job = WorkbenchTranscriptionJob(sourcePath: "/tmp/import.mp4")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        json.removeValue(forKey: "recordingKind")
        let restored = try JSONDecoder().decode(WorkbenchTranscriptionJob.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.recordingKind == nil)
        #expect(restored.sessionType == .upload)
    }

    @Test func persistedMeetingPurposeTakesPrecedenceOverAudioOrVideoContainer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.mp4")
        let manifest = RecordingSessionManifest(
            sessionID: UUID().uuidString, startedAt: Date(), outputPath: url.path,
            mode: RecordingCaptureMode.audioOnly.rawValue, backend: "stream",
            status: RecordingSessionManifest.registered, recordingKind: .meeting
        )
        try RecordingSessionManifest.writeThrowing(manifest)
        #expect(WorkbenchRecordingKind.recordedSource(at: url) == .meeting)
        var legacy = manifest
        legacy.recordingKind = nil
        try RecordingSessionManifest.writeThrowing(legacy)
        #expect(WorkbenchRecordingKind.recordedSource(at: url) == .audio)
        legacy.mode = RecordingCaptureMode.window.rawValue
        try RecordingSessionManifest.writeThrowing(legacy)
        #expect(WorkbenchRecordingKind.recordedSource(at: url) == .screen)
    }

    @Test func meetingPurposeIsPreservedWhenCaptureModeChanges() {
        let request = LocalRecordingRequest(mode: .audioOnly, applicationBundleIdentifier: nil, startImmediately: true, purpose: .meeting)
        var configuration = request.configuration(from: RecordingCaptureConfiguration())
        #expect(configuration.recordingKind == .meeting)
        #expect(configuration.capturesSystemAudio)
        configuration.applyMode(.window)
        #expect(configuration.recordingKind == .meeting)
        let normal = LocalRecordingRequest(mode: .audioOnly, applicationBundleIdentifier: nil, startImmediately: false, purpose: .recording)
        configuration = normal.configuration(from: configuration)
        #expect(configuration.recordingKind == .audio)
        #expect(!configuration.capturesSystemAudio)
    }

    @Test func cloudWireValuesRemainCompatibleAndScreenRecordingIsDistinct() {
        #expect(WorkbenchSessionType(sourceType: "meeting_record", capturesVideo: true) == .meetingRecord)
        #expect(WorkbenchSessionType(sourceType: "google_meet") == .googleMeet)
        #expect(WorkbenchSessionType(sourceType: "record", capturesVideo: true) == .screenRecord)
        #expect(WorkbenchSessionType(sourceType: "record", capturesVideo: false) == .record)
        #expect(WorkbenchSessionType(sourceType: "youtube") == .netVideo)
        #expect(WorkbenchSessionType(sourceType: "upload", capturesVideo: true) == .upload)
        #expect(WorkbenchSessionType(sourceType: "unknown", isDub: true) == .dub)
        #expect(WorkbenchSessionType.record.navGlyph != WorkbenchSessionType.screenRecord.navGlyph)
        #expect(WorkbenchSessionType.upload.navGlyph == .bookType)
        #expect(WorkbenchSessionType.record.navGlyph != WorkbenchSessionType.meetingRecord.navGlyph)
    }

    @Test func legacyRecordingMetadataMigratesOnceWithoutChangingRecentOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workbench.json")
        var job = WorkbenchTranscriptionJob(sourcePath: "/tmp/capture.mp4")
        job.isRecordedCapture = true
        job.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = WorkbenchSnapshot(schemaVersion: 7, transcriptions: [job], dubs: [])
        try JSONEncoder().encode(original).write(to: file)
        let persistence = WorkbenchPersistence(URL: file)
        let (loaded, _) = await persistence.load()
        let snapshot = try #require(loaded)
        let migrated = await persistence.recordingMetadataMigrated
        #expect(migrated)
        #expect(snapshot.transcriptions[0].recordingKind == .screen)
        #expect(snapshot.transcriptions[0].modifiedAt == job.modifiedAt)
        try await persistence.saveCommitted(snapshot, revision: 1)
        _ = await persistence.load()
        let migratedAgain = await persistence.recordingMetadataMigrated
        #expect(!migratedAgain)
    }
}
