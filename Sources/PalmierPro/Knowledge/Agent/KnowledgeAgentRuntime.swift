import Foundation

/// Knowledge Base Agent runtime: skill selection → routing → tool-loop → evidence gate → answer composition.
/// P0 implementation: uses structured JSON tool-loop (LLMTextClient has no native function calling).
struct KnowledgeAgentRuntime: Sendable {
    let scope: KnowledgeQAScope
    let originFilter: Set<KnowledgeSourceOrigin>?
    let allowCloud: Bool
    
    static let maxToolRounds = 6
    static let simpleQAToolBudget = 2
    
    func answer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    private func run(
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
        try await MainActor.run {
            try AccountService.shared.requireNewContentAccess()
        }
        
        continuation.yield(.status("Loading skills…"))
        let skills = await MainActor.run { SkillStore.shared.knowledgeSkills() }
        
        guard !skills.isEmpty else {
            continuation.yield(.status("Falling back to simple search…"))
            try await fallbackToSimpleRAG(request, continuation: continuation)
            return
        }
        
        continuation.yield(.status("Selecting skills…"))
        let selectedSkills = try await selectSkills(query: query, scope: scope, skills: skills)
        
        guard !selectedSkills.isEmpty else {
            continuation.yield(.status("Falling back to simple search…"))
            try await fallbackToSimpleRAG(request, continuation: continuation)
            return
        }
        
        let route = routeRequest(query: query, scope: scope, skills: selectedSkills)
        
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
    
    private func selectSkills(query: String, scope: KnowledgeQAScope, skills: [Skill]) async throws -> [Skill] {
        let selectionPrompt = Self.skillSelectionPrompt(query: query, scope: scope, skills: skills)
        
        do {
            let client = try await Self.makeTextClient(allowCloud: allowCloud)
            let response = try await client.complete(system: selectionPrompt.system, user: selectionPrompt.user)
            
            if let selectedIDs = Self.parseSkillSelection(response), !selectedIDs.isEmpty {
                let selected = skills.filter { selectedIDs.contains($0.id) }
                if !selected.isEmpty {
                    return Array(selected.prefix(3))
                }
            }
        } catch {
            Log.knowledge.warning("Skill selection LLM failed, using heuristic fallback: \(error.localizedDescription)")
        }
        
        return Self.heuristicSkillSelection(query: query, scope: scope, skills: skills)
    }
    
    private func routeRequest(query: String, scope: KnowledgeQAScope, skills: [Skill]) -> KnowledgeAgentRoute {
        let queryLower = query.lowercased()
        
        let hasMultiSessionSkill = skills.contains {
            $0.id == "mac_kb_collection_analysis" || $0.id == "mac_kb_timeline_qa"
        }
        
        let isInventory = skills.contains { $0.id == "mac_kb_session_inventory" }
            || queryLower.contains("how many") || queryLower.contains("list all")
            || queryLower.contains("which sessions")
        
        let isSingleSession = scope.sessionIDs.count == 1
        let hasTranscriptSkill = skills.contains { $0.id == "mac_kb_session_transcript" }
        
        if isInventory {
            return .inventory
        }
        
        if isSingleSession && hasTranscriptSkill && !hasMultiSessionSkill {
            return .simpleQA
        }
        
        if hasMultiSessionSkill {
            return .complex
        }
        
        return .simpleQA
    }
    
    private func executeSimpleQA(
        _ request: KnowledgeQARequest,
        skills: [Skill],
        continuation: AsyncStream<KnowledgeAnswerEvent>.Continuation
    ) async throws {
        let executor = KnowledgeToolExecutor(scope: scope, originFilter: originFilter)
        
        var hits: [KnowledgeSourceRef] = []
        let searchResult = try await executor.execute(
            toolName: "knowledge.search",
            arguments: ["query": request.queryText, "limit": 8]
        )
        
        if case let .success(data) = searchResult,
           let citations = data["citations"] as? [[String: Any]] {
            hits = citations.compactMap { Self.parseCitation($0) }
        }
        
        try Task.checkCancellation()
        
        if hits.isEmpty {
            let message = KnowledgeQAService.insufficientEvidenceMessage(scope: request.scope)
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
        
        let context = KnowledgeQAService.buildContext(hits: hits.compactMap { Self.citationToHit($0) }, maxChars: 10_000)
        let system = KnowledgeQAService.systemPrompt(mode: request.answerMode, scope: request.scope, originFilter: originFilter)
        let user = KnowledgeQAService.userPrompt(query: request.queryText, context: context, history: request.history)
        
        let answerText: String
        do {
            let client = try await Self.makeTextClient(allowCloud: allowCloud)
            answerText = try await client.complete(system: system, user: user)
        } catch {
            let fallback = KnowledgeQAService.excerptFallback(query: request.queryText, hits: hits.compactMap { Self.citationToHit($0) })
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
        let executor = KnowledgeToolExecutor(scope: scope, originFilter: originFilter)
        let client = try await Self.makeTextClient(allowCloud: allowCloud)
        
        var conversationHistory: [String] = []
        var citations: [KnowledgeSourceRef] = []
        
        let systemPrompt = await Self.agentSystemPrompt(skills: skills, scope: scope)
        let initialUser = Self.agentInitialUserPrompt(query: request.queryText, history: request.history)
        
        conversationHistory.append("User: \(initialUser)")
        
        for round in 1...maxRounds {
            try Task.checkCancellation()
            
            let thinking = conversationHistory.joined(separator: "\n\n")
            let response = try await client.complete(system: systemPrompt, user: thinking)
            
            conversationHistory.append("Assistant: \(response)")
            
            let parsed = Self.parseToolCalls(response)
            
            if parsed.toolCalls.isEmpty {
                continuation.yield(.status("Composing final answer…"))
                
                let context = Self.buildContextFromCitations(citations, maxChars: 10_000)
                let finalSystem = KnowledgeQAService.systemPrompt(mode: request.answerMode, scope: request.scope, originFilter: originFilter)
                let finalUser = KnowledgeQAService.userPrompt(query: request.queryText, context: context, history: request.history)
                
                let answerText = try await client.complete(system: finalSystem, user: finalUser)
                
                continuation.yield(.citations(citations))
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
                        citations.append(contentsOf: cits.compactMap { Self.parseCitation($0) })
                    }
                    let observation = "Tool \(toolCall.name) returned: \(Self.formatDict(data))"
                    observations.append(observation)
                    
                case let .error(message):
                    observations.append("Tool \(toolCall.name) error: \(message)")
                    
                case let .control(control):
                    switch control {
                    case let .finish(acceptedRefs):
                        shouldFinish = true
                        observations.append("finish_with_evidence called with \(acceptedRefs.count) refs")
                        
                    case let .clarify(question):
                        continuation.yield(.failed("Need clarification: \(question)"))
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
        
        continuation.yield(.citations(citations))
        continuation.yield(.status("Composing final answer…"))
        
        let context = Self.buildContextFromCitations(citations, maxChars: 10_000)
        let finalSystem = KnowledgeQAService.systemPrompt(mode: request.answerMode, scope: request.scope, originFilter: originFilter)
        let finalUser = KnowledgeQAService.userPrompt(query: request.queryText, context: context, history: request.history)
        
        let answerText = try await client.complete(system: finalSystem, user: finalUser)
        
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
        // Must use legacy RAG path — KnowledgeQAService.answer defaults to this agent runtime.
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        let stream = service.legacyAnswer(request)
        for await event in stream {
            continuation.yield(event)
        }
        continuation.finish()
    }
    
    @MainActor
    private static func makeTextClient(allowCloud: Bool) async throws -> any LLMTextClient {
        try await KnowledgeQAService.makeTextClient(allowCloud: allowCloud)
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
        
        if scope.sessionIDs.count == 1,
           let skill = skills.first(where: { $0.id == "mac_kb_session_transcript" }) {
            return [skill]
        }
        
        if let skill = skills.first(where: { $0.id == "mac_kb_content_qa" }) {
            return [skill]
        }
        
        return skills.prefix(1).map { $0 }
    }
    
    private static func skillSelectionPrompt(query: String, scope: KnowledgeQAScope, skills: [Skill]) -> (system: String, user: String) {
        let skillList = skills.map { skill in
            let summary = skill.metadata?.selectionSummary ?? skill.description
            return "- \(skill.id): \(summary)"
        }.joined(separator: "\n")
        
        let system = """
        You are a skill selector for a knowledge base assistant.
        Select up to 3 skills that best match the user's query.
        
        Available skills:
        \(skillList)
        
        Output ONLY a JSON array of skill IDs, nothing else. Example: ["mac_kb_content_qa", "mac_kb_timeline_qa"]
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
    
    private static func parseSkillSelection(_ response: String) -> [String]? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return array
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
        
        Think step-by-step and use tools to gather evidence before answering.
        """
    }
    
    private static func agentInitialUserPrompt(query: String, history: [KnowledgeMessage]) -> String {
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
        
        parts.append("Query: \(query)")
        parts.append("")
        parts.append("Use available tools to gather evidence, then call finish_with_evidence.")
        
        return parts.joined(separator: "\n")
    }
    
    private static func parseToolCalls(_ response: String) -> (toolCalls: [ParsedToolCall], thinking: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let jsonPattern = #"\{[^}]*"tool_calls"[^}]*\[[^\]]*\][^}]*\}"#
        if let regex = try? NSRegularExpression(pattern: jsonPattern, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) {
            let jsonStr = String(trimmed[Range(match.range, in: trimmed)!])
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
    
    private static func parseCitation(_ dict: [String: Any]) -> KnowledgeSourceRef? {
        guard let id = dict["id"] as? String,
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
            chunkIndex: nil,
            language: nil,
            speaker: dict["speaker"] as? String,
            snippet: dict["snippet"] as? String
        )
    }
    
    private static func citationToHit(_ ref: KnowledgeSourceRef) -> SessionSearchHit? {
        guard let sessionID = ref.sessionUUID else { return nil }
        return SessionSearchHit(
            sessionID: sessionID,
            title: ref.title,
            unitID: 0,
            kind: .transcriptChunk,
            start: ref.startTime,
            end: ref.endTime,
            speakerLabels: ref.speaker.map { [$0] } ?? [],
            text: ref.snippet ?? "",
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
