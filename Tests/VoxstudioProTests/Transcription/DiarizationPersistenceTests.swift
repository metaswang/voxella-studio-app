import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Diarization result persistence")
struct DiarizationPersistenceTests {
    private static func artifacts() -> CompletedTranscriptionArtifacts {
        let result = TranscriptionResult(
            text: "Hello again", language: "en",
            words: [
                .init(text: "Hello", start: 0.16, end: 0.72, speaker: "Speaker 1", speakerConfidence: 0.91),
                .init(text: "again", start: 1.28, end: 1.92, speaker: "Speaker 2", speakerConfidence: 0.88)
            ],
            segments: [
                .init(text: "Hello", start: 0.16, end: 0.72, speaker: "Speaker 1"),
                .init(text: "again", start: 1.28, end: 1.92, speaker: "Speaker 2")
            ], asrEngine: .whisper
        )
        return CompletedTranscriptionArtifacts(
            rawResult: result, result: result, subtitleTrack: nil, translationTracks: [],
            diarizationDiagnostics: .init(
                backend: .mlxStreamingSortformer, elapsedSeconds: 18.1, processedChunks: 240,
                detectedSpeakerCount: 2, requestedSpeakerCount: nil, warnings: [],
                modelRevision: "fixture-revision", peakMLXMemoryBytes: 3_425_139_788,
                processedAudioDuration: 3605.028, chunkDuration: 15.04, fifoMax: 0, spkcacheMax: 188
            ),
            alignmentDiagnostics: nil, processedSourcePath: nil
        )
    }

    @concurrent
    private static func withSnapshotFile(_ operation: @Sendable (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await operation(directory.appendingPathComponent("workbench.json"))
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        try FileManager.default.removeItem(at: directory)
    }

    @Test func completedSpeakerResultsSurviveDiskReload() async throws {
        try await Self.withSnapshotFile { url in
            let artifacts = Self.artifacts()
            var job = WorkbenchTranscriptionJob(sourcePath: url.deletingLastPathComponent().appendingPathComponent("fixture.wav").path)
            #expect(TranscriptionCommitPolicy.shouldCommit(status: .completed, artifacts: artifacts))
            artifacts.apply(to: &job)
            job.state = .completed
            await WorkbenchPersistence(URL: url).save(
                .init(schemaVersion: 7, transcriptions: [job], dubs: []), revision: 1
            )

            let (snapshot, outcome) = await WorkbenchPersistence(URL: url).load()
            #expect(outcome == .loaded)
            let restored = try #require(snapshot?.transcriptions.first)
            #expect(restored.id == job.id)
            #expect(restored.state == .completed)
            #expect(restored.result == artifacts.result)
            #expect(restored.diarizationDiagnostics == artifacts.diarizationDiagnostics)
        }
    }

    @Test(arguments: [MediaJobStatus.cancelled, .failed])
    func unsuccessfulReplacementPreservesSavedSpeakerResults(status: MediaJobStatus) async throws {
        try await Self.withSnapshotFile { url in
            let persistence = WorkbenchPersistence(URL: url)
            var job = WorkbenchTranscriptionJob(sourcePath: "fixture.wav")
            let original = Self.artifacts()
            original.apply(to: &job)
            job.state = .completed
            let saved = WorkbenchSnapshot(schemaVersion: 7, transcriptions: [job], dubs: [])
            await persistence.save(saved, revision: 2)

            #expect(!TranscriptionCommitPolicy.shouldCommit(status: status, artifacts: original))
            var stale = job
            stale.result = nil
            stale.diarizationDiagnostics = nil
            await persistence.save(.init(schemaVersion: 7, transcriptions: [stale], dubs: []), revision: 1)

            let (snapshot, outcome) = await WorkbenchPersistence(URL: url).load()
            #expect(outcome == .loaded)
            #expect(snapshot?.transcriptions.first?.result == original.result)
            #expect(snapshot?.transcriptions.first?.diarizationDiagnostics == original.diarizationDiagnostics)
        }
    }
}
