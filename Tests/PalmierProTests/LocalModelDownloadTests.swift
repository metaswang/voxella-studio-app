import Foundation
import Testing
@testable import PalmierPro
#if BUNDLED_SPEECH
import HuggingFace

@Suite("Anonymous model downloads")
struct LocalModelDownloadTests {
    @Test func publicDownloadsIgnoreEnvironmentAuthenticationAndBlobCache() async {
        let client = LocalModelDownload.client()
        #expect(await client.bearerToken == nil)
        #expect(client.host.host == "huggingface.co")
        #expect(client.cache == nil)
    }

    @Test func slashETagDoesNotBecomeAFilePath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LocalModelDownload.client(session: session)
        let data = try await client.downloadContentsOfFile(
            at: "config.json", from: Repo.ID(rawValue: "test/model")!,
            revision: String(repeating: "a", count: 40)
        )
        #expect(data == Data("{}".utf8))
    }

    @Test func destinationSnapshotTransferCompletesWithoutHubCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await LocalModelDownload.transferSnapshot(
            repository: Repo.ID(rawValue: "test/model")!,
            revision: String(repeating: "a", count: 40),
            to: directory,
            matching: ["*.safetensors"],
            session: session
        ) { _ in }
    }

    @Test func snapshotTransferPreservesAccessFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: HTTPClientError.self) {
            try await LocalModelDownload.transferSnapshot(
                repository: Repo.ID(rawValue: "denied/model")!,
                revision: String(repeating: "a", count: 40),
                to: directory,
                matching: ["*.safetensors"],
                session: session
            ) { _ in }
        }
    }

    @Test func snapshotTransferPreservesCancellationBeforeStart() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await LocalModelDownload.transferSnapshot(
                repository: Repo.ID(rawValue: "test/model")!,
                revision: String(repeating: "a", count: 40),
                to: URL(fileURLWithPath: "/unused-cancelled-download"),
                matching: ["*.safetensors"]
            ) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [401, 403, 429, 500])
    func httpErrorsDoNotExposeResponseSecretsOrPretendLicenseIsMissing(status: Int) throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://huggingface.co/test")!, statusCode: status,
            httpVersion: nil, headerFields: nil
        ))
        let message = LocalModelDownload.message(for: HTTPClientError.responseError(
            response: response, detail: "private-token-do-not-display"
        ))
        #expect(message.contains(String(status)))
        #expect(!message.contains("private-token"))
        #expect(!message.contains("accept the model license"))
    }
}
private final class ModelResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Each protocol instance uses only its immutable request and its own callbacks.
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let status = url.path.contains("/denied/") ? 403 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [
            "ETag": "W/\"1a-model/etag\"", "X-Repo-Commit": String(repeating: "a", count: 40)
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" {
            let body = url.path.contains("/tree/") ? "[]" : "{}"
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
