import Foundation
import Observation

@Observable
@MainActor
final class KnowledgeGraphSettings {
    static let shared = KnowledgeGraphSettings()

    private static let enabledKey = "voxella.knowledge-graph.enabled.v1"

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: .aiConfigurationDidChange, object: nil)
            guard isEnabled else { return }
            SessionIndexCoordinator.shared.backfillKnowledgeGraph()
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }
}

@MainActor
enum KnowledgeGraphAvailability {
    static func canRun(_ useCase: LLMUseCase) -> Bool {
        guard KnowledgeGraphSettings.shared.isEnabled,
              !HostedCreditAvailability.shared.isExhausted
        else { return false }
        switch AITransportPolicy.current {
        case .hosted:
            return true
        case .byok:
            return LLMSettingsStore.shared.hasConfiguredModel(for: useCase)
        case .unavailable:
            return false
        }
    }

    static func visibleFilter(
        scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?
    ) -> SessionSearchFilter {
        let signedIn = AccountService.shared.isSignedIn
        let owner = AccountService.shared.userID?.uuidString
        switch scope {
        case .all:
            return .visible(
                isSignedIn: signedIn,
                uiFilter: originFilter,
                cloudOwnerUserID: owner,
                limit: 30
            )
        case let .session(id):
            return .visible(
                isSignedIn: signedIn,
                sessionID: id,
                uiFilter: originFilter,
                cloudOwnerUserID: owner,
                limit: 30
            )
        case let .sessions(ids):
            return .visible(
                isSignedIn: signedIn,
                sessionIDs: Set(ids),
                uiFilter: originFilter,
                cloudOwnerUserID: owner,
                limit: 30
            )
        }
    }
}

struct KnowledgeGraphRecallService: Sendable {
    typealias ClientFactory = @Sendable () async throws -> any LLMTextClient

    let store: SessionIndexStore
    private let clientFactory: ClientFactory?

    init(store: SessionIndexStore, clientFactory: ClientFactory? = nil) {
        self.store = store
        self.clientFactory = clientFactory
    }

    func recall(
        query: String,
        filter: SessionSearchFilter,
        maximumHops: Int = 2
    ) async throws -> [SessionSearchHit] {
        let isAvailable: Bool
        if clientFactory != nil {
            isAvailable = true
        } else {
            isAvailable = await MainActor.run(body: {
                KnowledgeGraphAvailability.canRun(.graphQueryUnderstanding)
            })
        }
        guard isAvailable else {
            return []
        }
        let intent = try await GraphQueryUnderstanding.resolve(
            query,
            clientFactory: clientFactory
        )
        try Task.checkCancellation()
        let scopes = graphScopes(for: filter)
        let starting = try await store.graphEntities(matching: intent.entities, scopes: scopes)
        guard !starting.isEmpty else { return [] }

        let hops = min(3, max(1, min(maximumHops, intent.maximumHops)))
        var visited = Set(starting.map(\.id))
        var frontier = Array(visited)
        for _ in 0..<hops where !frontier.isEmpty && visited.count < 80 {
            try Task.checkCancellation()
            let relations = try await store.graphNeighbors(entityIDs: frontier, limit: 20)
            let next = relations.flatMap { [$0.subjectID, $0.objectID] }
                .filter { !visited.contains($0) }
            let admitted = Array(next.prefix(min(20, 80 - visited.count)))
            visited.formUnion(admitted)
            frontier = admitted
        }
        return try await store.graphChunks(entityIDs: Array(visited), filter: filter, limit: 20)
    }

    private func graphScopes(for filter: SessionSearchFilter) -> Set<String> {
        let origins = filter.sourceOrigins ?? Set(KnowledgeSourceOrigin.allCases)
        var scopes: Set<String> = []
        if origins.contains(.local) { scopes.insert("local") }
        if origins.contains(.cloud), let owner = filter.cloudOwnerUserID {
            scopes.insert(KnowledgeGraphSchema.scopeKey(origin: .cloud, ownerUserID: owner))
        }
        return scopes
    }
}

private struct GraphQueryIntent: Decodable, Sendable {
    var entities: [String]
    var maximumHops: Int

    private enum CodingKeys: String, CodingKey {
        case entities
        case maximumHops = "maximum_hops"
    }
}

private enum GraphQueryUnderstanding {
    static func resolve(
        _ query: String,
        clientFactory: KnowledgeGraphRecallService.ClientFactory? = nil
    ) async throws -> GraphQueryIntent {
        let client: any LLMTextClient
        if let clientFactory {
            client = try await clientFactory()
        } else {
            client = try await makeClient(for: .graphQueryUnderstanding)
        }
        let response = try await client.complete(
            system: "Extract only explicit graph entity names from the user's question. Return JSON with entities (string array, at most 8) and maximum_hops (1 or 2). Do not answer the question.",
            user: query
        )
        let decoded = try decode(GraphQueryIntent.self, from: response)
        let entities = Array(Set(decoded.entities.map(KnowledgeGraphSchema.normalizedName)))
            .filter { !$0.isEmpty }
            .prefix(8)
        return GraphQueryIntent(entities: Array(entities), maximumHops: min(2, max(1, decoded.maximumHops)))
    }
}

struct KnowledgeGraphIngestionService: Sendable {
    typealias ClientFactory = @Sendable () async throws -> any LLMTextClient

    let store: SessionIndexStore
    private let clientFactory: ClientFactory?

    init(store: SessionIndexStore, clientFactory: ClientFactory? = nil) {
        self.store = store
        self.clientFactory = clientFactory
    }

    func rebuild(_ source: KnowledgeGraphSource) async throws {
        let isAvailable: Bool
        if clientFactory != nil {
            isAvailable = true
        } else {
            isAvailable = await MainActor.run(body: {
                KnowledgeGraphAvailability.canRun(.graphExtraction)
            })
        }
        guard isAvailable else {
            return
        }
        let client: any LLMTextClient
        if let clientFactory {
            client = try await clientFactory()
        } else {
            client = try await makeClient(for: .graphExtraction)
        }
        var entities: [KnowledgeGraphEntity] = []
        var relations: [KnowledgeGraphRelation] = []
        for batch in source.chunks.chunked(into: 6) {
            try Task.checkCancellation()
            let extraction = try await extract(batch: batch, client: client)
            entities.append(contentsOf: extraction.entities)
            relations.append(contentsOf: extraction.relations)
        }
        let canCommit: Bool
        if clientFactory != nil {
            canCommit = true
        } else {
            canCommit = await MainActor.run(body: {
                KnowledgeGraphAvailability.canRun(.graphExtraction)
            })
        }
        guard canCommit else {
            return
        }
        _ = try await store.replaceGraph(
            source: source,
            extraction: KnowledgeGraphExtraction(entities: entities, relations: relations)
        )
    }

    private func extract(
        batch: [SessionSearchHit],
        client: any LLMTextClient
    ) async throws -> KnowledgeGraphExtraction {
        let chunkIDs = Set(batch.map(\.unitID))
        let chunks = batch.map { "[chunk_id=\($0.unitID)]\n\($0.text)" }.joined(separator: "\n\n")
        let response = try await client.complete(
            system: """
            Extract a small graph from only the supplied transcript chunks. Return strict JSON:
            {"entities":[{"name":"...","type":"person|organization|project|place|event|concept|other","aliases":["..."],"chunkIDs":[1]}],"relations":[{"subject":"entity name","predicate":"ASSOCIATED_WITH|ATTENDS|AUTHORS|DECIDES|DISCUSSES|LEADS|LOCATED_IN|MENTIONS|OWNS|RELATED_TO|REQUIRES|WORKS_ON","object":"entity name","evidenceChunkIDs":[1]}]}.
            Every chunk ID must be one supplied in this batch. Omit uncertain entities and relations. Do not include prose or markdown.
            """,
            user: chunks
        )
        return try decode(KnowledgeGraphExtraction.self, from: response)
            .validated(allowedChunkIDs: chunkIDs)
    }
}

private enum GraphServiceError: LocalizedError {
    case invalidModelOutput

    var errorDescription: String? { "The graph model returned an invalid structured result." }
}

@MainActor
private func makeClient(for useCase: LLMUseCase) async throws -> any LLMTextClient {
    guard KnowledgeGraphAvailability.canRun(useCase) else {
        throw KnowledgeQAError.llmUnavailable
    }
    return try await AITransportPolicy.makeTextClient(for: useCase)
}

private func decode<T: Decodable>(_ type: T.Type, from response: String) throws -> T {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: String
    if trimmed.hasPrefix("```") {
        json = trimmed
            .split(separator: "\n")
            .dropFirst()
            .dropLast()
            .joined(separator: "\n")
    } else {
        json = trimmed
    }
    guard let data = json.data(using: .utf8) else { throw GraphServiceError.invalidModelOutput }
    return try JSONDecoder().decode(T.self, from: data)
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
