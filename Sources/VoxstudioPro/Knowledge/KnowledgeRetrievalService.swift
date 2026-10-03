import Foundation

enum KnowledgeRetrievalPath: String, Sendable {
    case agent
    case legacy
}

enum KnowledgeGraphRecallStatus: String, Sendable {
    case used
    case disabled
    case unavailable
    case timeout
    case failed
}

enum KnowledgeRerankerStatus: String, Sendable {
    case used
    case timeout
    case failed
    case skipped
}

struct KnowledgeRetrievalRequest: Sendable {
    var query: String
    var originalQuery: String
    var scope: KnowledgeQAScope
    var originFilter: Set<KnowledgeSourceOrigin>?
    var resultLimit: Int
    var requestID: UUID
    var includeCatalog: Bool
    var retrievalPath: KnowledgeRetrievalPath
    var useGraph: Bool

    init(
        query: String,
        originalQuery: String? = nil,
        scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?,
        resultLimit: Int = 8,
        requestID: UUID,
        includeCatalog: Bool,
        retrievalPath: KnowledgeRetrievalPath,
        useGraph: Bool = false
    ) {
        self.query = query
        self.originalQuery = originalQuery ?? query
        self.scope = scope
        self.originFilter = originFilter
        self.resultLimit = resultLimit
        self.requestID = requestID
        self.includeCatalog = includeCatalog
        self.retrievalPath = retrievalPath
        self.useGraph = useGraph
    }

    var clampedResultLimit: Int {
        min(32, max(1, resultLimit))
    }
}

struct KnowledgeRetrievalDiagnostics: Equatable, Sendable {
    var hybridHitCount: Int = 0
    var graphAttempted: Bool = false
    var graphStatus: KnowledgeGraphRecallStatus = .disabled
    var graphHitCount: Int = 0
    var candidateCount: Int = 0
    var rerankerStatus: KnowledgeRerankerStatus = .skipped
}

struct KnowledgeRetrievalResult: Sendable {
    var hits: [SessionSearchHit]
    var diagnostics: KnowledgeRetrievalDiagnostics
}

/// Shared Hybrid + Graph recall, fusion, rerank, and MMR used by both
/// Legacy RAG and Agent semantic search tools.
struct KnowledgeRetrievalService: Sendable {
    var topK: Int = 30
    var candidateLimit: Int = 40
    var graphCandidateLimit: Int = 20
    var executionPolicy: KnowledgeQAExecutionPolicy = .default
    var dependencies: KnowledgeQAExecutionDependencies = .live

    func search(_ request: KnowledgeRetrievalRequest) async throws -> KnowledgeRetrievalResult {
        try await search(request, policy: executionPolicy)
    }

    func search(
        _ request: KnowledgeRetrievalRequest,
        policy: KnowledgeQAExecutionPolicy
    ) async throws -> KnowledgeRetrievalResult {
        var diagnostics = KnowledgeRetrievalDiagnostics()
        var visibleFilter = await makeVisibleFilter(
            scope: request.scope,
            originFilter: request.originFilter
        )
        visibleFilter.canonicalGenerations = await MainActor.run {
            Dictionary(uniqueKeysWithValues: WorkbenchStore.shared.sessions.compactMap { source in
                KnowledgeTranscriptMaterial.from(source).map { (source.id, $0.generation) }
            })
        }
        let filter = visibleFilter
        if filter.sourceOrigins?.isEmpty == true || filter.sessionIDs?.isEmpty == true {
            log(request: request, diagnostics: diagnostics)
            return KnowledgeRetrievalResult(hits: [], diagnostics: diagnostics)
        }

        if request.includeCatalog,
           Self.isCatalogQuery(request.originalQuery) || Self.isCatalogQuery(request.query)
        {
            let hits = try await catalogHits(filter: filter)
            diagnostics.candidateCount = hits.count
            log(request: request, diagnostics: diagnostics)
            return KnowledgeRetrievalResult(hits: hits, diagnostics: diagnostics)
        }

        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let (hybridHits, graphHits, graphAttempted, graphStatus) = try await KnowledgeQATimeout.run(policy.retrieval) {
            try await self.recallInParallel(
                service: service,
                query: request.query,
                filter: filter,
                policy: policy,
                requestID: request.requestID,
                useGraph: request.useGraph
            )
        }
        diagnostics.hybridHitCount = hybridHits.count
        diagnostics.graphAttempted = graphAttempted
        diagnostics.graphStatus = graphStatus
        diagnostics.graphHitCount = graphHits.count

        var candidates = Self.fuse(hybrid: hybridHits, graph: graphHits, limit: candidateLimit)
        candidates = Self.scoped(candidates, to: request.scope)
        diagnostics.candidateCount = candidates.count
        guard !candidates.isEmpty else {
            log(request: request, diagnostics: diagnostics)
            return KnowledgeRetrievalResult(hits: [], diagnostics: diagnostics)
        }

        let (selected, rerankerStatus) = try await rerank(
            query: request.query,
            candidates: candidates,
            service: service,
            policy: policy,
            requestID: request.requestID,
            limit: request.clampedResultLimit,
            coverSources: request.scope.sessionIDs.count > 1
        )
        diagnostics.rerankerStatus = rerankerStatus
        let hits = Array(selected.prefix(request.clampedResultLimit))
        log(request: request, diagnostics: diagnostics)
        return KnowledgeRetrievalResult(hits: hits, diagnostics: diagnostics)
    }

    func makeVisibleFilter(
        scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?
    ) async -> SessionSearchFilter {
        await MainActor.run {
            let signedIn = AccountService.shared.isSignedIn
            let owner = AccountService.shared.userID?.uuidString
            let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: signedIn, uiFilter: originFilter)
            switch scope {
            case .all:
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    uiFilter: originFilter,
                    cloudOwnerUserID: owner,
                    limit: topK
                )
            case let .session(sessionID):
                let session = WorkbenchStore.shared.sessions.first(where: { $0.id == sessionID })
                let origin = KnowledgeSourceOrigin.resolve(
                    isCloudStorage: session?.storage == .cloud,
                    hasRemoteSessionID: session?.remoteSessionID != nil || session?.isRemoteOnly == true
                )
                guard allowed.contains(origin) else {
                    return SessionSearchFilter(
                        sessionID: sessionID,
                        sourceOrigins: [],
                        cloudOwnerUserID: owner,
                        limit: topK
                    )
                }
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    sessionID: sessionID,
                    uiFilter: originFilter,
                    cloudOwnerUserID: owner,
                    limit: topK
                )
            case let .sessions(ids):
                let visibleIDs = Set(ids.filter { id in
                    let session = WorkbenchStore.shared.sessions.first(where: { $0.id == id })
                    let origin = KnowledgeSourceOrigin.resolve(
                        isCloudStorage: session?.storage == .cloud,
                        hasRemoteSessionID: session?.remoteSessionID != nil || session?.isRemoteOnly == true
                    )
                    return allowed.contains(origin)
                })
                guard !visibleIDs.isEmpty else {
                    return SessionSearchFilter(
                        sessionIDs: [],
                        sourceOrigins: [],
                        cloudOwnerUserID: owner,
                        limit: topK
                    )
                }
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    sessionIDs: visibleIDs,
                    uiFilter: originFilter,
                    cloudOwnerUserID: owner,
                    limit: topK
                )
            }
        }
    }

    static func isCatalogQuery(_ query: String) -> Bool {
        let normalized = query.lowercased()
        let markers = [
            "session", "sessions", "duration", "longest", "shortest", "recent", "latest",
            "list", "how many", "type", "origin", "date", "时长", "最长", "最短", "最近",
            "哪些 session", "所有 session", "多少个", "类型", "来源", "日期"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private func recallInParallel(
        service: SearchService,
        query: String,
        filter: SessionSearchFilter,
        policy: KnowledgeQAExecutionPolicy,
        requestID: UUID,
        useGraph: Bool
    ) async throws -> ([SessionSearchHit], [SessionSearchHit], Bool, KnowledgeGraphRecallStatus) {
        if !useGraph {
            return (try await hybridRecall(service: service, query: query, filter: filter), [], false, .disabled)
        }
        async let hybrid = hybridRecall(service: service, query: query, filter: filter)
        async let graph = graphRecallSoft(
            store: service.store,
            query: query,
            filter: filter,
            policy: policy,
            requestID: requestID
        )
        let hybridHits = try await hybrid
        let graphResult = await graph
        return (hybridHits, graphResult.hits, graphResult.attempted, graphResult.status)
    }

    private func hybridRecall(
        service: SearchService,
        query: String,
        filter: SessionSearchFilter
    ) async throws -> [SessionSearchHit] {
        if let hybridRecall = dependencies.hybridRecall {
            return Array((try await hybridRecall(query, filter)).prefix(topK))
        }
        let hits = try await service.transcriptSearch(query: query, filter: filter)
        return Array(hits.prefix(topK))
    }

    private func graphRecallSoft(
        store: SessionIndexStore,
        query: String,
        filter: SessionSearchFilter,
        policy: KnowledgeQAExecutionPolicy,
        requestID: UUID
    ) async -> (hits: [SessionSearchHit], attempted: Bool, status: KnowledgeGraphRecallStatus) {
        if dependencies.graphRecall == nil {
            let availability = await MainActor.run { () -> KnowledgeGraphRecallStatus? in
                if !KnowledgeGraphSettings.shared.isEnabled {
                    return .disabled
                }
                if !KnowledgeGraphAvailability.canRun(.graphQueryUnderstanding) {
                    return .unavailable
                }
                return nil
            }
            if let availability {
                return ([], false, availability)
            }
        }

        do {
            let hits = try await KnowledgeQATimeout.run(policy.graphRecall) {
                if let graphRecall = self.dependencies.graphRecall {
                    return try await graphRecall(query, filter)
                }
                return try await KnowledgeGraphRecallService(store: store).recall(query: query, filter: filter)
            }
            return (Array(hits.prefix(graphCandidateLimit)), true, .used)
        } catch is CancellationError {
            return ([], true, .timeout)
        } catch let error as KnowledgeQAError {
            if case .timeout = error {
                Log.search.info("knowledge graph recall timed out request_id=\(requestID.uuidString)")
                return ([], true, .timeout)
            }
            Log.search.warning("knowledge graph recall unavailable request_id=\(requestID.uuidString): \(error.localizedDescription)")
            return ([], true, .failed)
        } catch {
            Log.search.warning("knowledge graph recall unavailable request_id=\(requestID.uuidString): \(error.localizedDescription)")
            return ([], true, .failed)
        }
    }

    private func rerank(
        query: String,
        candidates: [SessionSearchHit],
        service: SearchService,
        policy: KnowledgeQAExecutionPolicy,
        requestID: UUID,
        limit: Int,
        coverSources: Bool
    ) async throws -> ([SessionSearchHit], KnowledgeRerankerStatus) {
        do {
            let scores = try await KnowledgeQATimeout.run(policy.rerank) {
                if let reranker = self.dependencies.reranker {
                    return try await reranker(query, candidates.map(\.text))
                }
                return try await RerankerService.shared.scores(
                    query: query,
                    chunks: candidates.map(\.text)
                )
            }
            guard scores.count == candidates.count else {
                throw KnowledgeQAError.invalidRerankerOutput
            }
            let reranked = zip(candidates, scores).map { KnowledgeRerankedHit(hit: $0.0, score: $0.1) }
            let admitted = KnowledgeRerankPolicy.thresholded(reranked)
            guard !admitted.isEmpty else {
                return ([], .used)
            }
            let vectors = await vectors(for: admitted.map(\.hit.unitID), service: service)
            return (KnowledgeMMR.select(admitted, vectors: vectors, limit: limit, coverSources: coverSources).map(\.hit), .used)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as KnowledgeQAError {
            if case .timeout = error {
                Log.search.warning("knowledge rerank timed out request_id=\(requestID.uuidString)")
                let vectors = await vectors(for: candidates.map(\.unitID), service: service)
                return (KnowledgeMMR.select(candidates.map { .init(hit: $0, score: $0.score) }, vectors: vectors,
                                            limit: limit, coverSources: coverSources).map(\.hit), .timeout)
            }
            Log.search.warning("knowledge rerank unavailable request_id=\(requestID.uuidString): \(error.localizedDescription)")
        } catch {
            Log.search.warning("knowledge rerank unavailable request_id=\(requestID.uuidString): \(error.localizedDescription)")
        }
        let fallback = candidates.map { KnowledgeRerankedHit(hit: $0, score: $0.score) }
        let vectors = await vectors(for: candidates.map(\.unitID), service: service)
        try Task.checkCancellation()
        return (KnowledgeMMR.select(fallback, vectors: vectors, limit: limit, coverSources: coverSources).map(\.hit), .failed)
    }

    private func vectors(for ids: [Int], service: SearchService) async -> [Int: [Float]] {
        if let read = dependencies.textEmbeddings { return (try? await read(ids)) ?? [:] }
        return (try? await service.store.textEmbeddings(unitIDs: ids)) ?? [:]
    }

    private func catalogHits(filter: SessionSearchFilter) async throws -> [SessionSearchHit] {
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let catalogFilter = SessionSearchFilter(
            sessionID: filter.sessionID,
            sessionIDs: filter.sessionIDs,
            sourceOrigins: filter.sourceOrigins,
            cloudOwnerUserID: filter.cloudOwnerUserID,
            limit: 50
        )
        let entries = try await service.sessionCatalog(filter: catalogFilter)
        return entries.enumerated().map { index, entry in
            SessionSearchHit(
                sessionID: entry.sessionID,
                title: entry.title,
                unitID: -((index + 1) * 1_000_000 + abs(entry.sessionID.hashValue % 999_999)),
                kind: .sessionCard,
                start: nil,
                end: entry.duration > 0 ? entry.duration : nil,
                speakerLabels: [],
                text: entry.title,
                score: 1 / Double(index + 1),
                matchSource: "catalog",
                snippet: nil,
                cueIDs: [],
                hasVideo: entry.hasVideo,
                language: entry.language,
                quoteSpan: nil,
                duration: entry.duration,
                sourceOrigin: entry.sourceOrigin,
                sessionType: entry.sessionType,
                sourceCreatedAt: entry.sourceCreatedAt,
                sourceModifiedAt: entry.sourceModifiedAt
            )
        }
    }

    /// Reciprocal-rank fusion preserves graph candidates before the shared cap.
    /// Relevance admission and source coverage happen afterwards.
    static func fuse(hybrid: [SessionSearchHit], graph: [SessionSearchHit], limit: Int) -> [SessionSearchHit] {
        var scores: [String: Double] = [:]
        var hits: [String: SessionSearchHit] = [:]
        var order: [String: Int] = [:]
        for channel in [hybrid, graph] {
            var seen = Set<String>()
            for (rank, hit) in channel.enumerated() {
                let key = hit.sessionID.uuidString + ":" + String(hit.unitID)
                guard seen.insert(key).inserted else { continue }
                scores[key, default: 0] += 1 / Double(60 + rank + 1)
                if hits[key] == nil { order[key] = order.count; hits[key] = hit }
            }
        }
        let maximumScore = scores.values.max() ?? 1
        return scores.keys.sorted {
            scores[$0] == scores[$1] ? order[$0]! < order[$1]! : scores[$0]! > scores[$1]!
        }.prefix(max(0, limit)).compactMap { key in
            guard var hit = hits[key] else { return nil }
            // Fallback MMR must compare fused ranks on one scale, rather than
            // incomparable graph and lexical/vector scores that undo fusion.
            hit.score = scores[key]! / maximumScore
            return hit
        }
    }

    private static func scoped(
        _ candidates: [SessionSearchHit],
        to scope: KnowledgeQAScope
    ) -> [SessionSearchHit] {
        switch scope {
        case .all:
            return candidates
        case let .session(sessionID):
            return candidates.filter { $0.sessionID == sessionID }
        case let .sessions(ids):
            let allowed = Set(ids)
            return candidates.filter { allowed.contains($0.sessionID) }
        }
    }

    private func log(request: KnowledgeRetrievalRequest, diagnostics: KnowledgeRetrievalDiagnostics) {
        Log.search.info(
            "knowledge retrieval path=\(request.retrievalPath.rawValue) request_id=\(request.requestID.uuidString) hybrid_hit_count=\(diagnostics.hybridHitCount) graph_attempted=\(diagnostics.graphAttempted) graph_status=\(diagnostics.graphStatus.rawValue) graph_hit_count=\(diagnostics.graphHitCount) candidate_count=\(diagnostics.candidateCount) reranker_status=\(diagnostics.rerankerStatus.rawValue)"
        )
    }
}
