import Foundation
import Testing
@testable import VoxstudioPro

#if BUNDLED_SPEECH
import HuggingFace

@Suite("R2-backed model downloads")
struct LocalModelDownloadTests {
    @Test func requestsSnapshotFromAPIAndDownloadsSignedFiles() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectModelResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await LocalModelDownload.transferSnapshot(
            repository: Repo.ID(rawValue: "test/model")!,
            revision: String(repeating: "a", count: 40),
            to: directory,
            matching: ["*.safetensors"],
            modelID: .forcedAligner,
            session: session
        ) { _ in }

        let downloaded = directory.appendingPathComponent("model.safetensors")
        #expect(try Data(contentsOf: downloaded) == Data("model".utf8))
    }

    @Test func downloadsSignedChunksAndWritesTheAssembledFile() async throws {
        let revision = UUID().uuidString
        defer { LocalModelChunkStore.shared.remove(repository: "chunk/model", revision: revision) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkModelResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await LocalModelDownload.transferSnapshot(
            repository: Repo.ID(rawValue: "chunk/model")!,
            revision: revision,
            to: directory,
            matching: ["*.safetensors"],
            modelID: .forcedAligner,
            session: session
        ) { _ in }

        let downloaded = directory.appendingPathComponent("model.safetensors")
        #expect(try Data(contentsOf: downloaded) == Data("abcdefgh".utf8))
    }

    @Test func rejectsInvalidSnapshotPathBeforeWritingOutsideDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: Error.self) {
            try LocalModelDownload.destinationURL(for: "../escape.safetensors", in: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.safetensors").path))
    }

    @Test func httpErrorsDoNotExposeRawResponseContent() throws {
        let error = URLError(.badServerResponse)
        let message = LocalModelDownload.message(for: error)
        #expect(!message.contains("token"))
        #expect(message.contains("resource download"))
    }

    @Test func cancellationIsCheckedBeforeRequest() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await LocalModelDownload.transferSnapshot(
                repository: Repo.ID(rawValue: "test/model")!,
                revision: String(repeating: "a", count: 40),
                to: URL(fileURLWithPath: "/unused-cancelled-download"),
                matching: ["*.safetensors"],
                modelID: .forcedAligner
            ) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class DirectModelResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.httpMethod == "POST" {
            sendJSON("{\"files\":[{\"path\":\"model.safetensors\",\"url\":\"https://r2.example/model\",\"size_bytes\":5}]}")
            return
        }
        send(status: 200, body: Data("model".utf8), contentType: "application/octet-stream")
    }

    override func stopLoading() {}
}

private final class ChunkModelResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if request.httpMethod == "POST" {
            sendJSON("{\"files\":[{\"path\":\"model.safetensors\",\"url\":\"https://r2.example/model\",\"size_bytes\":8,\"etag\":\"etag-1\",\"download\":{\"version\":1,\"chunk_size_bytes\":4,\"chunk_url_template\":\"https://cdn.example/model?chunk={chunk}\",\"expires_at\":4102444800}}]}")
            return
        }
        if url.host == "cdn.example" {
            let chunk = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "chunk" }?.value
            let body = chunk == "1" ? Data("efgh".utf8) : Data("abcd".utf8)
            send(status: 200, body: body, contentType: "application/octet-stream", headers: ["ETag": "\"etag-1\"", "X-Model-Chunk": chunk ?? "0", "X-Model-Object-Size": "8"])
            return
        }
        send(status: 200, body: Data("model".utf8), contentType: "application/octet-stream")
    }

    override func stopLoading() {}
}

private extension URLProtocol {
    func sendJSON(_ body: String) {
        send(status: 200, body: Data(body.utf8), contentType: "application/json")
    }

    func send(status: Int, body: Data, contentType: String, headers: [String: String] = [:]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: nil,
                  headerFields: headers.merging(["Content-Type": contentType, "Content-Length": String(body.count)]) { _, new in new }
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
