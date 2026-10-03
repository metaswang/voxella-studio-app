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
        case "knowledge.find_text": return try await findText(args)
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
            "has_transcript": material != nil,
            "content_provenance": material?.provenance as Any? ?? NSNull(),
            "body_generation": material?.generation as Any? ?? NSNull(),
            "transcript_segment_count": material?.segments.count ?? 0,
            "transcript_character_count": material?.segments.reduce(0, { $0 + $1.text.count }) ?? 0,
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

    /// Compact catalog facts leave budget for reading the sources discovered
    /// here. Full capability/provenance metadata remains available on demand.
    func catalogCard(_ source: WorkbenchSession, facts: KnowledgeMediaFacts? = nil) async -> [String: Any] {
        let facts = if let facts { facts } else { await KnowledgeMediaDurationCache.shared.knownFacts(for: source) }
        let material = KnowledgeTranscriptMaterial.from(source)
        return ["session_id": source.id.uuidString, "title": source.title,
                "type": KnowledgeSourceType.from(sessionType: source.sessionType).rawValue,
                "origin": KnowledgeScopeSnapshot.origin(source).rawValue,
                "created_at": ISO8601DateFormatter().string(from: source.createdAt),
                "modified_at": ISO8601DateFormatter().string(from: source.modifiedAt),
                "has_transcript": material != nil,
                "transcript_segment_count": material?.segments.count ?? 0,
                "transcript_character_count": material?.segments.reduce(0, { $0 + $1.text.count }) ?? 0,
                "has_summary": source.summaryMarkdown?.isEmpty == false,
                "media_duration_sec": facts.mediaDuration as Any? ?? NSNull(),
                "last_spoken_end_sec": facts.lastSpokenEnd as Any? ?? NSNull(),
                "media_duration_provenance": facts.provenance]
    }

    func catalogCitation(_ source: WorkbenchSession, card: [String: Any]) -> [String: Any] {
        let facts = card.filter { !["session_id", "title", "modified_at"].contains($0.key) }
        return KnowledgeJSON.citation(reference(source, kind: "sessionCard", chunk: -1, text: KnowledgeJSON.encode(facts)))
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
        if let hasTranscript = args["has_transcript"] as? Bool {
            sessions = sessions.filter { (KnowledgeTranscriptMaterial.from($0) != nil) == hasTranscript }
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
        var sessions = try await filteredInventory(args)
        let offset = args["cursor"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 32
        guard offset >= 0, offset <= sessions.count, limit > 0, limit <= 100 else { throw KnowledgeToolError.invalidParameter("Invalid inventory page") }
        let sortBy = args["sort_by"] as? String ?? "created"
        let sortOrder = args["sort_order"] as? String ?? "desc"
        guard ["created", "modified", "duration"].contains(sortBy), ["asc", "desc"].contains(sortOrder) else {
            throw KnowledgeToolError.invalidParameter("Invalid sort_by or sort_order")
        }
        var facts: [UUID: KnowledgeMediaFacts] = [:]
        // Explicit duration aggregates resolve the whole filtered population;
        // reading a catalog page never probes every media file implicitly.
        for batchStart in stride(from: 0, to: sessions.count, by: 4) {
            let batch = Array(sessions[batchStart..<min(batchStart + 4, sessions.count)])
            let results = await withTaskGroup(of: (UUID, KnowledgeMediaFacts).self) { group in
                for item in batch {
                    group.addTask {
                        let value = if aggregate && sortBy == "duration" {
                            await KnowledgeMediaDurationCache.shared.facts(for: item)
                        } else { await KnowledgeMediaDurationCache.shared.knownFacts(for: item) }
                        return (item.id, value)
                    }
                }
                var output: [(UUID, KnowledgeMediaFacts)] = []
                for await row in group { output.append(row) }
                return output
            }
            for (id, value) in results { facts[id] = value }
            try Task.checkCancellation()
        }
        if aggregate {
            sessions.sort {
                let lhs = sortBy == "duration" ? facts[$0.id]?.mediaDuration : (sortBy == "modified" ? $0.modifiedAt : $0.createdAt).timeIntervalSince1970
                let rhs = sortBy == "duration" ? facts[$1.id]?.mediaDuration : (sortBy == "modified" ? $1.modifiedAt : $1.createdAt).timeIntervalSince1970
                guard let lhs else { return rhs == nil && $0.id.uuidString < $1.id.uuidString }
                guard let rhs else { return true }
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : (sortOrder == "asc" ? lhs < rhs : lhs > rhs)
            }
        }
        var rows: [[String: Any]] = [], citations: [[String: Any]] = []
        for item in sessions.dropFirst(offset).prefix(limit) {
            let card = await catalogCard(item, facts: facts[item.id])
            rows.append(card)
            citations.append(catalogCitation(item, card: card))
        }
        var data: [String: Any] = ["sessions": rows, "count": rows.count, "returned_count": rows.count,
                                  "total_count": sessions.count, "complete": offset + rows.count == sessions.count,
                                  "next_cursor": offset + rows.count < sessions.count ? offset + rows.count : NSNull(),
                                  "date_field": args["date_field"] as? String ?? "created",
                                  "citations": citations]
        if aggregate {
            let knownSessions = sessions.filter { facts[$0.id]?.mediaDuration != nil }
            let known = knownSessions.compactMap { facts[$0.id]?.mediaDuration }
            let groupBy = args["group_by"] as? String
            guard groupBy == nil || ["type", "origin"].contains(groupBy!) else { throw KnowledgeToolError.invalidParameter("Invalid group_by") }
            var groups: [String: Int] = [:]
            for item in sessions {
                let key = groupBy == "type" ? KnowledgeSourceType.from(sessionType: item.sessionType).rawValue : KnowledgeScopeSnapshot.origin(item).rawValue
                groups[key, default: 0] += 1
            }
            let longest = knownSessions.max { facts[$0.id]!.mediaDuration! < facts[$1.id]!.mediaDuration! }
            let shortest = knownSessions.min { facts[$0.id]!.mediaDuration! < facts[$1.id]!.mediaDuration! }
            let longestCard: Any = if let longest { await catalogCard(longest, facts: facts[longest.id]) } else { NSNull() }
            let shortestCard: Any = if let shortest { await catalogCard(shortest, facts: facts[shortest.id]) } else { NSNull() }
            let aggregate: [String: Any] = ["count": sessions.count, "media_duration_sum_sec": known.reduce(0, +),
                "duration_known_count": known.count, "duration_unknown_count": sessions.count - known.count,
                "group_by": groupBy as Any? ?? NSNull(), "groups": groupBy == nil ? [:] : groups,
                "sort_by": sortBy, "sort_order": sortOrder, "sorted_session_ids": rows.compactMap { $0["session_id"] },
                "longest_known": longestCard, "shortest_known": shortestCard,
                "input_set_version": workspace?.snapshot.cacheNamespace ?? "live",
                "filters": args.filter { !["limit", "cursor"].contains($0.key) },
                "duration_policy": "Local media probed for duration sorting; other aggregates use cached metadata or explicit hints. Unknowns cannot establish global extrema.", "semantic_count": false]
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
        if material != nil {
            let chunks = KnowledgeBodyReader.nativeParts(material!)
            let allHits: [SessionSearchHit] = chunks.enumerated().map { index, chunk in
                SessionSearchHit(sessionID: source.id, title: source.title, unitID: index, kind: .transcriptChunk,
                    start: chunk.start, end: chunk.end, speakerLabels: chunk.speakers, text: chunk.text, score: 1,
                    matchSource: "direct_read", snippet: chunk.text, cueIDs: chunk.spans.compactMap(\.cueID), hasVideo: false,
                    language: material?.language, quoteSpan: nil, materialGeneration: material?.generation,
                    provenance: material?.provenance, materialRole: material?.role, revision: material?.revision,
                    characterStart: chunk.lower, characterEnd: chunk.upper, timingPrecision: chunk.timingPrecision, context: chunk.context)
            }
            let speaker = args["speaker"] as? String
            let filtered = allHits.filter {
                (start == nil || $0.end == nil || $0.end! >= start!) && (end == nil || $0.start == nil || $0.start! <= end!) &&
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
            // An unreadable current source must not revive an older indexed body.
            hits = []; total = 0; pageOffset = 0
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
            "pagination_unit": "bounded body units with original character spans and verified timing",
            "original_segment_count": segments?.count ?? 0,
            "body_generation": material?.generation as Any? ?? NSNull(),
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
            useGraph: args["use_graph"] as? Bool ?? false))
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
        let sources = await visibleSessions()
        let visible = Set(sources.map(\.id))
        var rows: [[String: Any]] = [], citations: [[String: Any]] = []
        for card in cards where visible.contains(card.sessionID) {
            if let source = sources.first(where: { $0.id == card.sessionID }) {
                var row = await catalogCard(source)
                citations.append(catalogCitation(source, card: row))
                row["match_source"] = card.matchSource
                row["match_excerpt"] = String((card.snippet ?? card.summaryExcerpt ?? "").prefix(2_000))
                row["match_excerpt_complete"] = (card.snippet ?? card.summaryExcerpt ?? "").count <= 2_000
                row["verification_note"] = "Source candidate only; read original transcript to verify factual claims"
                rows.append(row)
            }
        }
        return .success(["sources": rows, "returned_count": rows.count, "complete": false,
                         "candidate_set_only": true, "citations": citations])
    }

    static func textPages(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    private func findText(_ args: [String: Any]) async throws -> KnowledgeToolResult {
        guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1_000 else { throw KnowledgeToolError.invalidParameter("text must be a nonempty literal phrase up to 1000 characters") }
        let ids = try await sourceIDs(args)
        let sources = await visibleSessions().filter { ids == nil || ids!.contains($0.id) }
        let pattern = text.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var matches: [(SessionSearchHit, Int, String)] = [], unavailable: [String] = []
        var checked = 0, occurrences = 0
        for source in sources {
            try Task.checkCancellation()
            guard let material = KnowledgeTranscriptMaterial.from(source) else {
                unavailable.append(source.id.uuidString)
                continue
            }
            checked += 1
            let original = material.text as NSString
            let ranges = expression.matches(in: material.text, range: NSRange(location: 0, length: original.length))
            occurrences += ranges.count
            for index in material.segments.indices {
                let parentSpans = material.spans.filter { $0.parentIndex == index }
                guard let lower = parentSpans.map(\.lower).min(), let upper = parentSpans.map(\.upper).max(),
                      let found = ranges.first(where: { $0.range.location < upper && NSMaxRange($0.range) > lower }) else { continue }
                let excerptRange = original.rangeOfComposedCharacterSequences(for: NSRange(location: max(lower, found.range.location - 160),
                    length: min(upper, NSMaxRange(found.range) + 540) - max(lower, found.range.location - 160)))
                let snippet = original.substring(with: excerptRange)
                let hit = SessionSearchHit(sessionID: source.id, title: source.title, unitID: index, kind: .transcriptChunk,
                    start: parentSpans.compactMap(\.start).min(), end: parentSpans.compactMap(\.end).max(),
                    speakerLabels: Array(Set(parentSpans.compactMap(\.speaker))).sorted(), text: snippet, score: 1,
                    matchSource: "literal_scan", snippet: snippet, cueIDs: parentSpans.compactMap(\.cueID),
                    hasVideo: false, language: material.language, quoteSpan: nil, materialGeneration: material.generation,
                    provenance: material.provenance, characterStart: excerptRange.location, characterEnd: NSMaxRange(excerptRange),
                    timingPrecision: parentSpans.allSatisfy { $0.start != nil && $0.end != nil } ? "coarse" : "unknown")
                matches.append((hit, material.citationChunkBase, material.provenance))
            }
        }
        let cursor = args["cursor"] as? Int ?? 0, limit = args["limit"] as? Int ?? 32
        guard cursor >= 0, cursor <= matches.count, limit > 0, limit <= 100 else { throw KnowledgeToolError.invalidParameter("Invalid literal match page") }
        let page = Array(matches.dropFirst(cursor).prefix(limit))
        return .success(["text": text, "segments": page.map { hit, _, provenance in
                var row = Self.hitToDict(hit); row["read_provenance"] = provenance; return row
            },
            "returned_count": page.count, "total_count": matches.count,
            "occurrence_count": occurrences,
            "matched_segment_count": matches.count,
            "matched_source_count": Set(matches.map { $0.0.sessionID }).count,
            "checked_source_count": checked, "scope_source_count": sources.count, "unavailable_source_ids": unavailable,
            "complete": cursor + page.count == matches.count, "all_sources_readable": unavailable.isEmpty,
            "next_cursor": cursor + page.count < matches.count ? cursor + page.count : NSNull(),
            "match_semantics": "case-insensitive literal phrase with normalized whitespace; snippets retain canonical character ranges and trusted timing; transcript preferred with marked subtitle fallback",
            "citations": page.map { hit, base, _ in
                var ref = KnowledgeQAService.citation(from: hit)
                // Literal excerpts differ from full segment observations.
                ref.chunkIndex = base + 100_000_000 + hit.unitID
                return KnowledgeJSON.citation(ref)
            }])
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
         "end": hit.end as Any? ?? NSNull(), "speakers": hit.speakerLabels, "kind": hit.kind.rawValue,
         "provenance": hit.provenance as Any? ?? NSNull(), "body_generation": hit.materialGeneration as Any? ?? NSNull(),
         "character_start": hit.characterStart as Any? ?? NSNull(), "character_end": hit.characterEnd as Any? ?? NSNull(),
         "timing_precision": hit.timingPrecision, "matched_modalities": hit.matchedModalities]
    }

    static func bucketTimeline(hits: [SessionSearchHit], bucketSeconds: Double) -> [[String: Any]] {
        guard bucketSeconds > 0 else { return [] }
        let fine = hits.filter { $0.start != nil && $0.end != nil && $0.end! - $0.start! <= bucketSeconds }
        let grouped = Dictionary(grouping: fine) { floor($0.start! / bucketSeconds) * bucketSeconds }
        var rows: [[String: Any]] = grouped.keys.sorted().map { start in
            ["start": start, "end": start + bucketSeconds, "segment_count": grouped[start]!.count,
             "segments": grouped[start]!.map(hitToDict)]
        }
        for hit in hits where hit.start == nil || hit.end == nil || hit.end! - hit.start! > bucketSeconds {
            rows.append(["start": hit.start as Any? ?? NSNull(), "end": hit.end as Any? ?? NSNull(),
                         "timing_precision": hit.timingPrecision, "spans_multiple_buckets": hit.start != nil && hit.end != nil,
                         "segment_count": 1, "segments": [hitToDict(hit)]])
        }
        return rows
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
