import Foundation
import Testing
@testable import PalmierPro

@Suite("Knowledge session dataset experiment")
struct KnowledgeSessionDatasetExperiment {
    @Test
    func rebuildsAndQueriesTheLocalSessionDatasetWithoutRemoteModels() async throws {
        guard ProcessInfo.processInfo.environment["VOXSTUDIO_KNOWLEDGE_SESSION_EXPERIMENT"] == "1" else {
            return
        }

        let workbenchURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "VOXSTUDIO_KNOWLEDGE_WORKBENCH"
        ] ?? "/Users/adamwang/Library/Application Support/VoxStudio/workbench.json")
        let snapshot = try await loadSnapshot(from: workbenchURL)
        let (persistedSnapshot, loadOutcome) = await WorkbenchPersistence(URL: workbenchURL).load()
        #expect(loadOutcome == .loaded)
        #expect(persistedSnapshot?.transcriptions.count == snapshot.transcriptions.count)
        let indexedSnapshots = snapshot.transcriptions.compactMap(SessionIndexSnapshot.from)
        let localIndexedSnapshots = indexedSnapshots.filter { $0.sourceOrigin == .local }
        #expect(!indexedSnapshots.isEmpty)
        #expect(!localIndexedSnapshots.isEmpty)

        let directory = try await makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("index.sqlite")
        do {
            let store = try SessionIndexStore(url: indexURL)
            for item in indexedSnapshots {
                try await store.replaceLexical(
                    snapshot: item,
                    clips: CuePacker.pack(cues: item.cues)
                )
            }

            let indexedIDs = try await store.sessionIDs()
            #expect(Set(indexedSnapshots.map(\.sessionID)) == Set(indexedIDs))

            let filter = SessionSearchFilter.visible(
                isSignedIn: false,
                uiFilter: [.local],
                limit: 30
            )
            let source = try #require(try await graphSourceWithSearchableToken(in: store))
            let search = SearchService(store: store, embeddings: nil)
            let hits = try await search.transcriptSearch(query: source.token, filter: filter)
            #expect(!hits.isEmpty)
            #expect(hits.count <= 30)

            let candidates = Array(hits.prefix(30))
            #if BUNDLED_SPEECH
            let rerankerScores = try await RerankerService.shared.scores(
                query: source.token,
                chunks: candidates.map(\.text)
            )
            #expect(rerankerScores.count == candidates.count)
            #expect(rerankerScores.allSatisfy { $0.isFinite && (0...1).contains($0) })
            let rerankerAdmitted = KnowledgeRerankPolicy.thresholded(
                zip(candidates, rerankerScores).map { KnowledgeRerankedHit(hit: $0.0, score: $0.1) }
            )
            #expect(rerankerAdmitted.count <= candidates.count)
            #endif
            let vectors = (try? await store.textEmbeddings(unitIDs: candidates.map(\.unitID))) ?? [:]
            let selected = KnowledgeMMR.select(
                candidates.map { KnowledgeRerankedHit(hit: $0, score: $0.score) },
                vectors: vectors
            )
            #expect(!selected.isEmpty)
            #expect(selected.count <= 8)

            let anchors = selected.map(\.hit)
            var metadata: [UUID: KnowledgeSessionContextMetadata] = [:]
            var neighbors: [Int: [SessionSearchHit]] = [:]
            for anchor in anchors {
                if let card = try await store.sessionCard(id: anchor.sessionID) {
                    metadata[anchor.sessionID] = KnowledgeSessionContextMetadata(
                        title: card.title,
                        summary: card.summaryMarkdown ?? card.summaryExcerpt
                    )
                }
                if anchor.text.count < KnowledgeContextBuilder.shortAnchorLimit {
                    neighbors[anchor.unitID] = try await store.contextNeighbors(for: anchor)
                }
            }
            let context = KnowledgeContextBuilder.build(
                anchors: anchors,
                metadata: metadata,
                neighbors: neighbors,
                maxChars: 10_000
            )
            #expect(!context.isEmpty)
            #expect(context.count <= 10_000)
            #expect(KnowledgeQAService.citation(from: anchors[0]).chunkIndex == anchors[0].unitID)

            let entity = "experiment entity"
            let graphSources = try await store.graphSourcesNeedingRebuild(
                sourceOrigins: [.local],
                cloudOwnerUserID: nil
            )
            #expect(graphSources.count == localIndexedSnapshots.count)
            let ingestion = KnowledgeGraphIngestionService(
                store: store,
                clientFactory: { FixtureGraphClient() }
            )
            for graphSource in graphSources {
                try await ingestion.rebuild(graphSource)
            }
            let pendingGraphSources = try await store.graphSourcesNeedingRebuild(
                sourceOrigins: [.local],
                cloudOwnerUserID: nil
            )
            #expect(pendingGraphSources.isEmpty)

            let scopes = Set([KnowledgeGraphSchema.scopeKey(origin: .local, ownerUserID: nil)])
            let entities = try await store.graphEntities(matching: [entity], scopes: scopes)
            #expect(entities.count == 1)
            let graphHits = try await KnowledgeGraphRecallService(
                store: store,
                clientFactory: { FixtureGraphClient() }
            ).recall(query: "experiment entity", filter: filter)
            #expect(!graphHits.isEmpty)
            #expect(graphHits.count <= 20)
            #expect(graphHits.allSatisfy { $0.matchSource == "graph" })

            let removedSource = try #require(graphSources.first)
            try await store.deleteGraphSource(sessionID: removedSource.sessionID)
            let removedSourceHits = try await store.graphChunks(
                entityIDs: entities.map(\.id),
                filter: SessionSearchFilter.visible(
                    isSignedIn: false,
                    sessionID: removedSource.sessionID,
                    uiFilter: [.local],
                    limit: 20
                ),
                limit: 20
            )
            #expect(removedSourceHits.isEmpty)
        } catch {
            try? await removeTemporaryDirectory(directory)
            throw error
        }
        try await removeTemporaryDirectory(directory)
    }

    private func loadSnapshot(from url: URL) async throws -> WorkbenchSnapshot {
        try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(contentsOf: url))
        }.value
    }

    private func makeTemporaryDirectory() async throws -> URL {
        try await Task.detached(priority: .utility) {
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: FileManager.default.temporaryDirectory,
                create: true
            )
        }.value
    }

    private func removeTemporaryDirectory(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: url)
        }.value
    }

    private func graphSourceWithSearchableToken(
        in store: SessionIndexStore
    ) async throws -> (sessionID: UUID, token: String)? {
        for sessionID in try await store.sessionIDs() {
            guard let source = try await store.graphSource(sessionID: sessionID) else { continue }
            guard source.sourceOrigin == .local else { continue }
            for chunk in source.chunks {
                let token = chunk.text.unicodeScalars
                    .split(whereSeparator: { !CharacterSet.letters.contains($0) })
                    .map(String.init)
                    .first(where: { $0.count >= 5 })
                if let token {
                    return (sessionID, token)
                }
            }
        }
        return nil
    }
}

private struct FixtureGraphClient: LLMTextClient {
    func complete(system: String, user: String) async throws -> String {
        if system.contains("Extract only explicit graph entity names") {
            return #"{"entities":["experiment entity"],"maximum_hops":2}"#
        }
        let range = NSRange(user.startIndex..., in: user)
        let expression = try NSRegularExpression(pattern: #"\[chunk_id=(\d+)\]"#)
        guard let match = expression.firstMatch(in: user, range: range),
              let identifierRange = Range(match.range(at: 1), in: user),
              let identifier = Int(user[identifierRange])
        else {
            throw GraphFixtureError.missingChunkID
        }
        return """
        {"entities":[{"name":"experiment entity","type":"concept","aliases":[],"chunkIDs":[\(identifier)]}],"relations":[]}
        """
    }
}

private enum GraphFixtureError: Error {
    case missingChunkID
}
