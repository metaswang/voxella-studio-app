import Foundation

/// One authorization boundary for all read-only knowledge tools. The immutable
/// workspace is shared by the main agent and bounded source workers.
struct KnowledgeToolExecutor: Sendable {
    let scope: KnowledgeQAScope
    let originFilter: Set<KnowledgeSourceOrigin>?
    let retrievalService: KnowledgeRetrievalService
    var requestID: UUID = UUID()
    var workspace: KnowledgeEvidenceWorkspace? = nil
    var skills: [Skill] = []

    @concurrent
    func executeNative(name: String, inputJSON: String) async throws -> KnowledgeToolObservation {
        guard let definition = KnowledgeToolRegistry.allTools.first(where: { $0.nativeName == name }) else {
            return .error("Unknown or unauthorized knowledge tool: \(name)")
        }
        do {
            guard let args = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any] else {
                return .error("Arguments must be a JSON object")
            }
            try definition.validate(args)
            if let workspace { try await workspace.snapshot.validate() }
            switch definition.name {
            case "read_payload":
                guard let workspace, let handle = args["payload_ref"] as? String else { return .error("Missing payload") }
                let allowed = scope == workspace.snapshot.scope ? nil : Set(await visibleSessions().map(\.id))
                return await workspace.readPayload(handle, offset: args["cursor"] as? Int ?? 0, allowedSources: allowed)
            case "analysis.update":
                guard let workspace else { return .error("No evidence workspace") }
                return try await workspace.updateAnalysis(KnowledgeJSON.encode(args))
            case "read_skill":
                guard let skill = skills.first(where: { $0.id == args["skill_id"] as? String }),
                      KnowledgeToolRegistry.validateSkill(skill) else { return .error("Unknown or unauthorized skill") }
                let text = try String(contentsOf: skill.path, encoding: .utf8)
                let body = SkillFrontmatter.parse(text).body
                guard body.count <= 16_000 else { return .error("Skill exceeds the supported method size") }
                return await record(["skill_id": skill.id, "method": body,
                                     "allowed_tools": skill.metadata?.allowedTools ?? [],
                                     "native_name_mapping": Dictionary(uniqueKeysWithValues: KnowledgeToolRegistry.allTools.map { ($0.name, $0.nativeName) }),
                                     "permissions": "Method guidance only; main-agent core permissions remain unchanged"])
            default:
                let result = try await execute(toolName: definition.name, arguments: args)
                if let workspace { try await workspace.snapshot.validate() }
                switch result {
                case .success(let data): return await record(data)
                case .error(let message): return .error(message)
                case .control(.clarify(let question)):
                    return await record(["clarification_question": question])
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return .error(error.localizedDescription) }
    }

    private func record(_ data: [String: Any]) async -> KnowledgeToolObservation {
        if let workspace { return await workspace.record(KnowledgeJSON.encode(data)) }
        return KnowledgeToolObservation(json: KnowledgeJSON.encode(data), isError: false,
                                        citations: (data["citations"] as? [[String: Any]] ?? []).compactMap(KnowledgeJSON.reference))
    }

    func execute(toolName: String, arguments args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let definition = KnowledgeToolRegistry.tool(named: toolName) else { throw KnowledgeToolError.unknownTool(toolName) }
        try definition.validate(args)
        switch toolName {
        case "knowledge.search", "session.search_segments": return try await search(args)
        case "session.list", "session.aggregate": return try await inventory(args, aggregate: toolName == "session.aggregate")
        case "knowledge.get_session_metadata":
            let session = try await session(args)
            return .success(await metadata(session))
        case "session.get_summary": return try await summary(args)
        case "session.get_segments", "session.get_timeline", "session.get_speakers": return try await read(args, tool: toolName)
        case "knowledge.compare_sessions": return try await compare(args)
        case "knowledge.search_sources": return try await discover(args)
        case "ask_clarification":
            guard let question = args["question"] as? String, !question.isEmpty else { throw KnowledgeToolError.missingParameter("question") }
            return .control(.clarify(question: question))
        default: throw KnowledgeToolError.unknownTool(toolName)
        }
    }

    private func visibleSessions() async -> [WorkbenchSession] {
        if let workspace { return workspace.snapshot.sessions.filter { scope == .all || scope.sessionIDs.contains($0.id) } }
        return await KnowledgeScopeSnapshot.capture(scope: scope, origins: originFilter).sessions
    }

    private func session(_ args: [String: Any]) async throws -> WorkbenchSession {
        guard let raw = args["session_id"] as? String, let id = UUID(uuidString: raw) else {
            throw KnowledgeToolError.invalidParameter("session_id must be a valid UUID")
        }
        guard let found = await visibleSessions().first(where: { $0.id == id }) else {
            throw KnowledgeToolError.invalidParameter("Session is unavailable or outside the authorized scope")
        }
        return found
    }

    private func sourceIDs(_ args: [String: Any], minimum: Int = 1) async throws -> [UUID]? {
        guard let strings = args["session_ids"] as? [String] else { return nil }
        let ids = strings.compactMap(UUID.init(uuidString:))
        guard ids.count == strings.count, Set(ids).count == ids.count, ids.count >= minimum else {
            throw KnowledgeToolError.invalidParameter("session_ids must contain unique valid UUIDs")
        }
        let visible = Set(await visibleSessions().map(\.id))
        guard ids.allSatisfy({ (scope == .all || scope.sessionIDs.contains($0)) && (workspace == nil || visible.contains($0)) }) else {
            throw KnowledgeToolError.invalidParameter("Session is unavailable or outside the authorized scope")
        }
        return ids
    }

    @concurrent
    func metadata(_ session: WorkbenchSession, probe: Bool = true) async -> [String: Any] {
        let facts = probe ? await KnowledgeMediaDurationCache.shared.facts(for: session) : .from(session)
        if probe {
            let store = await MainActor.run { SessionIndexCoordinator.shared.searchService.store }
            try? await store.patchMediaFacts(sessionID: session.id, mediaDuration: facts.mediaDuration,
                provenance: facts.provenance, lastSpokenEnd: facts.lastSpokenEnd,
                transcribedStart: facts.transcribedStart, transcribedEnd: facts.transcribedEnd)
        }
        let material = KnowledgeTranscriptMaterial.from(session)
        var data: [String: Any] = [
            "session_id": session.id.uuidString, "title": session.title,
            "type": KnowledgeSourceType.from(sessionType: session.sessionType).rawValue,
            "origin": KnowledgeScopeSnapshot.origin(session).rawValue,
            "created_at": ISO8601DateFormatter().string(from: session.createdAt),
            "modified_at": ISO8601DateFormatter().string(from: session.modifiedAt),
            "date_semantics": "source created/imported and modified; recording date is unknown",
            "source_generation": KnowledgeScopeSnapshot.generation(session),
            "media_duration_sec": facts.mediaDuration as Any? ?? NSNull(),
            "media_duration_provenance": facts.provenance,
            "last_spoken_end_sec": facts.lastSpokenEnd as Any? ?? NSNull(),
            "transcribed_range": ["start": facts.transcribedStart as Any? ?? NSNull(),
                                  "end": facts.transcribedEnd as Any? ?? NSNull(), "coordinate": "source_seconds"],
            "has_transcript": material != nil || session.transcript != nil || session.dubTranscript != nil,
            "has_summary": session.summaryMarkdown?.isEmpty == false,
            "capabilities": ["metadata": true, "summary": session.summaryMarkdown?.isEmpty == false,
                             "direct_transcript": material != nil,
                             "lexical": true, "semantic": LocalModelManager.isInstalled(.weMMEmbedding2B4Bit),
                             "reranker": LocalModelManager.isInstalled(.qwen3Reranker06B4Bit)],
        ]
        let ref = reference(session, kind: "sessionCard", chunk: -1, text: KnowledgeJSON.encode(data))
        data["citations"] = [KnowledgeJSON.citation(ref)]
        return data
    }

    private func filteredInventory(_ args: [String: Any]) async throws -> [WorkbenchSession] {
        var sessions = await visibleSessions()
        if let query = args["query"] as? String, !query.isEmpty {
            sessions = sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if let raw = args["type"] as? String, raw != "all" {
            guard let type = KnowledgeSourceType(rawValue: raw) else { throw KnowledgeToolError.invalidParameter("Unknown source type") }
            sessions = sessions.filter { KnowledgeSourceType.from(sessionType: $0.sessionType) == type }
        }
        if let raw = args["origin"] as? String, raw != "all" {
            guard let origin = KnowledgeSourceOrigin(rawValue: raw) else { throw KnowledgeToolError.invalidParameter("Unknown origin") }
            sessions = sessions.filter { KnowledgeScopeSnapshot.origin($0) == origin }
        }
        let field = args["date_field"] as? String ?? "created"
        guard ["created", "modified"].contains(field) else { throw KnowledgeToolError.invalidParameter("date_field must be created or modified") }
        let from = try Self.date(args["date_from"] as? String)
        let to = try Self.date(args["date_to"] as? String)
        if let from, let to, from > to { throw KnowledgeToolError.invalidParameter("Reversed date range") }
        sessions = sessions.filter {
            let date = field == "created" ? $0.createdAt : $0.modifiedAt
            return (from == nil || date >= from!) && (to == nil || date <= to!)
        }
        return sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func date(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let result = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            throw KnowledgeToolError.invalidParameter("Invalid ISO8601 date: \(raw)")
        }
        return result
    }

    private func inventory(_ args: [String: Any], aggregate: Bool) async throws -> KnowledgeToolResult {
        let sessions = try await filteredInventory(args)
        let offset = args["cursor"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 32
        guard offset >= 0, offset <= sessions.count, limit > 0, limit <= 100 else { throw KnowledgeToolError.invalidParameter("Invalid inventory page") }
        var rows: [[String: Any]] = []
        for item in sessions.dropFirst(offset).prefix(limit) { rows.append(await metadata(item, probe: false)) }
        var data: [String: Any] = ["sessions": rows, "count": rows.count, "returned_count": rows.count,
                                  "total_count": sessions.count, "complete": offset + rows.count == sessions.count,
                                  "next_cursor": offset + rows.count < sessions.count ? offset + rows.count : NSNull(),
                                  "date_field": args["date_field"] as? String ?? "created",
                                  "citations": rows.flatMap { $0["citations"] as? [[String: Any]] ?? [] }]
        if aggregate {
            let facts = sessions.map { KnowledgeMediaFacts.from($0) }
            let known = facts.compactMap(\.mediaDuration)
            let groupBy = args["group_by"] as? String
            guard groupBy == nil || ["type", "origin"].contains(groupBy!) else { throw KnowledgeToolError.invalidParameter("Invalid group_by") }
            let sortBy = args["sort_by"] as? String ?? "created"
            guard ["created", "modified", "duration"].contains(sortBy) else { throw KnowledgeToolError.invalidParameter("Invalid sort_by") }
            let sorted = sessions.sorted {
                let lhs = sortBy == "duration" ? (KnowledgeMediaFacts.from($0).mediaDuration ?? -.infinity) :
                    (sortBy == "modified" ? $0.modifiedAt : $0.createdAt).timeIntervalSince1970
                let rhs = sortBy == "duration" ? (KnowledgeMediaFacts.from($1).mediaDuration ?? -.infinity) :
                    (sortBy == "modified" ? $1.modifiedAt : $1.createdAt).timeIntervalSince1970
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
            }
            var groups: [String: Int] = [:]
            for item in sessions {
                let key = groupBy == "type" ? KnowledgeSourceType.from(sessionType: item.sessionType).rawValue : KnowledgeScopeSnapshot.origin(item).rawValue
                groups[key, default: 0] += 1
            }
            let aggregate: [String: Any] = ["count": sessions.count, "media_duration_sum_sec": known.reduce(0, +),
                "duration_known_count": known.count, "duration_unknown_count": sessions.count - known.count,
                "group_by": groupBy as Any? ?? NSNull(), "groups": groupBy == nil ? [:] : groups,
                "sort_by": sortBy, "sorted_session_ids": sorted.dropFirst(offset).prefix(limit).map { $0.id.uuidString },
                "input_set_version": workspace?.snapshot.cacheNamespace ?? "live",
                "filters": args.filter { !["limit", "cursor"].contains($0.key) },
                "duration_policy": "source hints only; missing local media metadata counted as unknown", "semantic_count": false]
            data["aggregate"] = aggregate
            // Filters, grouping and the returned sort page are part of this
            // evidence identity; another aggregate must not reuse its citation.
            let aggregateJSON = KnowledgeJSON.encode(aggregate)
            let aggregateID = KnowledgeScopeSnapshot.digest(Data(aggregateJSON.utf8))
            let ref = KnowledgeSourceRef(sourceID: "aggregate:" + aggregateID,
                sourceType: "aggregate", title: "Visible source inventory", uri: nil, page: nil, startTime: nil,
                endTime: nil, parentID: nil, chunkIndex: -6, language: nil, speaker: nil,
                snippet: aggregateJSON, matchText: nil)
            data["citations"] = [KnowledgeJSON.citation(ref)]
        }
        return .success(data)
    }

    private func summary(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        let source = try await session(args)
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let indexed = source.summaryMarkdown == nil ? try await service.sessionSummary(id: source.id)?.markdown : nil
        guard let text = source.summaryMarkdown ?? indexed, !text.isEmpty else {
            return .success(["session_id": source.id.uuidString, "status": "unavailable", "summary_markdown": NSNull(), "complete": false])
        }
        let offset = args["cursor"] as? Int ?? 0
        guard offset >= 0, offset <= text.count else { throw KnowledgeToolError.invalidParameter("Invalid summary cursor") }
        let page = String(text.dropFirst(offset).prefix(8_000))
        let ref = reference(source, kind: "sessionSummary", chunk: -2_000_000 - offset, text: page)
        return .success(["session_id": source.id.uuidString, "summary_markdown": page, "generated_summary": true,
                         "returned_count": page.count, "total_count": text.count, "complete": offset + page.count == text.count,
                         "next_cursor": offset + page.count < text.count ? offset + page.count : NSNull(),
                         "citations": [KnowledgeJSON.citation(ref)]])
    }

    private func read(_ args: [String: Any], tool: String) async throws -> KnowledgeToolResult {
        let source = try await session(args)
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        let material = KnowledgeTranscriptMaterial.from(source)
        let segments = material?.segments
        let start = args["start"] as? Double
        let end = args["end"] as? Double
        guard (start == nil || start! >= 0), (end == nil || end! >= 0), (start == nil || end == nil || start! <= end!) else {
            throw KnowledgeToolError.invalidParameter("Invalid time range")
        }
        if tool == "session.get_speakers" {
            let indexed = try await service.speakerList(id: source.id)
            let speakers = Set((segments ?? []).compactMap(\.speaker) + indexed.map(\.displayName)).sorted()
            let ref = reference(source, kind: "speaker", chunk: -3, text: speakers.joined(separator: ", "))
            return .success(["speakers": speakers, "complete": true, "labels_available": !speakers.isEmpty,
                             "citations": [KnowledgeJSON.citation(ref)]])
        }
        let offset = args["cursor"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 80
        guard offset >= 0, limit > 0, limit <= 200 else { throw KnowledgeToolError.invalidParameter("Invalid transcript page") }
        let hits: [SessionSearchHit]
        let total: Int
        let pageOffset: Int
        if let segments {
            let allHits: [SessionSearchHit] = segments.enumerated().map { index, segment in
                return SessionSearchHit(sessionID: source.id, title: source.title, unitID: index, kind: .transcriptChunk,
                                 start: segment.start, end: segment.end, speakerLabels: segment.speaker.map { [$0] } ?? [],
                                 text: segment.text, score: 1, matchSource: "direct_read", snippet: segment.text,
                                 cueIDs: [], hasVideo: false, language: material?.language, quoteSpan: nil)
            }
            let speaker = args["speaker"] as? String
            let filtered = allHits.filter {
                (start == nil || ($0.end ?? 0) >= start!) && (end == nil || ($0.start ?? 0) <= end!) &&
                (speaker == nil || $0.speakerLabels.contains(speaker!))
            }
            let all = filtered.sorted {
                if $0.start == $1.start { return $0.unitID < $1.unitID }
                return ($0.start ?? 0) < ($1.start ?? 0)
            }
            hits = all
            total = all.count
            pageOffset = offset
        } else {
            var filter = await retrievalService.makeVisibleFilter(scope: .session(source.id), originFilter: originFilter)
            filter.limit = limit
            filter.start = start
            filter.end = end
            filter.speakerLabel = args["speaker"] as? String
            let indexed = try await service.store.transcriptPage(filter: filter, offset: offset)
            hits = indexed.hits
            total = indexed.total
            pageOffset = 0
        }
        guard offset <= total else { throw KnowledgeToolError.invalidParameter("Invalid transcript cursor") }
        if material == nil, total == 0 {
            return .success(["session_id": source.id.uuidString, "status": "unavailable", "segments": [],
                             "returned_count": 0, "complete": false,
                             "coverage_note": "No readable timed transcript is available for this range; this does not establish semantic absence."])
        }
        var page: [SessionSearchHit] = []
        var characters = 0
        for hit in hits.dropFirst(pageOffset).prefix(limit) {
            guard hit.text.count <= 16_000 else { throw KnowledgeToolError.invalidParameter("Transcript segment exceeds the supported page size") }
            if characters + hit.text.count > 16_000 { break }
            page.append(hit)
            characters += hit.text.count
        }
        var data: [String: Any] = ["session_id": source.id.uuidString, "segments": page.map(Self.hitToDict),
            "returned_count": page.count, "total_count": total,
            "complete": offset + page.count == total,
            "next_cursor": offset + page.count < total ? offset + page.count : NSNull(),
            "read_provenance": material?.provenance ?? "indexed_transcript_chunks",
            "completeness_semantics": "available transcript, not necessarily entire media",
            "returned_range": ["start": page.compactMap(\.start).min() as Any? ?? NSNull(), "end": page.compactMap(\.end).max() as Any? ?? NSNull()], "coverage": ["start": start as Any? ?? NSNull(), "end": end as Any? ?? NSNull(), "coordinate": "source_seconds"],
            "citations": page.map { hit in
                var ref = KnowledgeQAService.citation(from: hit)
                if let material { ref.chunkIndex = material.citationChunkBase + hit.unitID }
                return KnowledgeJSON.citation(ref)
            }]
        if tool == "session.get_timeline" {
            let bucket = args["bucket_seconds"] as? Int ?? 60
            guard bucket > 0 else { throw KnowledgeToolError.invalidParameter("bucket_seconds must be positive") }
            data["buckets"] = Self.bucketTimeline(hits: page, bucketSeconds: Double(bucket))
        }
        return .success(data)
    }

    private func search(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeToolError.invalidParameter("query must be non-empty")
        }
        let ids = try await sourceIDs(args)
        let limit = min(32, max(1, args["limit"] as? Int ?? 8))
        let result = try await retrievalService.search(KnowledgeRetrievalRequest(query: query,
            scope: ids.map(KnowledgeQAScope.fromSelection) ?? scope, originFilter: originFilter, resultLimit: limit,
            requestID: requestID, includeCatalog: false, retrievalPath: .agent,
            useGraph: args["use_graph"] as? Bool ?? (workspace == nil)))
        let visible = Set(await visibleSessions().map(\.id))
        let hits = result.hits.filter { workspace == nil || visible.contains($0.sessionID) }
        return .success(["hits": hits.count, "hit_count": hits.count,
            "segments": hits.map(Self.hitToDict), "complete": false, "candidate_set_only": true,
            "retrieval": ["hybrid_count": result.diagnostics.hybridHitCount,
                          "graph_count": result.diagnostics.graphHitCount, "graph_executed": result.diagnostics.graphAttempted,
                          "reranker": result.diagnostics.rerankerStatus.rawValue, "selected_count": hits.count,
                          "source_count": Set(hits.map(\.sessionID)).count],
            "citations": hits.map { KnowledgeJSON.citation(KnowledgeQAService.citation(from: $0)) }])
    }

    private func discover(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        let service = await MainActor.run { SessionIndexCoordinator.shared.searchService }
        var filter = await retrievalService.makeVisibleFilter(scope: scope, originFilter: originFilter)
        filter.limit = min(32, max(1, args["limit"] as? Int ?? 16))
        let cards = try await service.sessionSearch(query: args["query"] as? String ?? "", filter: filter)
        let visible = Set(await visibleSessions().map(\.id))
        var rows: [[String: Any]] = []
        for card in cards where visible.contains(card.sessionID) {
            if let source = await visibleSessions().first(where: { $0.id == card.sessionID }) {
                var row = await metadata(source, probe: false)
                row["match_source"] = card.matchSource
                rows.append(row)
            }
        }
        return .success(["sources": rows, "returned_count": rows.count, "complete": false,
                         "candidate_set_only": true, "citations": rows.flatMap { $0["citations"] as? [[String: Any]] ?? [] }])
    }

    private func compare(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let ids = try await sourceIDs(args, minimum: 2) else { throw KnowledgeToolError.missingParameter("session_ids") }
        guard ids.count <= 16 else { throw KnowledgeToolError.invalidParameter("Compare at most 16 sources per operation") }
        var rows: [[String: Any]] = []
        var citations: [[String: Any]] = []
        for id in ids {
            let result = try await summary(["session_id": id.uuidString])
            if case .success(var row) = result {
                if let query = args["focus_query"] as? String, !query.isEmpty,
                   case .success(let hits) = try await search(["session_ids": [id.uuidString], "query": query, "limit": 3]) {
                    row["focus_evidence"] = hits
                    citations += hits["citations"] as? [[String: Any]] ?? []
                }
                rows.append(row)
                citations += row["citations"] as? [[String: Any]] ?? []
            }
        }
        return .success(["comparisons": rows, "session_count": rows.count, "citations": citations,
                         "coverage_note": "Every requested source is retained; unavailable summaries remain unknown. Summaries do not verify exact decisions."])
    }

    private func reference(_ session: WorkbenchSession, kind: String, chunk: Int, text: String) -> KnowledgeSourceRef {
        KnowledgeSourceRef(sourceID: session.id.uuidString, sourceType: kind, title: session.title, uri: nil, page: nil,
                           startTime: nil, endTime: nil, parentID: nil, chunkIndex: chunk, language: nil,
                           speaker: nil, snippet: text, matchText: nil)
    }

    static func hitToDict(_ hit: SessionSearchHit) -> [String: Any] {
        ["session_id": hit.sessionID.uuidString, "text": hit.text, "start": hit.start as Any? ?? NSNull(),
         "end": hit.end as Any? ?? NSNull(), "speakers": hit.speakerLabels]
    }

    static func bucketTimeline(hits: [SessionSearchHit], bucketSeconds: Double) -> [[String: Any]] {
        guard bucketSeconds > 0 else { return [] }
        let grouped = Dictionary(grouping: hits) { floor(($0.start ?? 0) / bucketSeconds) * bucketSeconds }
        return grouped.keys.sorted().map { start in
            ["start": start, "end": start + bucketSeconds, "segment_count": grouped[start]!.count,
             "segments": grouped[start]!.map(hitToDict)]
        }
    }
}

enum KnowledgeToolResult: @unchecked Sendable {
    case success([String: Any])
    case error(String)
    case control(KnowledgeToolControl)
}

enum KnowledgeToolControl: Sendable { case clarify(question: String) }

enum KnowledgeToolError: LocalizedError, Sendable {
    case unknownTool(String), missingParameter(String), invalidParameter(String)
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .missingParameter(let name): "Missing required parameter: \(name)"
        case .invalidParameter(let message): "Invalid parameter: \(message)"
        }
    }
}
