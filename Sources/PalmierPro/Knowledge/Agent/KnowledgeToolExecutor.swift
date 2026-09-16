import Foundation

/// Executes knowledge agent tools by calling existing app services.
/// All implementations must respect origin visibility and return Sendable results.
struct KnowledgeToolExecutor: Sendable {
    let scope: KnowledgeQAScope
    let originFilter: Set<KnowledgeSourceOrigin>?
    
    func execute(toolName: String, arguments: [String: Any]) async throws -> KnowledgeToolResult {
        switch toolName {
        case "knowledge.search":
            return try await knowledgeSearch(arguments)
        case "session.list":
            return try await sessionList(arguments)
        case "knowledge.get_session_metadata":
            return try await knowledgeGetSessionMetadata(arguments)
        case "session.get_summary":
            return try await sessionGetSummary(arguments)
        case "session.get_segments":
            return try await sessionGetSegments(arguments)
        case "session.search_segments":
            return try await sessionSearchSegments(arguments)
        case "session.get_timeline":
            return try await sessionGetTimeline(arguments)
        case "knowledge.compare_sessions":
            return try await knowledgeCompareSessions(arguments)
        case "finish_with_evidence":
            return finishWithEvidence(arguments)
        case "ask_clarification":
            return askClarification(arguments)
        default:
            throw KnowledgeToolError.unknownTool(toolName)
        }
    }
    
    private func knowledgeSearch(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let query = args["query"] as? String else {
            throw KnowledgeToolError.missingParameter("query")
        }
        let sessionIDs = (args["session_ids"] as? [String])?.compactMap { UUID(uuidString: $0) }
        let limit = args["limit"] as? Int ?? 8
        
        let searchScope: KnowledgeQAScope
        if let sessionIDs, !sessionIDs.isEmpty {
            searchScope = KnowledgeQAScope.fromSelection(sessionIDs)
        } else {
            searchScope = scope
        }
        
        let filter = await MainActor.run { () -> SessionSearchFilter in
            let signedIn = AccountService.shared.isSignedIn
            switch searchScope {
            case .all:
                return SessionSearchFilter.visible(isSignedIn: signedIn, uiFilter: originFilter, limit: limit)
            case let .session(id):
                return SessionSearchFilter.visible(isSignedIn: signedIn, sessionID: id, uiFilter: originFilter, limit: limit)
            case let .sessions(ids):
                return SessionSearchFilter.visible(isSignedIn: signedIn, sessionIDs: Set(ids), uiFilter: originFilter, limit: limit)
            }
        }
        
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        var hits = try await service.transcriptSearch(query: query, filter: filter)
        if hits.isEmpty {
            hits = try await service.search(query: query, filter: filter)
        }
        
        let citations = hits.map { KnowledgeQAService.citation(from: $0) }
        return .success([
            "hits": hits.count,
            "citations": citations.map { citationToDict($0) },
        ])
    }
    
    private func sessionList(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        let query = args["query"] as? String
        let typeFilter = args["type"] as? String
        let originArg = args["origin"] as? String
        let dateFrom = args["date_from"] as? String
        let dateTo = args["date_to"] as? String
        let limit = args["limit"] as? Int ?? 20
        
        let sessions = await MainActor.run { WorkbenchStore.shared.sessions }
        let signedIn = await MainActor.run { AccountService.shared.isSignedIn }
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: signedIn, uiFilter: originFilter)
        
        var filtered = sessions.filter { session in
            let origin = KnowledgeSourceOrigin.resolve(
                isCloudStorage: session.storage == .cloud,
                hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
            )
            return allowed.contains(origin)
        }
        
        if let query, !query.isEmpty {
            filtered = filtered.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        
        if let typeFilter, !typeFilter.isEmpty {
            let sourceType = KnowledgeSourceType(rawValue: typeFilter)
            filtered = filtered.filter { KnowledgeSourceType.from(sessionType: $0.sessionType) == sourceType }
        }
        
        if let originArg, originArg != "all" {
            let targetOrigin = KnowledgeSourceOrigin(rawValue: originArg)
            filtered = filtered.filter { session in
                let origin = KnowledgeSourceOrigin.resolve(
                    isCloudStorage: session.storage == .cloud,
                    hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
                )
                return origin == targetOrigin
            }
        }
        
        if let dateFrom {
            if let date = ISO8601DateFormatter().date(from: dateFrom) {
                filtered = filtered.filter { $0.modifiedAt >= date }
            }
        }
        
        if let dateTo {
            if let date = ISO8601DateFormatter().date(from: dateTo) {
                filtered = filtered.filter { $0.modifiedAt <= date }
            }
        }
        
        let sorted = filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        let results = sorted.prefix(limit).map { session in
            sessionToDict(session)
        }
        
        return .success([
            "count": results.count,
            "sessions": results,
        ])
    }
    
    private func knowledgeGetSessionMetadata(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStr = args["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDStr) else {
            throw KnowledgeToolError.invalidParameter("session_id must be valid UUID")
        }
        
        guard let session = await MainActor.run(body: { WorkbenchStore.shared.sessions.first { $0.id == sessionID } }) else {
            return .error("Session not found")
        }
        
        return .success(sessionToDict(session))
    }
    
    private func sessionGetSummary(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStr = args["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDStr) else {
            throw KnowledgeToolError.invalidParameter("session_id must be valid UUID")
        }
        
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        guard let summary = try await service.sessionSummary(id: sessionID) else {
            return .error("Session not found or no summary available")
        }
        
        return .success([
            "session_id": sessionID.uuidString,
            "title": summary.title,
            "tag": summary.tag as Any,
            "summary_markdown": summary.markdown as Any,
        ])
    }
    
    private func sessionGetSegments(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStr = args["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDStr) else {
            throw KnowledgeToolError.invalidParameter("session_id must be valid UUID")
        }
        
        let start = args["start"] as? Double
        let end = args["end"] as? Double
        let limit = args["limit"] as? Int ?? 20
        
        let filter = SessionSearchFilter(sessionID: sessionID, start: start, end: end, limit: limit)
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        
        let hits: [SessionSearchHit]
        if let start, let end {
            hits = try await service.transcriptContext(sessionID: sessionID, start: start, end: end, pad: 0)
        } else {
            hits = try await service.transcriptLexicalSearch(query: "", filter: filter)
        }
        
        let segments = hits.map { hit in
            Self.hitToDict(hit)
        }
        
        return .success([
            "session_id": sessionID.uuidString,
            "segment_count": segments.count,
            "segments": segments,
        ])
    }
    
    private func sessionSearchSegments(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStrs = args["session_ids"] as? [String] else {
            throw KnowledgeToolError.missingParameter("session_ids")
        }
        guard let query = args["query"] as? String else {
            throw KnowledgeToolError.missingParameter("query")
        }
        
        let sessionIDs = sessionIDStrs.compactMap { UUID(uuidString: $0) }
        guard !sessionIDs.isEmpty else {
            throw KnowledgeToolError.invalidParameter("session_ids must contain valid UUIDs")
        }
        
        let limit = args["limit"] as? Int ?? 8
        let searchScope = KnowledgeQAScope.fromSelection(sessionIDs)
        
        let filter = await MainActor.run { () -> SessionSearchFilter in
            let signedIn = AccountService.shared.isSignedIn
            switch searchScope {
            case .all:
                return SessionSearchFilter.visible(isSignedIn: signedIn, uiFilter: originFilter, limit: limit)
            case let .session(id):
                return SessionSearchFilter.visible(isSignedIn: signedIn, sessionID: id, uiFilter: originFilter, limit: limit)
            case let .sessions(ids):
                return SessionSearchFilter.visible(isSignedIn: signedIn, sessionIDs: Set(ids), uiFilter: originFilter, limit: limit)
            }
        }
        
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let hits = try await service.transcriptSearch(query: query, filter: filter)
        
        let results = hits.map { Self.hitToDict($0) }
        return .success([
            "hit_count": results.count,
            "hits": results,
        ])
    }
    
    private func sessionGetTimeline(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStr = args["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDStr) else {
            throw KnowledgeToolError.invalidParameter("session_id must be valid UUID")
        }
        
        let bucketSeconds = args["bucket_seconds"] as? Int ?? 60
        
        let filter = SessionSearchFilter(sessionID: sessionID, limit: 500)
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let hits = try await service.transcriptLexicalSearch(query: "", filter: filter)
        
        let buckets = Self.bucketTimeline(hits: hits, bucketSeconds: Double(bucketSeconds))
        
        return .success([
            "session_id": sessionID.uuidString,
            "bucket_seconds": bucketSeconds,
            "bucket_count": buckets.count,
            "buckets": buckets,
        ])
    }
    
    private func knowledgeCompareSessions(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let sessionIDStrs = args["session_ids"] as? [String] else {
            throw KnowledgeToolError.missingParameter("session_ids")
        }
        
        let sessionIDs = sessionIDStrs.compactMap { UUID(uuidString: $0) }
        guard sessionIDs.count >= 2 else {
            throw KnowledgeToolError.invalidParameter("session_ids must contain at least 2 valid UUIDs")
        }
        
        let focusQuery = args["focus_query"] as? String
        let mode = args["mode"] as? String ?? "themes"
        
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        var comparisons: [[String: Any]] = []
        
        for sessionID in sessionIDs {
            guard let summary = try await service.sessionSummary(id: sessionID) else { continue }
            
            var sessionData: [String: Any] = [
                "session_id": sessionID.uuidString,
                "title": summary.title,
                "summary": summary.markdown as Any,
            ]
            
            if let focusQuery, !focusQuery.isEmpty {
                let filter = SessionSearchFilter.visible(
                    isSignedIn: await MainActor.run { AccountService.shared.isSignedIn },
                    sessionID: sessionID,
                    uiFilter: originFilter,
                    limit: 3
                )
                let hits = try await service.transcriptSearch(query: focusQuery, filter: filter)
                sessionData["focus_hits"] = hits.map { Self.hitToDict($0) }
            }
            
            comparisons.append(sessionData)
        }
        
        return .success([
            "mode": mode,
            "session_count": comparisons.count,
            "comparisons": comparisons,
        ])
    }
    
    private func finishWithEvidence(_ args: [String: Any]) -> KnowledgeToolResult {
        guard let acceptedRefs = args["accepted_refs"] as? [String] else {
            return .error("accepted_refs must be an array of citation IDs")
        }
        return .control(.finish(acceptedRefs: acceptedRefs))
    }
    
    private func askClarification(_ args: [String: Any]) -> KnowledgeToolResult {
        guard let question = args["question"] as? String, !question.isEmpty else {
            return .error("question must be a non-empty string")
        }
        return .control(.clarify(question: question))
    }
    
    static func bucketTimeline(hits: [SessionSearchHit], bucketSeconds: Double) -> [[String: Any]] {
        guard !hits.isEmpty, bucketSeconds > 0 else { return [] }
        
        var buckets: [[String: Any]] = []
        var currentBucket: [SessionSearchHit] = []
        var bucketStart = 0.0
        
        let sorted = hits.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        
        for hit in sorted {
            let hitStart = hit.start ?? 0
            let hitBucket = floor(hitStart / bucketSeconds) * bucketSeconds
            
            if currentBucket.isEmpty {
                bucketStart = hitBucket
                currentBucket.append(hit)
            } else if hitBucket == bucketStart {
                currentBucket.append(hit)
            } else {
                let bucketEnd = bucketStart + bucketSeconds
                buckets.append([
                    "start": bucketStart,
                    "end": bucketEnd,
                    "segment_count": currentBucket.count,
                    "segments": currentBucket.map { Self.hitToDict($0) },
                ])
                bucketStart = hitBucket
                currentBucket = [hit]
            }
        }
        
        if !currentBucket.isEmpty {
            let bucketEnd = bucketStart + bucketSeconds
            buckets.append([
                "start": bucketStart,
                "end": bucketEnd,
                "segment_count": currentBucket.count,
                "segments": currentBucket.map { Self.hitToDict($0) },
            ])
        }
        
        return buckets
    }
    
    private func sessionToDict(_ session: WorkbenchSession) -> [String: Any] {
        let origin = KnowledgeSourceOrigin.resolve(
            isCloudStorage: session.storage == .cloud,
            hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
        )
        let duration = session.duration ?? 0
        return [
            "session_id": session.id.uuidString,
            "title": session.title,
            "type": session.sessionType.rawValue,
            "duration": duration,
            "modified_at": ISO8601DateFormatter().string(from: session.modifiedAt),
            "origin": origin.rawValue,
            "has_transcript": session.transcript != nil,
        ]
    }
    
    private func citationToDict(_ ref: KnowledgeSourceRef) -> [String: Any] {
        var dict: [String: Any] = [
            "id": ref.id,
            "source_id": ref.sourceID,
            "source_type": ref.sourceType,
            "title": ref.title,
        ]
        if let uri = ref.uri { dict["uri"] = uri }
        if let page = ref.page { dict["page"] = page }
        if let startTime = ref.startTime { dict["start_time"] = startTime }
        if let endTime = ref.endTime { dict["end_time"] = endTime }
        if let speaker = ref.speaker { dict["speaker"] = speaker }
        if let snippet = ref.snippet { dict["snippet"] = snippet }
        return dict
    }
    
    private static func hitToDict(_ hit: SessionSearchHit) -> [String: Any] {
        var dict: [String: Any] = [
            "session_id": hit.sessionID.uuidString,
            "title": hit.title,
            "text": hit.text,
            "score": hit.score,
        ]
        if let start = hit.start { dict["start"] = start }
        if let end = hit.end { dict["end"] = end }
        if !hit.speakerLabels.isEmpty { dict["speakers"] = hit.speakerLabels }
        if let snippet = hit.snippet { dict["snippet"] = snippet }
        return dict
    }
}

enum KnowledgeToolResult: @unchecked Sendable {
    case success([String: Any])
    case error(String)
    case control(KnowledgeToolControl)
}

enum KnowledgeToolControl: Sendable {
    case finish(acceptedRefs: [String])
    case clarify(question: String)
}

enum KnowledgeToolError: LocalizedError, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case invalidParameter(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidParameter(let msg):
            return "Invalid parameter: \(msg)"
        }
    }
}
