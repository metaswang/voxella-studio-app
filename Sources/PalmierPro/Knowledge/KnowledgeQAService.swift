import Foundation

enum KnowledgeAnswerLanguage: Equatable, Sendable {
    case chinese
    case japanese
    case korean
    case cyrillic
    case english

    static func detect(from text: String) -> Self {
        var han = 0
        var kana = 0
        var hangul = 0
        var cyrillic = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF:
                kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                han += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                hangul += 1
            case 0x0400...0x052F:
                cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                continue
            }
        }

        if hangul > 0 { return .korean }
        if kana > 0 { return .japanese }
        if han > 0 { return .chinese }
        if cyrillic > latin { return .cyrillic }
        return .english
    }

    var instruction: String {
        switch self {
        case .chinese: "Chinese (中文)"
        case .japanese: "Japanese (日本語)"
        case .korean: "Korean (한국어)"
        case .cyrillic: "the same Cyrillic language as the question"
        case .english: "English"
        }
    }
}

struct KnowledgeQueryPlan: Equatable, Sendable {
    let standaloneQuery: String
    let searchQuery: String
    let answerConstraints: [String]
    let clarificationQuestion: String?

    static func fallback(for query: String) -> Self {
        Self(
            standaloneQuery: query,
            searchQuery: query,
            answerConstraints: [],
            clarificationQuestion: nil
        )
    }

    var needsClarification: Bool {
        let question = clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !question.isEmpty
    }
}

enum KnowledgeQueryUnderstandingStatus: String, Sendable {
    case planned
    case fallback
    case timedOut
    case failed
}

/// Time budgets owned by the Knowledge QA pipeline. These deliberately do not
/// change the shared `.chat` route policy used by other app features.
struct KnowledgeQAExecutionPolicy: Equatable, Sendable {
    var overall: Duration = .seconds(56)
    var understanding: Duration = .seconds(8)
    var retrieval: Duration = .seconds(8)
    var graphRecall: Duration = .seconds(5)
    var rerank: Duration = .seconds(5)
    var answer: Duration = .seconds(30)

    static let `default` = Self()
}

/// Injectable seams keep timeout and cancellation tests deterministic while
/// leaving the production retrieval and model clients unchanged.
struct KnowledgeQAMonotonicClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    static let continuous = Self()
}

struct KnowledgeQAExecutionDependencies: Sendable {
    typealias Planner = @Sendable (
        _ query: String,
        _ history: [KnowledgeMessage],
        _ targetTranscriptLanguage: String?,
        _ allowCloud: Bool
    ) async throws -> KnowledgeQueryPlan
    typealias Recall = @Sendable (
        _ query: String,
        _ filter: SessionSearchFilter
    ) async throws -> [SessionSearchHit]
    typealias Reranker = @Sendable (
        _ query: String,
        _ chunks: [String]
    ) async throws -> [Double]
    typealias Answer = @Sendable (
        _ system: String,
        _ user: String,
        _ allowCloud: Bool
    ) async throws -> String

    var planner: Planner?
    var hybridRecall: Recall?
    var graphRecall: Recall?
    var reranker: Reranker?
    var answer: Answer?
    var clock: KnowledgeQAMonotonicClock

    init(
        planner: Planner? = nil,
        hybridRecall: Recall? = nil,
        graphRecall: Recall? = nil,
        reranker: Reranker? = nil,
        answer: Answer? = nil,
        clock: KnowledgeQAMonotonicClock = .continuous
    ) {
        self.planner = planner
        self.hybridRecall = hybridRecall
        self.graphRecall = graphRecall
        self.reranker = reranker
        self.answer = answer
        self.clock = clock
    }

    static let live = Self()
}

enum KnowledgeQAOutcome: String, Sendable {
    case completed
    case fallback
    case noEvidence
    case timedOut
    case failed
    case cancelled
    case clarification
}

private struct KnowledgeQADeadline: Sendable {
    let end: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant

    init(duration: Duration, clock: KnowledgeQAMonotonicClock = .continuous) {
        now = clock.now
        end = now().advanced(by: duration)
    }

    var remaining: Duration {
        now().duration(to: end)
    }

    func budget(_ requested: Duration) throws -> Duration {
        let value = min(requested, remaining)
        guard value > .zero else { throw KnowledgeQAError.timeout }
        return value
    }
}

/// A timeout must release the caller even when an underlying dependency does
/// not respond to cancellation promptly. The losing task is cancelled and its
/// late result is discarded by this coordinator.
private struct KnowledgeQATimeoutFailure: Error, @unchecked Sendable {
    let error: Error
}

private enum KnowledgeQATimeoutResult<T>: @unchecked Sendable {
    case success(T)
    case failure(KnowledgeQATimeoutFailure)
}

private final class KnowledgeQATimeoutCoordinator<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: KnowledgeQATimeoutResult<T>?
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelOperation: (() -> Void)?
    private var cancelTimer: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        var pending: KnowledgeQATimeoutResult<T>?
        lock.lock()
        if let result {
            pending = result
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if let pending {
            switch pending {
            case let .success(value): continuation.resume(returning: value)
            case let .failure(failure): continuation.resume(throwing: failure)
            }
        }
    }

    func setCancelOperation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        if result != nil {
            lock.unlock()
            cancel()
        } else {
            cancelOperation = cancel
            lock.unlock()
        }
    }

    func setCancelTimer(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        if result != nil {
            lock.unlock()
            cancel()
        } else {
            cancelTimer = cancel
            lock.unlock()
        }
    }

    func resolve(_ result: KnowledgeQATimeoutResult<T>) {
        var continuation: CheckedContinuation<T, Error>?
        var cancelOperation: (() -> Void)?
        var cancelTimer: (() -> Void)?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        cancelOperation = self.cancelOperation
        cancelTimer = self.cancelTimer
        self.cancelOperation = nil
        self.cancelTimer = nil
        lock.unlock()
        cancelOperation?()
        cancelTimer?()
        if let continuation {
            switch result {
            case let .success(value): continuation.resume(returning: value)
            case let .failure(failure): continuation.resume(throwing: failure)
            }
        }
    }
}

/// Non-structured timeout race used by QA stages. Unlike a task group, this
/// returns as soon as the winner resolves and only signals cancellation to the
/// losing task.
enum KnowledgeQATimeout {
    static func run<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard duration > .zero else { throw KnowledgeQAError.timeout }
        let coordinator = KnowledgeQATimeoutCoordinator<T>()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    coordinator.attach(continuation)
                    let operationTask = Task {
                        do {
                            coordinator.resolve(.success(try await operation()))
                        } catch {
                            coordinator.resolve(.failure(KnowledgeQATimeoutFailure(error: error)))
                        }
                    }
                    coordinator.setCancelOperation { operationTask.cancel() }
                    let timerTask = Task {
                        do {
                            try await Task.sleep(for: duration)
                            coordinator.resolve(.failure(KnowledgeQATimeoutFailure(error: KnowledgeQAError.timeout)))
                        } catch is CancellationError {
                            // The operation won the race.
                        } catch {
                            coordinator.resolve(.failure(KnowledgeQATimeoutFailure(error: error)))
                        }
                    }
                    coordinator.setCancelTimer { timerTask.cancel() }
                }
            } onCancel: {
                coordinator.resolve(.failure(KnowledgeQATimeoutFailure(error: CancellationError())))
            }
        } catch let failure as KnowledgeQATimeoutFailure {
            throw failure.error
        }
    }
}

struct KnowledgeQAService: Sendable {
    var topK: Int = 30
    var candidateLimit: Int = 40
    var maxContextChars: Int = 10_000
    var executionPolicy: KnowledgeQAExecutionPolicy = .default
    var dependencies: KnowledgeQAExecutionDependencies = .live
    var chatStore: KnowledgeChatStore = .shared
    var useAgentRuntime: Bool = true
    var skillsProvider: (@Sendable () async -> [Skill])?

    var isPipelineInjected: Bool {
        dependencies.planner != nil
            || dependencies.hybridRecall != nil
            || dependencies.graphRecall != nil
            || dependencies.reranker != nil
            || dependencies.answer != nil
    }

    func makeRetrievalService() -> KnowledgeRetrievalService {
        KnowledgeRetrievalService(
            topK: topK,
            candidateLimit: candidateLimit,
            executionPolicy: executionPolicy,
            dependencies: dependencies
        )
    }

    func answer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
        streamAnswer(request, queryPlan: nil, preferAgent: useAgentRuntime)
    }

    func legacyAnswer(
        _ request: KnowledgeQARequest,
        queryPlan: KnowledgeQueryPlan? = nil
    ) -> AsyncStream<KnowledgeAnswerEvent> {
        streamAnswer(request, queryPlan: queryPlan, preferAgent: false)
    }

    func runPrepared(
        _ request: KnowledgeQARequest,
        queryPlan: KnowledgeQueryPlan,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        try await run(
            request,
            queryPlan: queryPlan,
            continuation: continuation,
            deadline: KnowledgeQADeadline(duration: executionPolicy.overall, clock: dependencies.clock)
        )
    }

    private func streamAnswer(
        _ request: KnowledgeQARequest,
        queryPlan: KnowledgeQueryPlan?,
        preferAgent: Bool
    ) -> AsyncStream<KnowledgeAnswerEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await self.dispatch(
                        request,
                        queryPlan: queryPlan,
                        preferAgent: preferAgent,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    Self.logOutcome(.cancelled, request: request)
                    continuation.finish()
                } catch {
                    Self.logOutcome(.failed, request: request, detail: error.localizedDescription)
                    continuation.yield(.failed(KnowledgeUserFacingCopy.message(for: error)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func dispatch(
        _ request: KnowledgeQARequest,
        queryPlan suppliedPlan: KnowledgeQueryPlan?,
        preferAgent: Bool,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let query = request.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Self.logOutcome(.failed, request: request, detail: "empty_query")
            continuation.yield(.failed("Enter a question to ask your knowledge base."))
            continuation.finish()
            return
        }

        let deadline = KnowledgeQADeadline(
            duration: executionPolicy.overall,
            clock: dependencies.clock
        )
        let queryPlan: KnowledgeQueryPlan
        if let suppliedPlan {
            queryPlan = suppliedPlan
        } else {
            queryPlan = try await understandQuery(
                request,
                query: query,
                deadline: deadline,
                continuation: continuation
            )
        }
        try Task.checkCancellation()

        if queryPlan.needsClarification, let question = queryPlan.clarificationQuestion {
            continuation.yield(.clarification(question))
            Self.logOutcome(.clarification, request: request)
            continuation.finish()
            return
        }

        if preferAgent {
            var fallback = self
            fallback.useAgentRuntime = false
            let runtime = KnowledgeAgentRuntime(
                scope: request.scope,
                originFilter: request.originFilter,
                allowCloud: request.allowCloud,
                queryPlan: queryPlan,
                retrievalService: makeRetrievalService(),
                fallbackService: fallback,
                skillsProvider: skillsProvider ?? {
                    await MainActor.run { SkillStore.shared.knowledgeSkills() }
                }
            )
            try await runtime.run(request, continuation: continuation)
            return
        }

        try await run(
            request,
            queryPlan: queryPlan,
            continuation: continuation,
            deadline: deadline
        )
    }

    private func run(
        _ request: KnowledgeQARequest,
        queryPlan: KnowledgeQueryPlan,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation,
        deadline: KnowledgeQADeadline
    ) async throws {
        let query = request.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Self.logOutcome(.failed, request: request, detail: "empty_query")
            continuation.yield(.failed("Enter a question to ask your knowledge base."))
            continuation.finish()
            return
        }

        if !isPipelineInjected {
            guard await MainActor.run(body: { KnowledgeAnswerAvailability.current() == .ready }) else {
                throw KnowledgeQAError.llmUnavailable
            }
        }

        continuation.yield(.status("Searching knowledge…"))
        Self.logStage(
            "searching",
            request: request,
            budget: executionPolicy.retrieval,
            remaining: deadline.remaining
        )
        let hits: [SessionSearchHit]
        var retrievalTimedOut = false
        var retrievalFailed = false
        do {
            var searchPolicy = executionPolicy
            searchPolicy.retrieval = try deadline.budget(executionPolicy.retrieval)
            searchPolicy.graphRecall = min(executionPolicy.graphRecall, searchPolicy.retrieval)
            searchPolicy.rerank = try deadline.budget(executionPolicy.rerank)
            let result = try await makeRetrievalService().search(
                KnowledgeRetrievalRequest(
                    query: queryPlan.searchQuery,
                    originalQuery: query,
                    scope: request.scope,
                    originFilter: request.originFilter,
                    resultLimit: 8,
                    requestID: request.requestID,
                    includeCatalog: true,
                    retrievalPath: .legacy
                ),
                policy: searchPolicy
            )
            hits = result.hits
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as KnowledgeQAError {
            guard case .timeout = error else { throw error }
            retrievalTimedOut = true
            hits = []
            Log.search.warning("knowledge qa stage=retrieval-timeout request_id=\(request.requestID.uuidString) budget_ms=\(Self.milliseconds(executionPolicy.retrieval))")
        } catch {
            retrievalFailed = true
            Log.search.warning("knowledge qa stage=retrieval-failed request_id=\(request.requestID.uuidString) reason=\(error.localizedDescription)")
            hits = []
        }
        try Task.checkCancellation()
        if !retrievalTimedOut, !retrievalFailed {
            Log.search.info("knowledge qa stage=search-complete scope=\(Self.scopeName(request.scope)) hits=\(hits.count) request_id=\(request.requestID.uuidString)")
        }

        let answerLanguage = KnowledgeAnswerLanguage.detect(from: query)
        let citations = hits.map { Self.citation(from: $0) }
        if hits.isEmpty {
            let message: String
            if retrievalTimedOut {
                message = Self.retrievalTimeoutMessage(scope: request.scope, language: answerLanguage)
            } else if retrievalFailed {
                message = Self.retrievalFailureMessage(scope: request.scope, language: answerLanguage)
            } else {
                message = Self.insufficientEvidenceMessage(scope: request.scope, language: answerLanguage)
            }
            continuation.yield(.citations([]))
            continuation.yield(.status(
                retrievalTimedOut ? "Search timed out" : (retrievalFailed ? "Search failed" : "No evidence found")
            ))
            for chunk in Self.chunkForStreaming(message) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(message))
            Self.logOutcome(
                retrievalTimedOut ? .timedOut : (retrievalFailed ? .failed : .noEvidence),
                request: request
            )
            continuation.finish()
            return
        }

        continuation.yield(.citations(citations))
        continuation.yield(.status("Composing answer…"))
        Log.search.info("knowledge qa stage=composing scope=\(Self.scopeName(request.scope)) citations=\(citations.count) request_id=\(request.requestID.uuidString)")

        let context: String
        do {
            let budget = try deadline.budget(.seconds(2))
            context = try await KnowledgeQATimeout.run(budget) {
                await self.buildContext(hits: hits)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.search.warning("knowledge qa stage=context-timeout request_id=\(request.requestID.uuidString)")
            context = Self.buildContext(hits: hits, maxChars: maxContextChars)
        }
        let system = Self.systemPrompt(
            mode: request.answerMode,
            scope: request.scope,
            originFilter: request.originFilter,
            answerLanguage: answerLanguage
        )
        let user = Self.userPrompt(
            query: query,
            standaloneQuery: queryPlan.standaloneQuery,
            searchQuery: queryPlan.searchQuery,
            answerConstraints: queryPlan.answerConstraints,
            context: context,
            history: request.history
        )

        let hostedCreditsExhausted: Bool
        if isPipelineInjected {
            hostedCreditsExhausted = false
        } else {
            hostedCreditsExhausted = await MainActor.run {
                AITransportPolicy.current == .hosted && HostedCreditAvailability.shared.isExhausted
            }
        }
        if hostedCreditsExhausted {
            continuation.yield(.recoveryActions([.account, .aiSettings]))
            let fallback = Self.excerptFallback(
                query: query,
                hits: hits,
                language: answerLanguage
            )
            continuation.yield(.status("Showing excerpts…"))
            for chunk in Self.chunkForStreaming(fallback) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(fallback))
            Self.logOutcome(.fallback, request: request, detail: "hosted_credits_exhausted")
            continuation.finish()
            return
        }

        let answerText: String
        do {
            let budget = try deadline.budget(executionPolicy.answer)
            answerText = try await KnowledgeQATimeout.run(budget) {
                try await generateAnswer(
                    system: system,
                    user: user,
                    allowCloud: request.allowCloud
                )
            }
        } catch let error as LLMClientError {
            Log.search.warning("knowledge qa stage=answer-fallback reason=\(error.localizedDescription)")
            if case .insufficientCredits = error {
                continuation.yield(.recoveryActions([.account, .aiSettings]))
            }
            let fallback = Self.excerptFallback(
                query: query,
                hits: hits,
                language: answerLanguage
            )
            continuation.yield(.status("Showing excerpts…"))
            for chunk in Self.chunkForStreaming(fallback) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(fallback))
            Self.logOutcome(.fallback, request: request, detail: "answer_model")
            continuation.finish()
            return
        } catch {
            Log.search.warning("knowledge qa stage=answer-fallback reason=\(error.localizedDescription)")
            let fallback = Self.excerptFallback(
                query: query,
                hits: hits,
                language: answerLanguage
            )
            continuation.yield(.status("Showing excerpts…"))
            for chunk in Self.chunkForStreaming(fallback) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(fallback))
            Self.logOutcome(.fallback, request: request, detail: "answer_model")
            continuation.finish()
            return
        }

        try Task.checkCancellation()
        continuation.yield(.status("Showing answer…"))
        Log.search.info("knowledge qa stage=showing-answer scope=\(Self.scopeName(request.scope)) chars=\(answerText.count) request_id=\(request.requestID.uuidString)")
        for chunk in Self.chunkForStreaming(answerText) {
            try Task.checkCancellation()
            continuation.yield(.delta(chunk))
        }
        continuation.yield(.finished(answerText))
        Self.logOutcome(.completed, request: request)
        continuation.finish()
    }

    private func buildContext(hits: [SessionSearchHit]) async -> String {
        let store = await MainActor.run { SessionIndexCoordinator.shared.searchService.store }
        var metadata: [UUID: KnowledgeSessionContextMetadata] = [:]
        var neighbors: [Int: [SessionSearchHit]] = [:]
        for hit in hits {
            if metadata[hit.sessionID] == nil,
               let card = try? await store.sessionCard(id: hit.sessionID)
            {
                metadata[hit.sessionID] = KnowledgeSessionContextMetadata(
                    title: card.title,
                    // A catalog hit is intentionally metadata-only. Passing
                    // the persisted summary here would let the answer model
                    // re-introduce unsolicited summaries into an inventory
                    // response.
                    summary: hit.matchSource == "catalog"
                        ? nil
                        : (card.summaryMarkdown ?? card.summaryExcerpt),
                    duration: card.duration,
                    sessionType: card.sessionType,
                    sourceOrigin: card.sourceOrigin,
                    sourceCreatedAt: card.sourceCreatedAt,
                    sourceModifiedAt: card.sourceModifiedAt
                )
            }
            if hit.text.count < KnowledgeContextBuilder.shortAnchorLimit {
                neighbors[hit.unitID] = (try? await store.contextNeighbors(for: hit)) ?? []
            }
        }
        return KnowledgeContextBuilder.build(
            anchors: hits,
            metadata: metadata,
            neighbors: neighbors,
            maxChars: maxContextChars
        )
    }

    private func generateAnswer(system: String, user: String, allowCloud: Bool) async throws -> String {
        if let answer = dependencies.answer {
            return try await answer(system, user, allowCloud)
        }
        let client = try await Self.makeTextClient(allowCloud: allowCloud, useCase: .chat)
        return try await client.complete(system: system, user: user)
    }

    private func understandQuery(
        _ request: KnowledgeQARequest,
        query: String,
        deadline: KnowledgeQADeadline,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws -> KnowledgeQueryPlan {
        continuation.yield(.status("Understanding question…"))
        Self.logStage(
            "understanding",
            request: request,
            budget: executionPolicy.understanding,
            remaining: deadline.remaining
        )
        let status: KnowledgeQueryUnderstandingStatus
        let queryPlan: KnowledgeQueryPlan
        do {
            let budget = try deadline.budget(executionPolicy.understanding)
            queryPlan = try await KnowledgeQATimeout.run(budget) {
                let targetTranscriptLanguage = await self.targetTranscriptLanguage(
                    for: request.scope,
                    originFilter: request.originFilter
                )
                if let targetTranscriptLanguage {
                    Log.search.debug("knowledge query planner target transcript language=\(targetTranscriptLanguage) request_id=\(request.requestID.uuidString)")
                }
                return try await self.planQuery(
                    query,
                    history: request.history,
                    targetTranscriptLanguage: targetTranscriptLanguage,
                    allowCloud: request.allowCloud,
                    request: request
                )
            }
            status = .planned
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as KnowledgeQAError {
            if case .timeout = error {
                status = .timedOut
                Log.search.warning("knowledge qa stage=understanding-timeout request_id=\(request.requestID.uuidString) budget_ms=\(Self.milliseconds(executionPolicy.understanding))")
            } else {
                status = .failed
                Log.search.warning("knowledge qa stage=understanding-failed request_id=\(request.requestID.uuidString) reason=\(error.localizedDescription)")
            }
            queryPlan = .fallback(for: query)
        } catch {
            status = .failed
            Log.search.warning("knowledge qa stage=understanding-failed request_id=\(request.requestID.uuidString) reason=\(error.localizedDescription)")
            queryPlan = .fallback(for: query)
        }
        Log.search.info(
            "knowledge qa stage=query-understanding status=\(status.rawValue) history_count=\(min(request.history.count, 6)) standalone_query_length=\(queryPlan.standaloneQuery.count) search_query_length=\(queryPlan.searchQuery.count) request_id=\(request.requestID.uuidString)"
        )
        return queryPlan
    }

    private func planQuery(
        _ query: String,
        history: [KnowledgeMessage],
        targetTranscriptLanguage: String?,
        allowCloud: Bool,
        request: KnowledgeQARequest
    ) async throws -> KnowledgeQueryPlan {
        do {
            if let planner = dependencies.planner {
                let plan = try await planner(
                    query,
                    history,
                    targetTranscriptLanguage,
                    allowCloud
                )
                Log.search.info("knowledge qa stage=planner-complete standalone_chars=\(plan.standaloneQuery.count) search_chars=\(plan.searchQuery.count) constraints=\(plan.answerConstraints.count) request_id=\(request.requestID.uuidString)")
                return plan
            }
            // Query understanding is a short, bounded planning step. Using the
            // dedicated route prevents a slow answer-chat route from blocking
            // the entire QA pipeline before retrieval can begin.
            let client = try await Self.makeTextClient(
                allowCloud: allowCloud,
                useCase: .graphQueryUnderstanding
            )
            let response = try await client.complete(
                system: Self.queryPlannerPrompt,
                user: Self.queryPlannerInput(
                    query: query,
                    history: history,
                    targetTranscriptLanguage: targetTranscriptLanguage
                )
            )
            let plan = try Self.decodeQueryPlan(response)
            Log.search.info("knowledge qa stage=planner-complete standalone_chars=\(plan.standaloneQuery.count) search_chars=\(plan.searchQuery.count) constraints=\(plan.answerConstraints.count) request_id=\(request.requestID.uuidString)")
            return plan
        } catch is CancellationError {
            Log.search.info("knowledge qa stage=planner-cancelled request_id=\(request.requestID.uuidString)")
            throw CancellationError()
        } catch {
            Log.search.warning("knowledge query planning unavailable request_id=\(request.requestID.uuidString): \(error.localizedDescription)")
            Log.search.info("knowledge qa stage=planner-fallback fallback=direct-question request_id=\(request.requestID.uuidString)")
            return .fallback(for: query)
        }
    }

    private static func scopeName(_ scope: KnowledgeQAScope) -> String {
        switch scope {
        case .all: "all"
        case .session: "session"
        case .sessions: "sessions"
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
    }

    private static func logStage(
        _ stage: String,
        request: KnowledgeQARequest,
        budget: Duration? = nil,
        remaining: Duration? = nil
    ) {
        let budgetText = budget.map { " budget_ms=\(Self.milliseconds($0))" } ?? ""
        let remainingText = remaining.map { " remaining_ms=\(Self.milliseconds($0))" } ?? ""
        Log.search.info("knowledge qa stage=\(stage) scope=\(Self.scopeName(request.scope)) request_id=\(request.requestID.uuidString)\(budgetText)\(remainingText)")
    }

    private static func logOutcome(_ outcome: KnowledgeQAOutcome, request: KnowledgeQARequest, detail: String? = nil) {
        let suffix = detail.map { " detail=\($0)" } ?? ""
        Log.search.info("knowledge qa outcome=\(outcome.rawValue) request_id=\(request.requestID.uuidString)\(suffix)")
    }

    /// Returns a source-language target only when the selected scope has one
    /// unambiguous, visible transcript language. A mixed-language selection
    /// deliberately falls back to the user's question language.
    private func targetTranscriptLanguage(
        for scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?
    ) async -> String? {
        let selectedIDs = scope.sessionIDs
        guard !selectedIDs.isEmpty else { return nil }

        let visibility: (ids: [UUID], ownerUserID: String?) = await MainActor.run {
            let signedIn = AccountService.shared.isSignedIn
            let owner = AccountService.shared.userID?.uuidString
            let allowed = KnowledgeSourceOrigin.effectiveOrigins(
                isSignedIn: signedIn,
                uiFilter: originFilter
            )
            let ids = selectedIDs.filter { id in
                let session = WorkbenchStore.shared.sessions.first(where: { $0.id == id })
                let origin = KnowledgeSourceOrigin.resolve(
                    isCloudStorage: session?.storage == .cloud,
                    hasRemoteSessionID: session?.remoteSessionID != nil || session?.isRemoteOnly == true
                )
                guard allowed.contains(origin) else { return false }
                if origin == .cloud, !signedIn { return false }
                return owner != nil || origin == .local
            }
            return (ids, owner)
        }
        let visibleIDs = visibility.ids
        guard !visibleIDs.isEmpty else { return nil }

        let store = await MainActor.run { SessionIndexCoordinator.shared.searchService.store }
        var languages: [String] = []
        for id in visibleIDs {
            guard let card = try? await store.sessionCard(id: id),
                  let language = card.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !language.isEmpty
            else { continue }

            if card.sourceOrigin == .cloud, card.ownerUserID != visibility.ownerUserID {
                continue
            }
            if !languages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                languages.append(language)
            }
        }

        guard languages.count == 1 else { return nil }
        return languages[0]
    }

    /// Cloud/BYOK credentials are independent of the WeMM download gate.
    /// Retrieval still requires local WeMM even when the answer LLM is hosted.
    /// P0: allowCloud = true when hosted transport is available (no settings toggle yet).
    @MainActor
    static func makeTextClient(
        allowCloud: Bool,
        useCase: LLMUseCase
    ) async throws -> any LLMTextClient {
        switch AITransportPolicy.current {
        case .unavailable:
            throw KnowledgeQAError.llmUnavailable
        case .hosted:
            guard allowCloud else { throw KnowledgeQAError.cloudDisabled }
            return try await AITransportPolicy.makeTextClient(for: useCase)
        case .byok:
            return try await AITransportPolicy.makeTextClient(for: useCase)
        }
    }

    /// Compatibility entry point for the knowledge agent's general chat route.
    @MainActor
    static func makeTextClient(allowCloud: Bool) async throws -> any LLMTextClient {
        try await makeTextClient(allowCloud: allowCloud, useCase: .chat)
    }

    static func buildContext(hits: [SessionSearchHit], maxChars: Int) -> String {
        // Search commonly returns several chunks from one session.  Do not
        // use `Dictionary(uniqueKeysWithValues:)` here: duplicate session IDs
        // are valid input and must share one metadata record.
        var metadata: [UUID: KnowledgeSessionContextMetadata] = [:]
        for hit in hits where metadata[hit.sessionID] == nil {
            metadata[hit.sessionID] = KnowledgeSessionContextMetadata(
                title: hit.title,
                summary: nil
            )
        }
        return KnowledgeContextBuilder.build(
            anchors: hits,
            metadata: metadata,
            neighbors: [:],
            maxChars: maxChars
        )
    }

    static func citation(
        from hit: SessionSearchHit,
        matchText: String? = nil
    ) -> KnowledgeSourceRef {
        let sourceType: String
        switch hit.kind {
        case .transcriptChunk:
            sourceType = "sessionTranscript"
        case .mediaClip:
            sourceType = "mediaClip"
        case .sessionCard:
            sourceType = "sessionCard"
        }
        return KnowledgeSourceRef(
            sourceID: hit.sessionID.uuidString,
            sourceType: sourceType,
            title: hit.title,
            uri: nil,
            page: nil,
            startTime: hit.start,
            endTime: hit.end,
            parentID: nil,
            chunkIndex: hit.unitID,
            language: hit.language,
            speaker: hit.speakerLabels.first,
            snippet: hit.snippet ?? String(hit.text.prefix(180)),
            matchText: matchText ?? hit.snippet ?? hit.text
        )
    }

    static func systemPrompt(
        mode: KnowledgeAnswerMode,
        scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?,
        answerLanguage: KnowledgeAnswerLanguage = .english
    ) -> String {
        let scopeLine: String
        switch scope {
        case .all:
            let sources: String
            if let originFilter {
                let hasLocal = originFilter.contains(.local)
                let hasCloud = originFilter.contains(.cloud)
                if hasLocal && hasCloud {
                    sources = "local and cloud"
                } else if hasCloud {
                    sources = "cloud"
                } else {
                    sources = "local"
                }
            } else {
                sources = "visible"
            }
            scopeLine = "You are answering across the user's \(sources) knowledge base of transcribed sessions."
        case .session:
            scopeLine = "You are answering only about one selected session. Do not invent content from other sessions."
        case let .sessions(ids):
            scopeLine = "You are answering across \(ids.count) user-selected sessions only. Do not invent content from sessions outside that set."
        }
        let style: String
        switch mode {
        case .concise: style = "Keep answers concise (2–6 sentences)."
        case .normal: style = "Answer clearly in a short paragraph or bullet list when helpful."
        case .detailed: style = "Provide a thorough answer with structure when useful."
        }
        return """
        You are Vox Studio Knowledge Base assistant.
        \(scopeLine)
        Use only the provided transcript excerpts as evidence.
        The user's output constraints are instructions about how to format the answer, not evidence and not search terms. Follow them when they are compatible with the evidence.
        Treat an explicit length or format constraint as a required contract. Before finalizing, verify the answer satisfies it without adding a preface, explanation of the constraint, or extra conclusion.
        If the excerpts are insufficient, say you could not find enough evidence and list the closest sources.
        Do not fabricate quotes, speakers, or timestamps.
        The app presents readable, clickable sources below the answer. Do not append bare numbers as citations to prose. If an inline citation is essential, use only [n] matching the excerpt numbers; never emit a standalone token such as `45` or `123`.
        \(style)
        The required answer language is \(answerLanguage.instruction). Write the entire answer in that language, including headings, caveats, and source explanations. Never switch to English because the evidence excerpts are in English. Match the language of the user's question exactly.
        """
    }

    static let queryPlannerPrompt = """
        You are a retrieval query planner for a transcript knowledge base.
        Use recent conversation only to resolve references such as pronouns, "this plan", or "that meeting". Do not treat prior assistant answers as knowledge-base facts.
        Preserve the current question's task intent, including comparison, listing, timeline, or causal analysis.
        Separate retrieval semantics from instructions about the answer's length, language, style, citations, or format.
        If a pronoun or reference could reasonably match more than one person, plan, meeting, or other entity, do not guess. Return a clarification_question and leave search_query as the current question.
        Return strict JSON only, with this shape:
        {"standalone_query":"fully resolved question with referents filled in","search_query":"semantic terms and entities only","answer_constraints":["output requirements"],"clarification_question":null}
        standalone_query is the current question with people, plans, meetings, and times resolved. It is used for skill selection and routing, not as evidence.
        search_query must contain only topics, entities, relationships, and time needed to find evidence. Remove answer-format instructions.
        When the planner input supplies a target transcript language, write search_query in that language and script because the indexed transcript is stored in its source language. Translate the semantic search intent when needed, but keep named entities, acronyms, and proper nouns in their original spelling unless the transcript language clearly uses a localized form. This rule applies only to search_query; keep standalone_query and answer_constraints in the user's own wording.
        If no target transcript language is supplied, keep search_query in the language and script used by the current question. Do not translate or transliterate it unless the user explicitly asks for translation.
        Do not answer the question. Do not invent entities. If there is no explicit output constraint, return an empty array for answer_constraints. If no clarification is needed, set clarification_question to null.
        """

    static func queryPlannerInput(
        query: String,
        history: [KnowledgeMessage],
        targetTranscriptLanguage: String? = nil
    ) -> String {
        let recent = history.suffix(6)
        var lines: [String] = []
        if let targetTranscriptLanguage {
            let language = targetTranscriptLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !language.isEmpty {
                lines.append("Target transcript language for search_query: \(language)")
                lines.append("Use this source language/script for the semantic search query; do not apply it to answer_constraints.")
                lines.append("")
            }
        }
        if !recent.isEmpty {
            lines.append("Conversation context (use only to resolve references):")
            lines.append(contentsOf: recent.map { message in
                let role = message.role == .user ? "User" : "Assistant"
                return "\(role): \(message.content)"
            })
            lines.append("")
        }
        lines.append("Current question: \(query)")
        return lines.joined(separator: "\n")
    }

    static func userPrompt(
        query: String,
        standaloneQuery: String? = nil,
        searchQuery: String? = nil,
        answerConstraints: [String] = [],
        context: String,
        history: [KnowledgeMessage]
    ) -> String {
        var parts: [String] = []
        let recent = history.suffix(6)
        if !recent.isEmpty {
            parts.append("Conversation so far (reference resolution only; not evidence):")
            for message in recent {
                let role = message.role == .user ? "User" : "Assistant"
                parts.append("\(role): \(message.content)")
            }
            parts.append("")
        }
        parts.append("Evidence excerpts:")
        parts.append(context)
        parts.append("")
        if let standaloneQuery {
            parts.append("Resolved standalone question: \(standaloneQuery)")
        }
        if let searchQuery {
            parts.append("Retrieval search intent (already applied; do not treat it as an answer): \(searchQuery)")
        }
        if !answerConstraints.isEmpty {
            parts.append("Answer constraints (follow these output requirements):")
            parts.append(contentsOf: answerConstraints.map { "- \($0)" })
        }
        if standaloneQuery != nil || searchQuery != nil || !answerConstraints.isEmpty {
            parts.append("")
        }
        parts.append("Question: \(query)")
        return parts.joined(separator: "\n")
    }

    static func decodeQueryPlan(_ response: String) throws -> KnowledgeQueryPlan {
        struct WirePlan: Decodable {
            let standaloneQuery: String?
            let searchQuery: String
            let answerConstraints: [String]
            let clarificationQuestion: String?

            enum CodingKeys: String, CodingKey {
                case standaloneQuery = "standalone_query"
                case searchQuery = "search_query"
                case answerConstraints = "answer_constraints"
                case clarificationQuestion = "clarification_question"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                standaloneQuery = try container.decodeIfPresent(String.self, forKey: .standaloneQuery)
                searchQuery = try container.decode(String.self, forKey: .searchQuery)
                answerConstraints = try container.decodeIfPresent([String].self, forKey: .answerConstraints) ?? []
                clarificationQuestion = try container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n")
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8) else {
            throw KnowledgeQAError.invalidQueryPlan
        }
        let wire = try JSONDecoder().decode(WirePlan.self, from: data)
        let searchQuery = wire.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty, searchQuery.count <= 500 else {
            throw KnowledgeQAError.invalidQueryPlan
        }
        let standalone = (wire.standaloneQuery ?? searchQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standaloneQuery = standalone.isEmpty ? searchQuery : String(standalone.prefix(500))
        let constraints = wire.answerConstraints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { String($0.prefix(240)) }
        let clarification = wire.clarificationQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clarificationQuestion = (clarification?.isEmpty == false)
            ? String(clarification!.prefix(500))
            : nil
        return KnowledgeQueryPlan(
            standaloneQuery: standaloneQuery,
            searchQuery: searchQuery,
            answerConstraints: Array(constraints),
            clarificationQuestion: clarificationQuestion
        )
    }

    static func insufficientEvidenceMessage(
        scope: KnowledgeQAScope,
        language: KnowledgeAnswerLanguage = .english
    ) -> String {
        if language == .chinese {
            switch scope {
            case .all:
                return "我在你的知识库中没有找到足够的已索引转录证据来回答这个问题。请尝试更具体的关键词，或等候 session 完成索引。"
            case .session:
                return "我在这个 session 中没有找到足够的证据来回答这个问题。请尝试换一种问法，或确认该 session 已完成索引。"
            case .sessions:
                return "我在选中的 session 中没有找到足够的证据来回答这个问题。请尝试换一种问法，或确认这些 session 已完成索引。"
            }
        }
        switch scope {
        case .all:
            return "I could not find enough indexed transcript evidence for that question across your knowledge base. Try a more specific phrase, or wait until sessions finish indexing."
        case .session:
            return "I could not find enough evidence in this session for that question. Try different wording, or confirm the session has finished indexing."
        case .sessions:
            return "I could not find enough evidence in the selected sessions for that question. Try different wording, or confirm those sessions have finished indexing."
        }
    }

    static func retrievalTimeoutMessage(
        scope: KnowledgeQAScope,
        language: KnowledgeAnswerLanguage = .english
    ) -> String {
        if language == .chinese {
            switch scope {
            case .all:
                return "知识库检索在时限内没有完成，因此我没有足够的证据回答这个问题。请稍后重试。"
            case .session:
                return "这个 session 的检索在时限内没有完成，因此我没有足够的证据回答这个问题。请稍后重试。"
            case .sessions:
                return "选中 session 的检索在时限内没有完成，因此我没有足够的证据回答这个问题。请稍后重试。"
            }
        }
        switch scope {
        case .all:
            return "Knowledge search did not finish within the time limit, so I do not have enough evidence to answer. Please try again."
        case .session:
            return "Search for this session did not finish within the time limit, so I do not have enough evidence to answer. Please try again."
        case .sessions:
            return "Search for the selected sessions did not finish within the time limit, so I do not have enough evidence to answer. Please try again."
        }
    }

    static func retrievalFailureMessage(
        scope: KnowledgeQAScope,
        language: KnowledgeAnswerLanguage = .english
    ) -> String {
        if language == .chinese {
            switch scope {
            case .all:
                return "知识库检索遇到暂时性错误，无法可靠回答这个问题。请稍后重试。"
            case .session:
                return "这个 session 的检索遇到暂时性错误，无法可靠回答这个问题。请稍后重试。"
            case .sessions:
                return "选中 session 的检索遇到暂时性错误，无法可靠回答这个问题。请稍后重试。"
            }
        }
        switch scope {
        case .all:
            return "Knowledge search failed temporarily, so I cannot answer reliably. Please try again."
        case .session:
            return "Search for this session failed temporarily, so I cannot answer reliably. Please try again."
        case .sessions:
            return "Search for the selected sessions failed temporarily, so I cannot answer reliably. Please try again."
        }
    }

    static func excerptFallback(
        query: String,
        hits: [SessionSearchHit],
        language: KnowledgeAnswerLanguage = .english
    ) -> String {
        let isCatalogResult = !hits.isEmpty && hits.allSatisfy { $0.kind == .sessionCard }
        var lines: [String]
        if language == .chinese {
            lines = [
                isCatalogResult
                    ? "我找到了匹配的 session，但回答模型在时限内没有返回可用答案。下面列出请求的 session 元数据："
                    : "我找到了相关的转录片段，但回答模型在时限内没有返回可用答案。下面列出最接近的证据摘录：",
                "",
                "与“\(query)”最接近的匹配：",
            ]
        } else {
            lines = [
                isCatalogResult
                    ? "I found matching sessions, but AI answering did not return a usable answer within the time limit. Here is the requested session metadata:"
                    : "I found related transcript excerpts, but AI answering did not return a usable answer within the time limit. Here are the closest evidence excerpts:",
                "",
                "Closest matches for “\(query)”:",
            ]
        }
        for (index, hit) in hits.prefix(5).enumerated() {
            if hit.kind == .sessionCard {
                let duration: String
                if hit.duration.isFinite && hit.duration > 0 {
                    let totalSeconds = Int(hit.duration.rounded())
                    let hours = totalSeconds / 3600
                    let minutes = (totalSeconds % 3600) / 60
                    let seconds = totalSeconds % 60
                    duration = hours > 0
                        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                        : String(format: "%d:%02d", minutes, seconds)
                } else {
                    duration = "—"
                }
                let modified: String
                if let timestamp = hit.sourceModifiedAt, timestamp.isFinite {
                    modified = Date(timeIntervalSince1970: timestamp)
                        .formatted(date: .abbreviated, time: .omitted)
                } else {
                    modified = "—"
                }
                lines.append(
                    "\(index + 1). \(hit.title) · \(hit.sessionType.label) · \(hit.sourceOrigin.label) · \(duration) · \(modified)"
                )
            } else {
                let time = hit.start.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
                let snippet = (hit.snippet ?? hit.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = snippet.count > 160 ? String(snippet.prefix(157)) + "…" : snippet
                lines.append("\(index + 1). \(hit.title) · \(time) — \(clipped)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Split a completed answer into small deltas for P0 UI animation.
    /// Not token-level SSE — replace when a streaming LLM client exists (P1+).
    static func chunkForStreaming(_ text: String, chunkSize: Int = 18) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<end]))
            index = end
        }
        return chunks
    }
}

enum KnowledgeQAError: LocalizedError {
    case llmUnavailable
    case cloudDisabled
    case sessionNotVisible
    case invalidRerankerOutput
    case invalidQueryPlan
    case timeout

    var errorDescription: String? {
        switch self {
        case .llmUnavailable:
            "AI answering is unavailable. Sign in for hosted AI or configure BYOK in Settings → AI."
        case .cloudDisabled:
            "Cloud answering is disabled for this request."
        case .sessionNotVisible:
            "Sign in to ask about this cloud session."
        case .invalidRerankerOutput:
            "Knowledge search could not rank the available information. Try again."
        case .invalidQueryPlan:
            "Knowledge search could not prepare this question. Try again."
        case .timeout:
            "AI answering took too long to respond. Showing transcript excerpts instead."
        }
    }
}
