import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Local model download authorization")
struct LocalModelDownloadAuthorizationStoreTests {
    @Test func authorizationPersistsRevisionAndReplacesOlderRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-authorization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelDownloadAuthorizationStore(rootURL: root)

        try await store.authorize(.init(id: .qwenTTS17B, revision: "old"))
        try await store.authorize(.init(id: .qwenTTS17B, revision: "current"))

        #expect(try await store.records() == [.init(id: .qwenTTS17B, revision: "current")])
    }

    @Test func revokedDownloadIsNotRecovered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-revocation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelDownloadAuthorizationStore(rootURL: root)

        try await store.authorize(.init(id: .forcedAligner, revision: "revision"))
        try await store.revoke(.forcedAligner)

        #expect(try await store.records().isEmpty)
    }

    @Test func searchUsesTheSharedWeMMDownloadAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-authorization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelDownloadAuthorizationStore(rootURL: root)

        let record = LocalModelDownloadAuthorizationStore.Record(
            id: SearchIndexConfig.modelID, revision: SearchIndexConfig.model.revision
        )
        try await store.authorize(record)
        try await store.authorize(record)
        #expect(try await store.records() == [record])
        try await store.revoke(SearchIndexConfig.modelID)
        #expect(try await store.records().isEmpty)
    }
}
