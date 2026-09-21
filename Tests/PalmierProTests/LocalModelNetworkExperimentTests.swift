import Foundation
import Testing
@testable import PalmierPro
#if BUNDLED_SPEECH
import HuggingFace

/// Run only against scripts/experiments/model_download_server.py on loopback.
@Suite("Real HTTP model download faults", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VOXELLA_MODEL_NETWORK_EXPERIMENT"] == "1"))
@MainActor
struct LocalModelNetworkExperimentTests {
    private let chunk = 256 * 1024

    @Test(arguments: ["truncate", "refresh", "wrong", "whole", "slow"])
    func recoversAndVerifiesBytes(_ scenario: String) async throws {
        let key = "\(scenario)__\(UUID().uuidString)"
        let revision = UUID().uuidString
        let repository = "experiment/\(key)"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        defer {
            try? FileManager.default.removeItem(at: destination)
            LocalModelChunkStore.shared.remove(repository: repository, revision: revision)
        }
        let probe = ExperimentProgress()
        try await transfer(repository, revision, destination, probe)
        let count = ["truncate", "slow"].contains(scenario) ? 3 : 1
        let expected = (0..<count).reduce(into: Data()) { $0.append(Data(repeating: UInt8(65 + $1), count: chunk)) }
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")) == expected)
        let counts = try await stats()["counts"] ?? [:]
        if scenario == "truncate" { #expect((counts[key + ":chunk:1"] ?? 0) >= 2) }
        if scenario == "whole" { #expect(counts[key + ":direct:0"] == 2) }
        if scenario == "refresh" { #expect(counts[key + ":snapshot"] == 2) }
        if scenario == "wrong" { #expect(counts[key + ":direct:0"] == 1) }
        if scenario == "slow" { #expect(await probe.sawPartialChunk) }
        print("EXPERIMENT PASS \(scenario): exact payload verified")
    }

    @Test(arguments: ["expired", "identity", "bad_range", "ignore_range"])
    func rejectsFaultWithoutInstalling(_ scenario: String) async throws {
        let key = "\(scenario)__\(UUID().uuidString)"
        let repository = "experiment/\(key)"
        let revision = UUID().uuidString
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        defer {
            try? FileManager.default.removeItem(at: destination)
            LocalModelChunkStore.shared.remove(repository: repository, revision: revision)
        }
        await #expect(throws: Error.self) { try await transfer(repository, revision, destination, ExperimentProgress()) }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("model.safetensors").path))
        let result = try await stats()
        if scenario == "expired" { #expect(result["counts"]?[key + ":snapshot"] == 3) }
        if scenario == "identity" { #expect(result["counts"]?[key + ":snapshot"] == 2) }
        if scenario == "ignore_range" {
            #expect((result["sent"]?[key + ":direct:0"] ?? 0) < 64 * 1024 * 1024)
        }
        print("EXPERIMENT PASS \(scenario): rejected without installation")
    }

    @Test func cancellationResumesOnlyIncompleteChunks() async throws {
        let key = "resume__\(UUID().uuidString)"
        let repository = "experiment/\(key)"
        let revision = UUID().uuidString
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        defer {
            try? FileManager.default.removeItem(at: destination)
            LocalModelChunkStore.shared.remove(repository: repository, revision: revision)
        }
        let probe = ExperimentProgress()
        let task = Task { try await transfer(repository, revision, destination, probe) }
        for _ in 0..<100 {
            if await probe.sawPartialChunk { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        await #expect(throws: Error.self) { try await task.value }
        try await transfer(repository, revision, destination, ExperimentProgress())
        let expected = (0..<3).reduce(into: Data()) { $0.append(Data(repeating: UInt8(65 + $1), count: chunk)) }
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")) == expected)
        let counts = try await stats()["counts"] ?? [:]
        #expect(counts[key + ":chunk:0"] == 1)
        #expect((counts[key + ":chunk:1"] ?? 0) >= 2)
        print("EXPERIMENT PASS cancellation/resume: completed chunk requested once")
    }

    private func transfer(_ repository: String, _ revision: String, _ destination: URL, _ probe: ExperimentProgress) async throws {
        let base = VoxellaAPIConfiguration.baseURL
        #expect(base.host == "127.0.0.1")
        guard base.host == "127.0.0.1" else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        try await LocalModelDownload.transferSnapshot(repository: Repo.ID(rawValue: repository)!, revision: revision,
            to: destination, matching: ["*.safetensors"], modelID: .forcedAligner, session: session) { progress in
                probe.record(progress)
            }
    }

    private func stats() async throws -> [String: [String: Int]] {
        let (data, _) = try await URLSession.shared.data(from: VoxellaAPIConfiguration.baseURL.appendingPathComponent("stats"))
        return try JSONDecoder().decode([String: [String: Int]].self, from: data)
    }
}

@MainActor private final class ExperimentProgress {
    var sawPartialChunk = false
    func record(_ value: LocalModelTransferProgress) {
        if value.completedBytes > 256 * 1024, value.completedBytes < value.totalBytes,
           value.completedBytes % (256 * 1024) != 0 { sawPartialChunk = true }
    }
}
#endif
