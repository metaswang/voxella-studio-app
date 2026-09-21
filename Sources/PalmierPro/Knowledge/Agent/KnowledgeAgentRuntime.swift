import Foundation

/// Knowledge Base Agent runtime: skill selection → routing → tool-loop → evidence gate → answer composition.
/// P0 implementation: uses structured JSON tool-loop (LLMTextClient has no native function calling).
struct KnowledgeAgentRuntime: Sendable {
    let scope: KnowledgeQAScope
    let originFilter: Set<KnowledgeSourceOrigin>?
    let allowCloud: Bool
    let queryPlan: KnowledgeQueryPlan
    let retrievalService: KnowledgeRetrievalService
    let fallbackService: KnowledgeQAService
    let skillsProvider: @Sendable () async -> [Skill]

    init(
        scope: KnowledgeQAScope,
        originFilter: Set<KnowledgeSourceOrigin>?,
        allowCloud: Bool,
        queryPlan: KnowledgeQueryPlan,
        retrievalService: KnowledgeRetrievalService,
        fallbackService: KnowledgeQAService,
        skillsProvider: @escaping @Sendable () async -> [Skill] = {
            await MainActor.run { SkillStore.shared.knowledgeSkills() }
        }
    ) {
        self.scope = scope
        self.originFilter = originFilter
        self.allowCloud = allowCloud
        self.queryPlan = queryPlan
        self.retrievalService = retrievalService
        self.fallbackService = fallbackService
        self.skillsProvider = skillsProvider
    }
    
    static let maxToolRounds = 6
    static let simpleQAToolBudget = 2
    /// Skill selection must never hold the QA stream open indefinitely. If the
    /// selector is unavailable, the capability-aware heuristic below can still
    /// route collection-scoped requests to the collection-analysis skill.
    static let skillSelectionTimeout: Duration = .seconds(8)
    /// Bound every follow-up Agent request as well. The hosted client has its
    /// own transport policy, but a retrying or non-cooperative provider must
    /// not leave the Knowledge page stuck in an intermediate status forever.
    static let agentCompletionTimeout: Duration = .seconds(60)
    
    func answer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(KnowledgeUserFacingCopy.message(for: error)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    func run(
        _ request: KnowledgeQARequest,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let query = request.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            continuation.yield(.failed("Enter a question to ask your knowledge base."))
            continuation.finish()
            return
        }
        
        try Task.checkCancellation()
        if !fallbackService.isPipelineInjected {
            try await MainActor.run {
                try AccountService.shared.requireNewContentAccess()
            }
        }

        continuation.yield(.status("Loading skills…"))
        let skills = await skillsProvider()
        
        guard !skills.isEmpty else {
            continuation.yield(.status("Falling back to simple search…"))
            try await fallbackToSimpleRAG(request, continuation: continuation)
            return
        }
        
        continuation.yield(.status("Selecting skills…"))
        let selectedSkills = try await selectSkills(
            query: queryPlan.standaloneQuery,
            scope: scope,
            skills: skills,
            requestID: request.requestID
        )
        
        guard !selectedSkills.isEmpty else {
            continuation.yield(.status("Falling back to simple search…"))
            try await fallbackToSimpleRAG(request, continuation: continuation)
            return
        }
        
        let route = routeRequest(query: queryPlan.standaloneQuery, scope: scope, skills: selectedSkills)
        
        switch route {
        case .simpleQA:
            continuation.yield(.status("Quick search…"))
            try await executeSimpleQA(request, skills: selectedSkills, continuation: continuation)
        case .inventory:
            continuation.yield(.status("Listing sessions…"))
            try await executeToolLoop(request, skills: selectedSkills, maxRounds: 4, continuation: continuation)
        case .complex:
            continuation.yield(.status("Analyzing with tools…"))
            try await executeToolLoop(request, skills: selectedSkills, maxRounds: Self.maxToolRounds, continuation: continuation)
        }
    }
    
    private func selectSkills(
        query: String,
        scope: KnowledgeQAScope,
        skills: [Skill],
        requestID: UUID
    ) async throws -> [Skill] {
        let selectionPrompt = Self.skillSelectionPrompt(query: query, scope: scope, skills: skills)
        let startedAt = Date()
        
        do {
            let client = try await Self.makeTextClient(
                allowCloud: allowCloud,
                useCase: .skillSelection
            )
            let response = try await KnowledgeQATimeout.run(Self.skillSelectionTimeout) {
                try await Self.complete(
                    client,
                    system: selectionPrompt.system,
                    user: selectionPrompt.user,
                    options: .skillSelection
                )
            }
            
            if let selectedIDs = Self.parseSkillSelection(response), !selectedIDs.isEmpty {
                var selected = Array(skills.filter { selectedIDs.contains($0.id) }.prefix(3))
                if !selected.isEmpty {
                    // A collection-scoped request needs collection-analysis
                    // capability even when the selector returns only the
                    // transcript or inventory skill. Keep the model's other
                    // choices, but make the cross-session route available.
                    if Self.isCollectionScope(scope),
                       let collectionSkill = skills.first(where: { $0.id == "mac_kb_collection_analysis" }),
                       !selected.contains(where: { $0.id == collectionSkill.id }) {
                        selected.insert(collectionSkill, at: 0)
                    }
                    let result = Array(selected.prefix(3))
                    Log.knowledge.notice(
                        "skill_selection completed request_id=\(requestID.uuidString.lowercased()) available_skill_count=\(skills.count) selected_skill_count=\(result.count) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                    return result
                }
            }
        } catch {
            Log.knowledge.warning(
                "skill_selection fallback request_id=\(requestID.uuidString.lowercased()) available_skill_count=\(skills.count) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) reason=\(error.localizedDescription)"
            )
        }
        
        Log.knowledge.notice(
            "skill_selection heuristic_fallback request_id=\(requestID.uuidString.lowercased()) available_skill_count=\(skills.count) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        return Self.heuristicSkillSelection(query: query, scope: scope, skills: skills)
    }
    
    private func routeRequest(query: String, scope: KnowledgeQAScope, skills: [Skill]) -> KnowledgeAgentRoute {
        let queryLower = query.lowercased()
        
        let hasCollectionSkill = skills.contains { $0.id == "mac_kb_collection_analysis" }
        let hasTimelineSkill = skills.contains { $0.id == "mac_kb_timeline_qa" }
        let hasMultiSessionSkill = hasCollectionSkill || hasTimelineSkill

        let hasInventorySkill = skills.contains { $0.id == "mac_kb_session_inventory" }
        let explicitInventoryQuery = queryLower.contains("how many")
            || queryLower.contains("list all")
            || queryLower.contains("which sessions")
        
        let isSingleSession = scope.sessionIDs.count == 1
        let hasTranscriptSkill = skills.contains { $0.id == "mac_kb_session_transcript" }
        
        // Explicit inventory requests win. Otherwise, if collection analysis
        // is present, prefer the multi-session loop over a metadata-only or
        // transcript-only route.
        if explicitInventoryQuery || (hasInventorySkill && !hasCollectionSkill && !hasTimelineSkill) {
            return .inventory
        }
        
        if isSingleSession && hasTranscriptSkill && !hasMultiSessionSkill {
            return .simpleQA
        }
        
        if hasMultiSessionSkill {
            return .complex
        }

        if hasInventorySkill {
            return .inventory
        }
        
        return .simpleQA
    }
    
    private func executeSimpleQA(
        _ request: KnowledgeQARequest,
        skills: [Skill],
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let executor = KnowledgeToolExecutor(
            scope: scope,
            originFilter: originFilter,
            retrievalService: retrievalService,
            requestID: request.requestID
        )
        let answerLanguage = KnowledgeAnswerLanguage.detect(from: request.queryText)
        
        var hits: [KnowledgeSourceRef] = []
        let searchResult = try await executor.execute(
            toolName: "knowledge.search",
            arguments: ["query": queryPlan.searchQuery, "limit": 8]
        )
        
        if case let .success(data) = searchResult,
           let citations = data["citations"] as? [[String: Any]] {
            hits = citations.compactMap { Self.parseCitation($0) }
        }
        
        try Task.checkCancellation()
        
        if hits.isEmpty {
            let message = KnowledgeQAService.insufficientEvidenceMessage(
                scope: request.scope,
                language: answerLanguage
            )
            continuation.yield(.citations([]))
            continuation.yield(.status("No evidence found"))
            for chunk in KnowledgeQAService.chunkForStreaming(message) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(message))
            continuation.finish()
            return
        }
        
        continuation.yield(.citations(hits))
        continuation.yield(.status("Composing answer…"))

        let contextHits = Self.sessionHits(from: hits)
        let context = KnowledgeQAService.buildContext(hits: contextHits, maxChars: 10_000)
        let system = KnowledgeQAService.systemPrompt(
            mode: request.answerMode,
            scope: request.scope,
            originFilter: originFilter,
            answerLanguage: answerLanguage
        )
        let user = KnowledgeQAService.userPrompt(
            query: request.queryText,
            standaloneQuery: queryPlan.standaloneQuery,
            searchQuery: queryPlan.searchQuery,
            answerConstraints: queryPlan.answerConstraints,
            context: context,
            history: request.history
        )
        
        let answerText: String
        do {
            if let answer = fallbackService.dependencies.answer {
                answerText = try await answer(system, user, allowCloud)
            } else {
                let client = try await Self.makeTextClient(allowCloud: allowCloud)
                answerText = try await Self.completeWithTimeout(client, system: system, user: user)
            }
        } catch {
            let fallback = KnowledgeQAService.excerptFallback(
                query: request.queryText,
                hits: contextHits,
                language: answerLanguage
            )
            continuation.yield(.status("Showing excerpts…"))
            for chunk in KnowledgeQAService.chunkForStreaming(fallback) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(fallback))
            continuation.finish()
            return
        }
        
        try Task.checkCancellation()
        continuation.yield(.status("Showing answer…"))
        for chunk in KnowledgeQAService.chunkForStreaming(answerText) {
            try Task.checkCancellation()
            continuation.yield(.delta(chunk))
            try await Task.sleep(for: .milliseconds(12))
        }
        continuation.yield(.finished(answerText))
        continuation.finish()
    }
    
    private func executeToolLoop(
        _ request: KnowledgeQARequest,
        skills: [Skill],
        maxRounds: Int,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let executor = KnowledgeToolExecutor(
            scope: scope,
            originFilter: originFilter,
            retrievalService: retrievalService,
            requestID: request.requestID
        )
        let client = try await Self.makeTextClient(allowCloud: allowCloud)
        let answerLanguage = KnowledgeAnswerLanguage.detect(from: request.queryText)
        
        var conversationHistory: [String] = []
        var citations: [KnowledgeSourceRef] = []
        var acceptedReferenceIDs: [String]?
        
        let systemPrompt = await Self.agentSystemPrompt(skills: skills, scope: scope)
        let initialUser = Self.agentInitialUserPrompt(
            query: request.queryText,
            queryPlan: queryPlan,
            history: request.history
        )
        
        conversationHistory.append("User: \(initialUser)")
        
        for _ in 1...maxRounds {
            try Task.checkCancellation()
            
            let thinking = conversationHistory.joined(separator: "\n\n")
            let response: String
            do {
                response = try await Self.completeWithTimeout(client, system: systemPrompt, user: thinking)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as KnowledgeQAError {
                guard case .timeout = error else { throw error }
                // Preserve evidence already collected by earlier tool calls.
                // A slow follow-up model request must not turn a grounded
                // answer into a generic no-evidence response.
                Log.knowledge.warning("Agent tool-loop request timed out; composing from collected evidence")
                break
            }
            
            conversationHistory.append("Assistant: \(response)")
            
            let parsed = Self.parseToolCalls(response)
            
            if parsed.toolCalls.isEmpty {
                continuation.yield(.status("Composing final answer…"))
                
                let answerCitations = Self.answerCitations(
                    from: citations,
                    acceptedReferenceIDs: acceptedReferenceIDs
                )
                let context = Self.buildContextFromCitations(answerCitations, maxChars: 10_000)
                let finalSystem = KnowledgeQAService.systemPrompt(
                    mode: request.answerMode,
                    scope: request.scope,
                    originFilter: originFilter,
                    answerLanguage: answerLanguage
                )
                let finalUser = KnowledgeQAService.userPrompt(
                    query: request.queryText,
                    standaloneQuery: queryPlan.standaloneQuery,
                    searchQuery: queryPlan.searchQuery,
                    answerConstraints: queryPlan.answerConstraints,
                    context: context,
                    history: request.history
                )
                
                let answerText: String
                do {
                    answerText = try await Self.completeWithTimeout(client, system: finalSystem, user: finalUser)
                } catch {
                    try await Self.emitEvidenceFallback(
                        query: request.queryText,
                        scope: request.scope,
                        language: answerLanguage,
                        citations: answerCitations,
                        continuation: continuation
                    )
                    return
                }
                
                continuation.yield(.citations(answerCitations))
                continuation.yield(.status("Showing answer…"))
                for chunk in KnowledgeQAService.chunkForStreaming(answerText) {
                    try Task.checkCancellation()
                    continuation.yield(.delta(chunk))
                    try await Task.sleep(for: .milliseconds(12))
                }
                continuation.yield(.finished(answerText))
                continuation.finish()
                return
            }
            
            var observations: [String] = []
            var shouldFinish = false
            
            for toolCall in parsed.toolCalls {
                try Task.checkCancellation()
                
                let result = try await executor.execute(toolName: toolCall.name, arguments: toolCall.arguments)
                
                switch result {
                case let .success(data):
                    if let cits = data["citations"] as? [[String: Any]] {
                        Self.appendUnique(
                            cits.compactMap { Self.parseCitation($0) },
                            to: &citations
                        )
                    }
                    let observation = "Tool \(toolCall.name) returned: \(Self.formatDict(data))"
                    observations.append(observation)
                    
                case let .error(message):
                    observations.append("Tool \(toolCall.name) error: \(message)")
                    
                case let .control(control):
                    switch control {
                    case let .finish(acceptedRefs):
                        shouldFinish = true
                        acceptedReferenceIDs = acceptedRefs
                        observations.append("finish_with_evidence called with \(acceptedRefs.count) refs")
                        
                    case let .clarify(question):
                        continuation.yield(.clarification(question))
                        continuation.finish()
                        return
                    }
                }
            }
            
            conversationHistory.append("Observations: \(observations.joined(separator: "; "))")
            
            if shouldFinish {
                break
            }
        }
        
        let answerCitations = Self.answerCitations(
            from: citations,
            acceptedReferenceIDs: acceptedReferenceIDs
        )
        continuation.yield(.citations(answerCitations))
        continuation.yield(.status("Composing final answer…"))
        
        let context = Self.buildContextFromCitations(answerCitations, maxChars: 10_000)
        let finalSystem = KnowledgeQAService.systemPrompt(
            mode: request.answerMode,
            scope: request.scope,
            originFilter: originFilter,
            answerLanguage: answerLanguage
        )
        let finalUser = KnowledgeQAService.userPrompt(
            query: request.queryText,
            standaloneQuery: queryPlan.standaloneQuery,
            searchQuery: queryPlan.searchQuery,
            answerConstraints: queryPlan.answerConstraints,
            context: context,
            history: request.history
        )
        
        let answerText: String
        do {
            answerText = try await Self.completeWithTimeout(client, system: finalSystem, user: finalUser)
        } catch {
            try await Self.emitEvidenceFallback(
                query: request.queryText,
                scope: request.scope,
                language: answerLanguage,
                citations: answerCitations,
                continuation: continuation
            )
            return
        }
        
        continuation.yield(.status("Showing answer…"))
        for chunk in KnowledgeQAService.chunkForStreaming(answerText) {
            try Task.checkCancellation()
            continuation.yield(.delta(chunk))
            try await Task.sleep(for: .milliseconds(12))
        }
        continuation.yield(.finished(answerText))
        continuation.finish()
    }
    
    private func fallbackToSimpleRAG(
        _ request: KnowledgeQARequest,
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        try await fallbackService.runPrepared(
            request,
            queryPlan: queryPlan,
            continuation: continuation
        )
    }
    
    @MainActor
    private static func makeTextClient(
        allowCloud: Bool,
        useCase: LLMUseCase = .chat
    ) async throws -> any LLMTextClient {
        try await KnowledgeQAService.makeTextClient(allowCloud: allowCloud, useCase: useCase)
    }

    private static func complete(
        _ client: any LLMTextClient,
        system: String,
        user: String,
        options: LLMTextCompletionOptions
    ) async throws -> String {
        if let configurable = client as? any LLMConfigurableTextClient {
            return try await configurable.complete(system: system, user: user, options: options)
        }
        return try await client.complete(system: system, user: user)
    }

    private static func completeWithTimeout(
        _ client: any LLMTextClient,
        system: String,
        user: String
    ) async throws -> String {
        try await KnowledgeQATimeout.run(Self.agentCompletionTimeout) {
            try await client.complete(system: system, user: user)
        }
    }

    private static func emitEvidenceFallback(
        query: String,
        scope: KnowledgeQAScope,
        language: KnowledgeAnswerLanguage,
        citations: [KnowledgeSourceRef],
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let hits = sessionHits(from: citations)
        let text: String
        if hits.isEmpty {
            text = KnowledgeQAService.insufficientEvidenceMessage(scope: scope, language: language)
        } else {
            text = KnowledgeQAService.excerptFallback(query: query, hits: hits, language: language)
        }

        continuation.yield(.citations(citations))
        continuation.yield(.status("Showing excerpts…"))
        for chunk in KnowledgeQAService.chunkForStreaming(text) {
            try Task.checkCancellation()
            continuation.yield(.delta(chunk))
            try await Task.sleep(for: .milliseconds(12))
        }
        continuation.yield(.finished(text))
        continuation.finish()
    }

    /// Load skill instruction bodies from each skill's SKILL.md path (installed or bundled).
    private static func getSkillBodies(skills: [Skill]) -> String {
        skills.map { skill in
            let text = (try? String(contentsOf: skill.path, encoding: .utf8)) ?? ""
            let body = SkillFrontmatter.parse(text).body
            let content = body.isEmpty ? skill.description : body
            return "## \(skill.name) (\(skill.id))\n\(content)"
        }.joined(separator: "\n\n")
    }
    
    private static func heuristicSkillSelection(query: String, scope: KnowledgeQAScope, skills: [Skill]) -> [Skill] {
        let queryLower = query.lowercased()
        
        if scope.sessionIDs.count > 1,
           queryLower.contains("compare") || queryLower.contains("contrast") || queryLower.contains("difference") {
            if let skill = skills.first(where: { $0.id == "mac_kb_collection_analysis" }) {
                return [skill]
            }
        }
        
        if queryLower.contains("timeline") || queryLower.contains("when") || queryLower.contains("at ") {
            if let skill = skills.first(where: { $0.id == "mac_kb_timeline_qa" }) {
                return [skill]
            }
        }
        
        if queryLower.contains("how many") || queryLower.contains("list all") || queryLower.contains("which sessions") {
            if let skill = skills.first(where: { $0.id == "mac_kb_session_inventory" }) {
                return [skill]
            }
        }

        // A collection scope is inherently multi-session. When the selector
        // model is unavailable, prefer the skill that can inspect the whole
        // collection over the transcript-only fallback. This is deliberately
        // capability-based rather than a list of language-specific phrases.
        if Self.isCollectionScope(scope),
           let skill = skills.first(where: { $0.id == "mac_kb_collection_analysis" }) {
            return [skill]
        }
        
        if scope.sessionIDs.count == 1,
           let skill = skills.first(where: { $0.id == "mac_kb_session_transcript" }) {
            return [skill]
        }
        
        if let skill = skills.first(where: { $0.id == "mac_kb_content_qa" }) {
            return [skill]
        }
        
        return skills.prefix(1).map { $0 }
    }

    private static func isCollectionScope(_ scope: KnowledgeQAScope) -> Bool {
        switch scope {
        case .all:
            return true
        case let .sessions(ids):
            return ids.count > 1
        case .session:
            return false
        }
    }
    
    static func skillSelectionPrompt(query: String, scope: KnowledgeQAScope, skills: [Skill]) -> (system: String, user: String) {
        let skillList = skills.map { skill in
            let summary = skill.metadata?.selectionSummary ?? skill.description
            return "- \(skill.id): \(summary)"
        }.joined(separator: "\n")
        
        let system = """
        You are a skill selector for a knowledge base assistant.
        Select up to 3 skills that best match the user's query.
        
        Available skills:
        \(skillList)
        
        Output ONLY this JSON object, with no explanation: {"selected_skill_ids":["mac_kb_content_qa"]}
        """
        
        let scopeDescription: String
        switch scope {
        case .all:
            scopeDescription = "across all sessions"
        case .session:
            scopeDescription = "within one selected session"
        case let .sessions(ids):
            scopeDescription = "across \(ids.count) selected sessions"
        }
        
        let user = "Query: \(query)\nScope: \(scopeDescription)\n\nSelect skills:"
        
        return (system, user)
    }
    
    static func parseSkillSelection(_ response: String) -> [String]? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let payload = object as? [String: Any] {
            guard payload.keys.allSatisfy({ $0 == "selected_skill_ids" }),
                  let ids = payload["selected_skill_ids"] as? [String] else {
                return nil
            }
            return Array(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.prefix(3))
        }
        // Keep accepting the old array shape for rolling upgrades and older
        // providers that do not support structured output yet.
        if let array = object as? [String] {
            return Array(array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.prefix(3))
        }
        return nil
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
    
    private static func agentSystemPrompt(skills: [Skill], scope: KnowledgeQAScope) async -> String {
        let toolDefs = KnowledgeToolRegistry.allTools.map { tool in
            let params = tool.parameters.map { "\($0.name) (\($0.type)): \($0.description)" }.joined(separator: ", ")
            return "- \(tool.name): \(tool.description). Parameters: \(params)"
        }.joined(separator: "\n")
        
        let skillBodies = getSkillBodies(skills: skills)
        
        return """
        You are a knowledge base assistant with access to tools.
        
        Available tools:
        \(toolDefs)
        
        Active skills:
        \(skillBodies)
        
        To use tools, output JSON in this format:
        {"tool_calls": [{"name": "tool.name", "arguments": {"param": "value"}}]}
        
        You MUST call finish_with_evidence when you have gathered sufficient evidence.
        Call ask_clarification if the query is ambiguous or evidence is insufficient.

        For a query that classifies or finds a theme across multiple sessions,
        call session.list without a topic in its query field (that field only
        filters titles), then inspect summaries or transcript evidence before
        deciding which sessions support the answer.
        
        Think step-by-step and use tools to gather evidence before answering.
        """
    }
    
    private static func agentInitialUserPrompt(
        query: String,
        queryPlan: KnowledgeQueryPlan,
        history: [KnowledgeMessage]
    ) -> String {
        var parts: [String] = []
        
        let recent = history.suffix(3)
        if !recent.isEmpty {
            parts.append("Conversation history:")
            for message in recent {
                let role = message.role == .user ? "User" : "Assistant"
                parts.append("\(role): \(message.content)")
            }
            parts.append("")
        }
        
        parts.append("Original query: \(query)")
        parts.append("Resolved standalone query: \(queryPlan.standaloneQuery)")
        parts.append("Retrieval search query: \(queryPlan.searchQuery)")
        if queryPlan.answerConstraints.isEmpty {
            parts.append("Answer constraints: none")
        } else {
            parts.append("Answer constraints:")
            parts.append(contentsOf: queryPlan.answerConstraints.map { "- \($0)" })
        }
        parts.append("")
        parts.append("Use available tools to gather evidence. The first semantic transcript search must use the retrieval search query or an equivalent expansion of it.")
        parts.append("Then call finish_with_evidence.")
        
        return parts.joined(separator: "\n")
    }
    
    private static func parseToolCalls(_ response: String) -> (toolCalls: [ParsedToolCall], thinking: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let jsonPattern = #"\{[^}]*"tool_calls"[^}]*\[[^\]]*\][^}]*\}"#
        if let regex = try? NSRegularExpression(pattern: jsonPattern, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) {
            guard let range = Range(match.range, in: trimmed) else {
                return ([], trimmed)
            }
            let jsonStr = String(trimmed[range])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let calls = json["tool_calls"] as? [[String: Any]] {
                let parsed = calls.compactMap { ParsedToolCall.from($0) }
                return (parsed, trimmed)
            }
        }
        
        return ([], trimmed)
    }
    
    private static func buildContextFromCitations(_ citations: [KnowledgeSourceRef], maxChars: Int) -> String {
        var used = 0
        var blocks: [String] = []
        for (index, ref) in citations.enumerated() {
            let snippet = ref.snippet ?? ""
            guard !snippet.isEmpty else { continue }
            let block = "[\(index + 1)] \(ref.title) — \(snippet)"
            if used + block.count > maxChars, !blocks.isEmpty { break }
            blocks.append(block)
            used += block.count
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Keep the evidence shown in the answer aligned with the agent's final
    /// evidence decision. A search can run more than once during the tool
    /// loop, so the raw citation array is not a stable citation list for the
    /// final answer.
    private static func answerCitations(
        from citations: [KnowledgeSourceRef],
        acceptedReferenceIDs: [String]?
    ) -> [KnowledgeSourceRef] {
        let unique = citations.reduce(into: [KnowledgeSourceRef]()) { result, citation in
            guard !result.contains(where: { $0.id == citation.id }) else { return }
            result.append(citation)
        }

        guard let acceptedReferenceIDs else {
            // The model may exhaust its tool budget without emitting the
            // control call. Keep only evidence-bearing candidates in that
            // case; session cards alone must never become answer context.
            return unique.filter { citation in
                guard let snippet = citation.snippet else { return false }
                return !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard !acceptedReferenceIDs.isEmpty else { return [] }

        let acceptedIDs = Set(acceptedReferenceIDs)
        let acceptedIndexes = Set<Int>(
            acceptedReferenceIDs.compactMap { value in
                guard let number = Int(value), number > 0 else { return nil }
                return number - 1
            }
        )
        return unique.enumerated().compactMap { index, citation in
            if acceptedIDs.contains(citation.id)
                || acceptedIDs.contains(citation.sourceID)
                || acceptedIndexes.contains(index) {
                return citation
            }
            return nil
        }
    }

    private static func appendUnique(
        _ incoming: [KnowledgeSourceRef],
        to citations: inout [KnowledgeSourceRef]
    ) {
        for citation in incoming where !citations.contains(where: { $0.id == citation.id }) {
            citations.append(citation)
        }
    }
    
    private static func parseCitation(_ dict: [String: Any]) -> KnowledgeSourceRef? {
        guard dict["id"] as? String != nil,
              let sourceID = dict["source_id"] as? String,
              let sourceType = dict["source_type"] as? String,
              let title = dict["title"] as? String else {
            return nil
        }
        return KnowledgeSourceRef(
            sourceID: sourceID,
            sourceType: sourceType,
            title: title,
            uri: dict["uri"] as? String,
            page: dict["page"] as? Int,
            startTime: dict["start_time"] as? Double,
            endTime: dict["end_time"] as? Double,
            parentID: nil,
            chunkIndex: dict["chunk_index"] as? Int,
            language: dict["language"] as? String,
            speaker: dict["speaker"] as? String,
            snippet: dict["snippet"] as? String,
            matchText: dict["match_text"] as? String
        )
    }
    
    private static func sessionHits(from citations: [KnowledgeSourceRef]) -> [SessionSearchHit] {
        citations.enumerated().compactMap { index, citation in
            // A citation produced by an older provider may not have a chunk
            // index. Use a unique negative fallback so multiple such citations
            // remain distinct while never colliding with database unit IDs.
            citationToHit(citation, fallbackUnitID: -index - 1)
        }
    }

    private static func citationToHit(
        _ ref: KnowledgeSourceRef,
        fallbackUnitID: Int
    ) -> SessionSearchHit? {
        guard let sessionID = ref.sessionUUID else { return nil }
        let kind: SessionIndexUnitKind
        switch ref.sourceType {
        case "mediaClip":
            kind = .mediaClip
        case "sessionCard", "sessionSummary":
            kind = .sessionCard
        default:
            kind = .transcriptChunk
        }
        return SessionSearchHit(
            sessionID: sessionID,
            title: ref.title,
            unitID: ref.chunkIndex ?? fallbackUnitID,
            kind: kind,
            start: ref.startTime,
            end: ref.endTime,
            speakerLabels: ref.speaker.map { [$0] } ?? [],
            text: ref.matchText ?? ref.snippet ?? "",
            score: 1.0,
            matchSource: ref.sourceType,
            snippet: ref.snippet,
            cueIDs: [],
            hasVideo: false,
            language: ref.language,
            quoteSpan: nil
        )
    }
    
    private static func formatDict(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "\(dict)"
        }
        return str
    }
}

struct ParsedToolCall: @unchecked Sendable {
    let name: String
    let arguments: [String: Any]
    
    static func from(_ dict: [String: Any]) -> ParsedToolCall? {
        guard let name = dict["name"] as? String,
              let arguments = dict["arguments"] as? [String: Any] else {
            return nil
        }
        return ParsedToolCall(name: name, arguments: arguments)
    }
}

enum KnowledgeAgentRoute {
    case simpleQA
    case inventory
    case complex
}
