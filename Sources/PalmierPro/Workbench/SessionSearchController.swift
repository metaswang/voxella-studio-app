import Foundation
import Observation

@MainActor
@Observable
final class SessionSearchController {
    struct Result: Identifiable, Sendable {
        enum Origin: Sendable { case local, cloud, both }

        let id: UUID
        let localSessionID: UUID?
        let remoteSessionID: UUID
        let title: String
        let summary: String?
        let snippet: String?
        let matchSource: String
        let updatedAt: Date?
        let origin: Origin
        let isTranscript: Bool

        var isDisplayable: Bool {
            let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasSnippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if matchSource == "summary" {
                return hasSummary || hasSnippet
            }
            if isTranscript {
                return hasSnippet
            }
            return hasTitle || hasSummary || hasSnippet
        }

        static func deduplicated(_ results: [Result]) -> [Result] {
            var seen = Set<UUID>()
            return results.filter { seen.insert($0.remoteSessionID).inserted }
        }
    }

    private struct Level0Stage: Sendable {
        enum Kind: Sendable {
            case localLexical
            case localHybrid
            case cloud
        }

        let kind: Kind
        let results: [Result]
        let errorMessage: String?
    }

    var query = ""
    var l0Results: [Result] = []
    var l1Results: [Result] = []
    var isLoadingL0 = false
    var isLoadingL1 = false
    var isLoadingSemantic = false
    var errorMessage: String?

    private let store: WorkbenchStore
    private let api: VoxellaAPIClient
    private var generation = UUID()
    private var cloudTranscriptSearchUnavailable = false

    init(store: WorkbenchStore = .shared, api: VoxellaAPIClient = .shared) {
        self.store = store
        self.api = api
    }

    func reset() {
        generation = UUID()
        query = ""
        l0Results = []
        l1Results = []
        isLoadingL0 = false
        isLoadingL1 = false
        isLoadingSemantic = false
        errorMessage = nil
    }

    func search() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGeneration = UUID()
        generation = currentGeneration
        l0Results = []
        l1Results = []
        isLoadingSemantic = false
        errorMessage = nil
        guard !normalized.isEmpty else { return }

        isLoadingL0 = true
        defer {
            if generation == currentGeneration {
                isLoadingL0 = false
                isLoadingSemantic = false
            }
        }
        do {
            try await Task.sleep(for: .milliseconds(220))
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            isLoadingSemantic = true
            var lexicalResults: [Result] = []
            var hybridResults: [Result]?
            var cloudResults: [Result] = []

            await withTaskGroup(of: Level0Stage.self) { group in
                group.addTask { [self] in
                    do {
                        return Level0Stage(
                            kind: .localLexical,
                            results: try await self.localLexical(query: normalized, transcriptOnly: false),
                            errorMessage: nil
                        )
                    } catch is CancellationError {
                        return Level0Stage(kind: .localLexical, results: [], errorMessage: nil)
                    } catch {
                        return Level0Stage(
                            kind: .localLexical,
                            results: [],
                            errorMessage: error.localizedDescription
                        )
                    }
                }
                group.addTask { [self] in
                    do {
                        return Level0Stage(
                            kind: .localHybrid,
                            results: try await self.localHybrid(query: normalized, transcriptOnly: false),
                            errorMessage: nil
                        )
                    } catch is CancellationError {
                        return Level0Stage(kind: .localHybrid, results: [], errorMessage: nil)
                    } catch {
                        return Level0Stage(
                            kind: .localHybrid,
                            results: [],
                            errorMessage: error.localizedDescription
                        )
                    }
                }
                group.addTask { [self] in
                    do {
                        return Level0Stage(
                            kind: .cloud,
                            results: try await self.cloudL0(query: normalized),
                            errorMessage: nil
                        )
                    } catch is CancellationError {
                        return Level0Stage(kind: .cloud, results: [], errorMessage: nil)
                    } catch {
                        return Level0Stage(
                            kind: .cloud,
                            results: [],
                            errorMessage: error.localizedDescription
                        )
                    }
                }

                for await stage in group {
                    guard generation == currentGeneration, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let message = stage.errorMessage, errorMessage == nil {
                        errorMessage = message
                    }
                    switch stage.kind {
                    case .localLexical:
                        lexicalResults = stage.results
                    case .localHybrid:
                        if stage.errorMessage == nil, !stage.results.isEmpty {
                            hybridResults = stage.results
                        }
                    case .cloud:
                        cloudResults = stage.results
                    }
                    l0Results = fuse(
                        local: hybridResults ?? lexicalResults,
                        cloud: cloudResults
                    )
                    let l0Keys = Set(l0Results.map(\.remoteSessionID))
                    l1Results.removeAll { l0Keys.contains($0.remoteSessionID) }
                }
            }
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func searchTranscriptAfterPause() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGeneration = generation
        guard normalized.count >= 3 else { return }
        do {
            try await Task.sleep(for: .milliseconds(700))
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            isLoadingL1 = true
            defer { if generation == currentGeneration { isLoadingL1 = false } }
            async let local = localHybrid(query: normalized, transcriptOnly: true)
            async let cloud = cloudL1(query: normalized)
            let (localResults, cloudResults) = try await (local, cloud)
            guard generation == currentGeneration, !Task.isCancelled else { return }
            let l0Keys = Set(l0Results.map(\.remoteSessionID))
            l1Results = fuse(local: localResults, cloud: cloudResults)
                .filter { !l0Keys.contains($0.remoteSessionID) }
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func open(_ result: Result) {
        store.openSearchResult(localSessionID: result.localSessionID, remoteSessionID: result.remoteSessionID)
    }

    private func localLexical(query: String, transcriptOnly: Bool) async throws -> [Result] {
        let localSessions = indexedSessions()
        let service = SessionIndexCoordinator.shared.searchService
        let filter = SessionSearchFilter(limit: 30)
        if transcriptOnly {
            async let transcripts = service.transcriptLexicalSearch(query: query, filter: filter)
            async let clips = service.clipLexicalSearch(query: query, filter: filter)
            let (transcriptHits, clipHits) = try await (transcripts, clips)
            return rankedLocal(
                rankings: [transcriptHits.map(\.sessionID), clipHits.map(\.sessionID)],
                hits: transcriptHits + clipHits,
                sessions: localSessions,
                transcriptOnly: true
            )
        }
        async let cards = service.sessionLexicalSearch(query: query, filter: filter)
        async let transcripts = service.transcriptLexicalSearch(query: query, filter: filter)
        async let clips = service.clipLexicalSearch(query: query, filter: filter)
        let (sessionCards, transcriptHits, clipHits) = try await (cards, transcripts, clips)
        return makeLocalResults(
            sessionCards: sessionCards,
            transcriptHits: transcriptHits,
            clipHits: clipHits,
            sessions: localSessions,
            transcriptOnly: false
        )
    }

    private func localHybrid(query: String, transcriptOnly: Bool) async throws -> [Result] {
        let localSessions = indexedSessions()
        let service = SessionIndexCoordinator.shared.searchService
        let filter = SessionSearchFilter(limit: 30)
        if transcriptOnly {
            async let transcripts = service.transcriptSearch(query: query, filter: filter)
            async let clips = service.clipSearch(query: query, filter: filter)
            let (transcriptHits, clipHits) = try await (transcripts, clips)
            return rankedLocal(
                rankings: [transcriptHits.map(\.sessionID), clipHits.map(\.sessionID)],
                hits: transcriptHits + clipHits,
                sessions: localSessions,
                transcriptOnly: true
            )
        }
        async let cards = service.sessionSearch(query: query, filter: filter)
        async let transcripts = service.transcriptSearch(query: query, filter: filter)
        async let clips = service.clipSearch(query: query, filter: filter)
        let (sessionCards, transcriptHits, clipHits) = try await (cards, transcripts, clips)
        return makeLocalResults(
            sessionCards: sessionCards,
            transcriptHits: transcriptHits,
            clipHits: clipHits,
            sessions: localSessions,
            transcriptOnly: false
        )
    }

    private func indexedSessions() -> [UUID: WorkbenchSession] {
        let localPairs: [(UUID, WorkbenchSession)] = store.sessions.compactMap { session in
            guard session.transcriptionID != nil || session.dubID != nil else { return nil }
            return (session.id, session)
        }
        return Dictionary(uniqueKeysWithValues: localPairs)
    }

    private func makeLocalResults(
        sessionCards: [SessionCard],
        transcriptHits: [SessionSearchHit],
        clipHits: [SessionSearchHit],
        sessions: [UUID: WorkbenchSession],
        transcriptOnly: Bool
    ) -> [Result] {
        let cardResults = sessionCards.compactMap { card -> Result? in
            guard let session = sessions[card.sessionID] else { return nil }
            return makeResult(
                id: session.id,
                localSessionID: session.id,
                remoteSessionID: session.remoteSessionID ?? session.id,
                title: session.title,
                fallbackTitle: nil,
                summary: session.summaryMarkdown,
                snippet: card.snippet,
                matchSource: card.matchSource,
                updatedAt: session.modifiedAt,
                origin: .local,
                isTranscript: false,
                defaultMatchSource: "summary"
            )
        }
        let content = rankedLocal(
            rankings: [transcriptHits.map(\.sessionID), clipHits.map(\.sessionID)],
            hits: transcriptHits + clipHits, sessions: sessions, transcriptOnly: transcriptOnly
        )
        if transcriptOnly { return content }
        return fuse(local: cardResults, cloud: content)
    }

    private func rankedLocal(
        rankings: [[UUID]], hits: [SessionSearchHit], sessions: [UUID: WorkbenchSession], transcriptOnly: Bool
    ) -> [Result] {
        let order = ReciprocalRankFusion.fuse(rankings: rankings, k: 20)
        let bySession = Dictionary(grouping: hits, by: \.sessionID)
        return order.compactMap { id in
            guard let session = sessions[id], let hit = bySession[id]?.first else { return nil }
            return makeResult(
                id: session.id,
                localSessionID: session.id,
                remoteSessionID: session.remoteSessionID ?? session.id,
                title: session.title,
                fallbackTitle: nil,
                summary: session.summaryMarkdown,
                snippet: hit.snippet ?? hit.text,
                matchSource: hit.matchSource,
                updatedAt: session.modifiedAt,
                origin: .local,
                isTranscript: transcriptOnly || hit.kind != .sessionCard,
                defaultMatchSource: "transcript"
            )
        }
    }

    private func cloudL0(query: String) async throws -> [Result] {
        guard AccountService.shared.isSignedIn else { return [] }
        let response = try await api.searchSessions(query: query, typingPauseMS: 0)
        return response.items.compactMap {
            makeResult(
                id: $0.sessionID,
                localSessionID: nil,
                remoteSessionID: $0.sessionID,
                title: $0.title,
                fallbackTitle: $0.originalFilename,
                summary: $0.summary,
                snippet: $0.matchSnippet,
                matchSource: $0.matchSource,
                updatedAt: Self.parseDate($0.updatedAt ?? $0.createdAt),
                origin: .cloud,
                isTranscript: false,
                defaultMatchSource: "summary"
            )
        }
    }

    private func cloudL1(query: String) async throws -> [Result] {
        guard AccountService.shared.isSignedIn else {
            cloudTranscriptSearchUnavailable = false
            return []
        }
        guard !cloudTranscriptSearchUnavailable else { return [] }
        do {
            let response = try await api.searchSessionTranscripts(query: query)
            return response.items.compactMap {
                makeResult(
                    id: $0.sessionID,
                    localSessionID: nil,
                    remoteSessionID: $0.sessionID,
                    title: $0.title,
                    fallbackTitle: $0.originalFilename,
                    summary: $0.summary,
                    snippet: $0.matchSnippet,
                    matchSource: $0.matchSource,
                    updatedAt: Self.parseDate($0.updatedAt ?? $0.createdAt),
                    origin: .cloud,
                    isTranscript: true,
                    defaultMatchSource: "transcript"
                )
            }
        } catch VoxellaAPIError.http(404, _) {
            cloudTranscriptSearchUnavailable = true
            Log.search.warning("cloud transcript search endpoint is unavailable; using local transcript search")
            return []
        }
    }

    private func fuse(local: [Result], cloud: [Result]) -> [Result] {
        let validLocal = Result.deduplicated(local.filter(\.isDisplayable))
        let validCloud = Result.deduplicated(cloud.filter(\.isDisplayable))
        let localByKey = Dictionary(uniqueKeysWithValues: validLocal.map { ($0.remoteSessionID, $0) })
        let cloudByKey = Dictionary(uniqueKeysWithValues: validCloud.map { ($0.remoteSessionID, $0) })
        let localRanks = Dictionary(uniqueKeysWithValues: validLocal.enumerated().map { ($0.element.remoteSessionID, $0.offset) })
        let cloudRanks = Dictionary(uniqueKeysWithValues: validCloud.enumerated().map { ($0.element.remoteSessionID, $0.offset) })
        return Set(localByKey.keys).union(cloudByKey.keys).compactMap { key in
            switch (localByKey[key], cloudByKey[key]) {
            case let (.some(local), .some(cloud)):
                return makeResult(
                    id: local.id,
                    localSessionID: local.localSessionID,
                    remoteSessionID: key,
                    title: cloud.title,
                    fallbackTitle: local.title,
                    summary: cloud.summary ?? local.summary,
                    snippet: local.snippet ?? cloud.snippet,
                    matchSource: local.matchSource,
                    updatedAt: max(local.updatedAt ?? .distantPast, cloud.updatedAt ?? .distantPast),
                    origin: .both,
                    isTranscript: local.isTranscript || cloud.isTranscript,
                    defaultMatchSource: "summary"
                )
            case let (.some(local), .none): return local
            case let (.none, .some(cloud)): return cloud
            case (.none, .none): return nil
            }
        }.sorted { lhs, rhs in
            let leftRank = min(localRanks[lhs.remoteSessionID] ?? .max, cloudRanks[lhs.remoteSessionID] ?? .max)
            let rightRank = min(localRanks[rhs.remoteSessionID] ?? .max, cloudRanks[rhs.remoteSessionID] ?? .max)
            let leftFresh = freshness(lhs.updatedAt)
            let rightFresh = freshness(rhs.updatedAt)
            let leftScore = 1 / Double(20 + leftRank + 1) + leftFresh
            let rightScore = 1 / Double(20 + rightRank + 1) + rightFresh
            return leftScore == rightScore ? lhs.remoteSessionID.uuidString < rhs.remoteSessionID.uuidString : leftScore > rightScore
        }
    }

    private func makeResult(
        id: UUID,
        localSessionID: UUID?,
        remoteSessionID: UUID,
        title: String?,
        fallbackTitle: String?,
        summary: String?,
        snippet: String?,
        matchSource: String?,
        updatedAt: Date?,
        origin: Result.Origin,
        isTranscript: Bool,
        defaultMatchSource: String
    ) -> Result? {
        let normalizedTitle = Self.nonEmpty(title)
        let normalizedFallbackTitle = Self.nonEmpty(fallbackTitle)
        let normalizedSummary = Self.nonEmpty(summary)
        let normalizedSnippet = Self.nonEmpty(snippet)
        guard let displayTitle = normalizedTitle ?? normalizedFallbackTitle ?? normalizedSummary ?? normalizedSnippet else {
            return nil
        }
        return Result(
            id: id,
            localSessionID: localSessionID,
            remoteSessionID: remoteSessionID,
            title: displayTitle,
            summary: normalizedSummary,
            snippet: normalizedSnippet,
            matchSource: Self.nonEmpty(matchSource) ?? defaultMatchSource,
            updatedAt: updatedAt,
            origin: origin,
            isTranscript: isTranscript
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func freshness(_ date: Date?) -> Double {
        guard let date else { return 0 }
        return 0.004 * exp(-max(0, Date().timeIntervalSince(date)) / (30 * 86_400))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? { formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value) }()
    }
}
