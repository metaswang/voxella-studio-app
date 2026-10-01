import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Model download scheduler")
struct LocalModelDownloadSchedulerTests {
    actor Probe {
        private var active = 0
        private(set) var maximumActive = 0
        private var releases: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            active += 1
            maximumActive = max(maximumActive, active)
            await withCheckedContinuation { releases.append($0) }
            active -= 1
        }

        func releaseNext() {
            releases.removeFirst().resume()
        }

        func releaseCount() -> Int { releases.count }
    }

    @Test func capsGlobalTransfersAndSplitsFairlyAcrossModels() async throws {
        let scheduler = LocalModelDownloadScheduler(maximumTransfers: 4)
        let probe = Probe()
        let first = (0..<4).map { _ in
            Task {
                try await scheduler.withPermit(for: .whisperLargeV3Turbo8Bit) {
                    await probe.enter()
                }
            }
        }
        while await probe.releaseCount() < 4 { await Task.yield() }
        #expect(await scheduler.activeTransferCount() == 4)
        #expect(await scheduler.activeTransferCount(for: .whisperLargeV3Turbo8Bit) == 4)

        let second = Task {
            try await scheduler.withPermit(for: .weMMEmbedding2B4Bit) {
                await probe.enter()
            }
        }
        await probe.releaseNext()
        while await probe.releaseCount() < 4 { await Task.yield() }
        #expect(await scheduler.activeTransferCount(for: .weMMEmbedding2B4Bit) == 1)

        for _ in 0..<4 { await probe.releaseNext() }
        for task in first { try await task.value }
        try await second.value
        #expect(await probe.maximumActive == 4)
    }
}

@Suite("Chunk staging store")
struct LocalModelChunkStoreTests {
    @Test func resumesCompletedChunksAfterReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelChunkStore(rootURL: root)
        var state = try store.load(
            repository: "owner/name",
            revision: "rev",
            path: "model.safetensors",
            etag: "etag-1",
            sizeBytes: 16,
            chunkSizeBytes: 8
        )
        let urls = try store.location(repository: "owner/name", revision: "rev", path: "model.safetensors", etag: "etag-1")
        try LocalModelChunkIO.writeChunk(Data("abcdefgh".utf8), to: urls.payload, offset: 0)
        state = try store.markChunkComplete(0, state: state)
        let restored = try store.load(
            repository: "owner/name",
            revision: "rev",
            path: "model.safetensors",
            etag: "etag-1",
            sizeBytes: 16,
            chunkSizeBytes: 8
        )
        #expect(restored.completedChunks == [0])
    }

    @Test func prunesCancelledStagingAfterRetentionWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelChunkStore(rootURL: root)
        _ = try store.load(
            repository: "owner/name",
            revision: "rev",
            path: "model.safetensors",
            etag: "etag-1",
            sizeBytes: 8,
            chunkSizeBytes: 8
        )
        store.markCancelled(repository: "owner/name", revision: "rev")
        store.pruneExpired(now: Date().addingTimeInterval(LocalModelDownloadLimits.cancelledStagingRetention + 1))
        let urls = try store.location(repository: "owner/name", revision: "rev", path: "model.safetensors", etag: "etag-1")
        #expect(!FileManager.default.fileExists(atPath: urls.payload.path))
    }
}

@Suite("Range fallback validation")
struct LocalModelChunkIOTests {
    @Test func rejectsMissingOrWrongTotalRange() throws {
        for headers in [[:], ["Content-Range": "bytes 8-15/999"]] {
            let response = HTTPURLResponse(url: URL(string: "https://r2.example/model")!, statusCode: 206, httpVersion: nil, headerFields: headers)!
            #expect(throws: LocalModelChunkIO.TransferError.self) {
                try LocalModelChunkIO.validatedRangeBody(data: Data(repeating: 1, count: 8), response: response,
                    expectedOffset: 8, expectedLength: 8, expectedTotal: 16)
            }
        }
    }

    @Test func rejectsWrongChunkEvenWhenLengthMatches() throws {
        let response = HTTPURLResponse(url: URL(string: "https://cdn.example/model")!, statusCode: 200, httpVersion: nil,
            headerFields: ["ETag": "\"etag-1\"", "X-Model-Chunk": "1", "X-Model-Object-Size": "16"])!
        #expect(throws: LocalModelChunkIO.TransferError.self) {
            try LocalModelChunkIO.validateChunkHeaders(response, chunk: 0, etag: "etag-1", total: 16)
        }
    }

    @Test func rejectsACompleteFileReturnedForAPartialRange() throws {
        let url = URL(string: "https://r2.example/model")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "8"])!
        #expect(throws: LocalModelChunkIO.TransferError.self) {
            try LocalModelChunkIO.validatedRangeBody(
                data: Data("abcdefgh".utf8),
                response: response,
                expectedOffset: 8,
                expectedLength: 8,
                expectedTotal: 16
            )
        }
    }

    @Test func acceptsAMatchingPartialContentRange() throws {
        let url = URL(string: "https://r2.example/model")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 8-15/16", "Content-Length": "8"]
        )!
        let data = try LocalModelChunkIO.validatedRangeBody(
            data: Data("ijklmnop".utf8),
            response: response,
            expectedOffset: 8,
            expectedLength: 8,
            expectedTotal: 16
        )
        #expect(data == Data("ijklmnop".utf8))
    }
}
