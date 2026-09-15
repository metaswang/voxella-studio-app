import Foundation

/// P0 Knowledge QA pipeline: Hybrid Search TopK → Context → Answer LLM.
/// Reranker / Answerability / MMR land in P1.
///
/// Streaming (P0): `LLMTextClient.complete` returns the full answer, then
/// `chunkForStreaming` emits character chunks so the chat UI can animate.
/// This is **not** token SSE. Real streaming is deferred (P1+); do not block P0 on it.
struct KnowledgeQAService: Sendable {
    var topK: Int = 8
    var maxContextChars: Int = 10_000
    var chatStore: KnowledgeChatStore = .shared
    var useAgentRuntime: Bool = true

    func answer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
        if useAgentRuntime {
            let runtime = KnowledgeAgentRuntime(
                scope: request.scope,
                originFilter: request.originFilter,
                allowCloud: request.allowCloud
            )
            return runtime.answer(request)
        } else {
            return legacyAnswer(request)
        }
    }
    
    func legacyAnswer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
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

        continuation.yield(.status("Searching knowledge…"))
        let hits = try await retrieve(query: query, scope: request.scope, originFilter: request.originFilter)
        try Task.checkCancellation()

        let citations = hits.map(Self.citation(from:))
        if hits.isEmpty {
            let message = Self.insufficientEvidenceMessage(scope: request.scope)
            continuation.yield(.citations([]))
            continuation.yield(.status("No evidence found"))
            for chunk in Self.chunkForStreaming(message) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(message))
            continuation.finish()
            return
        }

        continuation.yield(.citations(citations))
        continuation.yield(.status("Composing answer…"))

        let context = Self.buildContext(hits: hits, maxChars: maxContextChars)
        let system = Self.systemPrompt(mode: request.answerMode, scope: request.scope, originFilter: request.originFilter)
        let user = Self.userPrompt(query: query, context: context, history: request.history)

        let answerText: String
        do {
            answerText = try await generateAnswer(
                system: system,
                user: user,
                allowCloud: request.allowCloud
            )
        } catch {
            let fallback = Self.excerptFallback(query: query, hits: hits)
            continuation.yield(.status("Showing excerpts…"))
            for chunk in Self.chunkForStreaming(fallback) {
                try Task.checkCancellation()
                continuation.yield(.delta(chunk))
            }
            continuation.yield(.finished(fallback))
            continuation.finish()
            return
        }

        try Task.checkCancellation()
        continuation.yield(.status("Showing answer…"))
        for chunk in Self.chunkForStreaming(answerText) {
            try Task.checkCancellation()
            continuation.yield(.delta(chunk))
            try await Task.sleep(for: .milliseconds(12))
        }
        continuation.yield(.finished(answerText))
        continuation.finish()
    }

    private func retrieve(query: String, scope: KnowledgeQAScope, originFilter: Set<KnowledgeSourceOrigin>?) async throws -> [SessionSearchHit] {
        let filter = await MainActor.run { () -> SessionSearchFilter in
            let signedIn = AccountService.shared.isSignedIn
            let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: signedIn, uiFilter: originFilter)
            switch scope {
            case .all:
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    uiFilter: originFilter,
                    limit: topK
                )
            case let .session(sessionID):
                let session = WorkbenchStore.shared.sessions.first(where: { $0.id == sessionID })
                let origin = KnowledgeSourceOrigin.resolve(
                    isCloudStorage: session?.storage == .cloud,
                    hasRemoteSessionID: session?.remoteSessionID != nil || session?.isRemoteOnly == true
                )
                guard allowed.contains(origin) else {
                    return SessionSearchFilter(sessionID: sessionID, sourceOrigins: [], limit: topK)
                }
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    sessionID: sessionID,
                    uiFilter: originFilter,
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
                    return SessionSearchFilter(sessionIDs: [], sourceOrigins: [], limit: topK)
                }
                return SessionSearchFilter.visible(
                    isSignedIn: signedIn,
                    sessionIDs: visibleIDs,
                    uiFilter: originFilter,
                    limit: topK
                )
            }
        }
        if filter.sourceOrigins?.isEmpty == true {
            return []
        }
        if filter.sessionIDs?.isEmpty == true {
            return []
        }
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        var hits = try await service.transcriptSearch(query: query, filter: filter)
        if hits.isEmpty {
            hits = try await service.search(query: query, filter: filter)
        }
        switch scope {
        case .all:
            break
        case let .session(sessionID):
            hits = hits.filter { $0.sessionID == sessionID }
        case let .sessions(ids):
            let allowed = Set(ids)
            hits = hits.filter { allowed.contains($0.sessionID) }
        }
        return Array(hits.prefix(topK))
    }

    private func generateAnswer(system: String, user: String, allowCloud: Bool) async throws -> String {
        let client = try await Self.makeTextClient(allowCloud: allowCloud)
        return try await client.complete(system: system, user: user)
    }

    /// Cloud/BYOK credentials are independent of the WeMM download gate.
    /// Retrieval still requires local WeMM even when the answer LLM is hosted.
    /// P0: allowCloud = true when hosted transport is available (no settings toggle yet).
    @MainActor
    static func makeTextClient(allowCloud: Bool) async throws -> any LLMTextClient {
        switch AITransportPolicy.current {
        case .unavailable:
            throw KnowledgeQAError.llmUnavailable
        case .hosted:
            guard allowCloud else { throw KnowledgeQAError.cloudDisabled }
            return try await AITransportPolicy.makeTextClient(for: .chat)
        case .byok:
            return try await AITransportPolicy.makeTextClient(for: .chat)
        }
    }

    static func buildContext(hits: [SessionSearchHit], maxChars: Int) -> String {
        var used = 0
        var blocks: [String] = []
        for (index, hit) in hits.enumerated() {
            let start = hit.start.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
            let end = hit.end.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
            let speakers = hit.speakerLabels.isEmpty ? "—" : hit.speakerLabels.joined(separator: ", ")
            let body = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let block = """
            [\(index + 1)] session=\(hit.sessionID.uuidString) title=\(hit.title)
            time=\(start)–\(end) speakers=\(speakers)
            \(body)
            """
            if used + block.count > maxChars, !blocks.isEmpty { break }
            blocks.append(block)
            used += block.count
        }
        return blocks.joined(separator: "\n\n")
    }

    static func citation(from hit: SessionSearchHit) -> KnowledgeSourceRef {
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
            snippet: hit.snippet ?? String(hit.text.prefix(180))
        )
    }

    static func systemPrompt(mode: KnowledgeAnswerMode, scope: KnowledgeQAScope, originFilter: Set<KnowledgeSourceOrigin>?) -> String {
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
        If the excerpts are insufficient, say you could not find enough evidence and list the closest sources.
        Do not fabricate quotes, speakers, or timestamps.
        When helpful, cite sources as [n] matching the excerpt numbers.
        \(style)
        Reply in the same language as the user question when possible.
        """
    }

    static func userPrompt(query: String, context: String, history: [KnowledgeMessage]) -> String {
        var parts: [String] = []
        let recent = history.suffix(6)
        if !recent.isEmpty {
            parts.append("Conversation so far:")
            for message in recent {
                let role = message.role == .user ? "User" : "Assistant"
                parts.append("\(role): \(message.content)")
            }
            parts.append("")
        }
        parts.append("Evidence excerpts:")
        parts.append(context)
        parts.append("")
        parts.append("Question: \(query)")
        return parts.joined(separator: "\n")
    }

    static func insufficientEvidenceMessage(scope: KnowledgeQAScope) -> String {
        switch scope {
        case .all:
            return "I could not find enough indexed transcript evidence for that question across your knowledge base. Try a more specific phrase, or wait until sessions finish indexing."
        case .session:
            return "I could not find enough evidence in this session for that question. Try different wording, or confirm the session has finished indexing."
        case .sessions:
            return "I could not find enough evidence in the selected sessions for that question. Try different wording, or confirm those sessions have finished indexing."
        }
    }

    static func excerptFallback(query: String, hits: [SessionSearchHit]) -> String {
        var lines = [
            "I found related transcript excerpts, but the answer model is unavailable right now (sign in for hosted AI, or enable BYOK in Settings).",
            "",
            "Closest matches for “\(query)”:",
        ]
        for (index, hit) in hits.prefix(5).enumerated() {
            let time = hit.start.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
            let snippet = (hit.snippet ?? hit.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = snippet.count > 160 ? String(snippet.prefix(157)) + "…" : snippet
            lines.append("\(index + 1). \(hit.title) · \(time) — \(clipped)")
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

    var errorDescription: String? {
        switch self {
        case .llmUnavailable:
            "AI answering is unavailable. Sign in for hosted AI or configure BYOK in Settings → AI."
        case .cloudDisabled:
            "Cloud answering is disabled for this request."
        case .sessionNotVisible:
            "Sign in to ask about this cloud session."
        }
    }
}
