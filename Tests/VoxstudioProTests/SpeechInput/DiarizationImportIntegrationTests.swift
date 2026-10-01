#if BUNDLED_SPEECH
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Opt-in diarization import persistence", .serialized)
struct DiarizationImportIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_DIARIZATION_IMPORT"] == "1"))
    func fullPipelineResultSurvivesDiskReload() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXELLA_DIARIZATION_IMPORT_AUDIO"])
        try await Self.run(sourceURL: URL(fileURLWithPath: path))
    }

    @concurrent
    private static func run(sourceURL: URL) async throws {
        let output = try await LocalSpeechPipeline.shared.transcribeDetailed(
            sourceURL: sourceURL, languageCode: nil, speakerCount: 2
        ) { update in
            print("DIARIZATION_IMPORT stage=\(update.stage) fraction=\(update.fraction)")
        }
        #expect(output.diarizationDiagnostics.backend == .mlxStreamingSortformer)
        #expect(output.diarizationDiagnostics.processedChunks > 0)
        #expect(!output.result.words.isEmpty)
        let speakers = Set(output.result.words.compactMap(\.speaker))
        #expect(!speakers.isEmpty && speakers.count <= 4)
        #expect(output.result.words.allSatisfy {
            guard let start = $0.start, let end = $0.end else { return false }
            return start.isFinite && end.isFinite && start >= 0 && end >= start
        })
        #expect(zip(output.result.words, output.result.words.dropFirst()).allSatisfy {
            ($0.start ?? 0) <= ($1.start ?? 0)
        })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("workbench.json")
            var job = WorkbenchTranscriptionJob(sourcePath: sourceURL.path)
            let artifacts = CompletedTranscriptionArtifacts(
                rawResult: output.result, result: output.result, subtitleTrack: nil, translationTracks: [],
                diarizationDiagnostics: output.diarizationDiagnostics,
                alignmentDiagnostics: output.alignmentDiagnostics, processedSourcePath: nil
            )
            #expect(TranscriptionCommitPolicy.shouldCommit(status: .completed, artifacts: artifacts))
            artifacts.apply(to: &job)
            job.state = .completed
            await WorkbenchPersistence(URL: url).save(
                .init(schemaVersion: 7, transcriptions: [job], dubs: []), revision: 1
            )
            let (snapshot, outcome) = await WorkbenchPersistence(URL: url).load()
            #expect(outcome == .loaded)
            let restored = try #require(snapshot?.transcriptions.first)
            #expect(restored.state == .completed)
            #expect(restored.result == output.result)
            #expect(restored.diarizationDiagnostics == output.diarizationDiagnostics)
            #expect(restored.transcriptionAlignmentDiagnostics == output.alignmentDiagnostics)
            print("DIARIZATION_IMPORT persisted=true words=\(output.result.words.count) speakers=\(speakers.count) chunks=\(output.diarizationDiagnostics.processedChunks)")
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
