import Foundation
import MCP

/// Read-only evidence tools for a host model. Does not invoke the app answer agent.
enum MCPKnowledgeBaseTools {
    static let instructions = """
    Answer from VoxStudio evidence using your own reasoning. search defaults to canonical spoken content:
    Transcript first, same-source current subtitles only when Transcript is unavailable.
    Explicit subtitle_passages and media_clips searches retain their distinct material semantics.
    Clip results locate media; their subtitle snippets and scores do not establish visual facts.
    fetch verifies current source versions. Search is a candidate set, not exhaustive coverage.
    list_sources and aggregate cover the authorized catalog. methods are optional advisory guidance.
    """

    private static let common: [String: Value] = [
        "source_id": ["type": "string", "description": "Authorized session UUID"],
        "source_ids": ["type": "array", "items": ["type": "string"]],
        "origin": ["type": "string", "enum": ["all", "local", "cloud"]],
        "language": ["type": "string"],
        "date_from": ["type": "string"], "date_to": ["type": "string"],
        "date_field": ["type": "string", "enum": ["created", "modified"]],
        "speaker": ["type": "string"], "start": ["type": "number"], "end": ["type": "number"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
        "cursor": ["type": "string", "description": "Opaque versioned cursor returned by this tool"],
        "material": ["type": "string", "enum": ["canonical", "subtitles", "translation"]],
        "revision": ["type": "string", "description": "Current voiceover revision only"],
    ]
    static var tools: [Tool] {
        let definitions: [(String, String, [String], [String: Value], [String])] = [
            ("search", "Find evidence candidates; canonical passages by default. Explicit subtitles and clips remain independent.", Array(common.keys).filter { $0 != "cursor" }, [
                "query": ["type": "string"],
                "target": ["type": "string", "enum": ["passages", "sources", "subtitle_passages", "media_clips"]],
                "rerank": ["type": "string", "enum": ["auto", "none"]],
                "use_graph": ["type": "boolean"], "entities": ["type": "array", "items": ["type": "string"]],
                "modality": ["type": "string", "enum": ["text", "video", "mixed"]],
            ], ["query"]),
            ("fetch", "Read current original evidence or an explicit subtitle track; clips return media preview locations.", Array(common.keys), [
                "evidence_id": ["type": "string"], "view": ["type": "string", "enum": ["body", "cues", "summary", "metadata", "timeline", "media"],
                    "description": "cues preserves each saved subtitle cue; requires material=subtitles or translation. body returns retrieval passages."],
            ], []),
            ("list_sources", "Page through the complete authorized source catalog with body provenance and index lane readiness.", Array(common.keys).filter { !["material", "speaker", "start", "end", "revision"].contains($0) }, [:], []),
            ("aggregate", "Count, sum known media durations, group and sort the full authorized catalog; unknowns remain unknown.", Array(common.keys).filter { !["material", "speaker", "start", "end", "revision"].contains($0) }, [
                "group_by": ["type": "string", "enum": ["type", "origin"]],
                "sort_by": ["type": "string", "enum": ["created", "modified", "duration"]],
                "sort_order": ["type": "string", "enum": ["asc", "desc"]],
            ], []),
            ("find_text", "Find literal occurrences in current canonical or explicitly selected subtitle text, with original character positions.", Array(common.keys), [
                "text": ["type": "string"],
            ], ["text"]),
            ("methods", "List or read enabled knowledge methods; advisory guidance does not grant tools or permissions.", ["cursor"], [
                "action": ["type": "string", "enum": ["list", "read"]], "method_id": ["type": "string"],
            ], []),
        ]
        return definitions.map { name, description, keys, additions, required in
            let properties = common.filter { keys.contains($0.key) }.merging(additions) { _, rhs in rhs }
            return Tool(name: name, description: description,
                inputSchema: .object(["type": "object", "properties": .object(properties),
                                      "required": .array(required.map(Value.string)), "additionalProperties": false]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
                outputSchema: ["type": "object", "properties": [
                    "status": ["type": "string"], "complete": ["type": "boolean"],
                    "next_cursor": ["type": ["string", "null"]], "candidate_set_only": ["type": "boolean"],
                    "results": ["type": "array", "items": ["type": "object"]],
                    "sources": ["type": "array", "items": ["type": "object"]],
                    "segments": ["type": "array", "items": ["type": "object"]],
                    "aggregate": ["type": "object"], "methods": ["type": "array", "items": ["type": "object"]],
                ], "required": ["status", "complete"], "additionalProperties": true])
        }
    }

    static func makeServer() async -> MCPServerInstance {
        let server = Server(name: "voxstudio-knowledge", version: "1.0.0", instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await execute(name: params.name, args: ToolArgsBridge.argsFromMCP(params.arguments ?? [:]))
        }
        return MCPServerInstance(server: server) { _ in }
    }

    struct Locator: Codable, Sendable {
        var sourceID: UUID
        var material: String
        var language: String?
        var generation: String
        var lower: Int
        var upper: Int
        var clipID: Int? = nil
        var start: Double? = nil
        var end: Double? = nil
        var revision: String? = nil
        var id: String { "kb:" + ((try? JSONEncoder().encode(self).base64EncodedString()) ?? "") }
        static func decode(_ value: String) throws -> Self {
            guard value.hasPrefix("kb:"), let bytes = Data(base64Encoded: String(value.dropFirst(3))),
                  let locator = try? JSONDecoder().decode(Self.self, from: bytes) else {
                throw KnowledgeToolError.invalidParameter("Invalid evidence_id")
            }
            return locator
        }
    }
    private struct Cursor: Codable {
        var namespace: String
        var offset: Int
    }
    private static func cursor(_ offset: Int, namespace: String) -> String {
        (try! JSONEncoder().encode(Cursor(namespace: namespace, offset: offset))).base64EncodedString()
    }
    private static func offset(_ args: [String: Any], namespace: String) throws -> Int {
        guard let raw = args["cursor"] as? String else { return 0 }
        guard let bytes = Data(base64Encoded: raw), let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes),
              cursor.namespace == namespace, cursor.offset >= 0 else {
            throw KnowledgeToolError.invalidParameter("Cursor expired or belongs to another query; start again")
        }
        return cursor.offset
    }

    @MainActor
    static func execute(name: String, args: [String: Any], snapshot supplied: KnowledgeScopeSnapshot? = nil,
                        service suppliedService: SearchService? = nil) async -> CallTool.Result {
        do {
            guard let tool = tools.first(where: { $0.name == name }),
                  let schema = tool.inputSchema.objectValue, let properties = schema["properties"]?.objectValue else {
                throw KnowledgeToolError.unknownTool(name)
            }
            for key in args.keys where properties[key] == nil { throw KnowledgeToolError.invalidParameter("Unknown argument: \(key)") }
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where args[key] == nil {
                throw KnowledgeToolError.missingParameter(key)
            }
            for (key, value) in args {
                guard let type = properties[key]?.objectValue?["type"]?.stringValue else { continue }
                let number = value as? NSNumber
                let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                let valid: Bool
                switch type {
                case "string": valid = value is String
                case "array": valid = value is [String]
                case "boolean": valid = isBool
                case "integer": valid = !isBool && number?.doubleValue.isFinite == true && number!.doubleValue.rounded() == number!.doubleValue
                case "number": valid = !isBool && number?.doubleValue.isFinite == true
                default: valid = false
                }
                guard valid else { throw KnowledgeToolError.invalidParameter(key) }
                if let enumeration = properties[key]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue),
                   let value = value as? String, !enumeration.contains(value) { throw KnowledgeToolError.invalidParameter(key) }
            }
            let limit = args["limit"] as? Int ?? (name == "search" ? 8 : 32)
            guard (1...100).contains(limit) else { throw KnowledgeToolError.invalidParameter("limit must be 1...100") }
            let origins = (args["origin"] as? String).flatMap(KnowledgeSourceOrigin.init(rawValue:)).map { Set([$0]) }
            let snapshot = if let supplied { supplied } else { await KnowledgeScopeSnapshot.capture(scope: .all, origins: origins) }
            try await snapshot.validate()
            let sources = try selectedSources(args, snapshot: snapshot)
            let subset = KnowledgeScopeSnapshot(scope: .sessions(sources.map(\.id)), ownerID: snapshot.ownerID, sessions: sources,
                generations: snapshot.generations, authorizationGeneration: snapshot.authorizationGeneration, isLive: snapshot.isLive)
            var keyArgs = args; keyArgs.removeValue(forKey: "cursor"); keyArgs.removeValue(forKey: "limit")
            let namespace = KnowledgeScopeSnapshot.digest(Data((subset.cacheNamespace + "|" + name + "|" + KnowledgeJSON.encode(keyArgs)).utf8))
            let offset = try offset(args, namespace: namespace)
            let executor = KnowledgeToolExecutor(scope: subset.scope, originFilter: origins, retrievalService: .init(),
                                                 workspace: KnowledgeEvidenceWorkspace(snapshot: subset))
            let service = suppliedService ?? SessionIndexCoordinator.shared.searchService
            var result: [String: Any]
            switch name {
            case "search":
                result = try await search(args, sources: sources, snapshot: subset, service: service, limit: min(32, limit))
            case "fetch":
                result = try await fetch(args, sources: sources, executor: executor, service: service, offset: offset, limit: limit)
            case "list_sources", "aggregate":
                var nativeArgs: [String: Any] = ["cursor": offset, "limit": limit]
                for key in ["group_by", "sort_by", "sort_order"] { nativeArgs[key] = args[key] }
                let native = try await executeNative(executor, name: name == "aggregate" ? "session.aggregate" : "session.list",
                                                     data: JSONSerialization.data(withJSONObject: nativeArgs))
                result = try object(native)
                if var rows = result["sessions"] as? [[String: Any]] {
                    for index in rows.indices {
                        if let id = (rows[index]["session_id"] as? String).flatMap(UUID.init(uuidString:)),
                           let source = sources.first(where: { $0.id == id }) {
                            let body = KnowledgeTranscriptMaterial.from(source)
                            rows[index]["body_provenance"] = body?.provenance as Any? ?? NSNull()
                            rows[index]["material_generation"] = body?.generation as Any? ?? NSNull()
                            rows[index]["material_role"] = body?.role as Any? ?? NSNull()
                            rows[index]["revision"] = source.knowledgeRevisionID?.uuidString as Any? ?? NSNull()
                            rows[index]["body_readable"] = body != nil
                            rows[index]["subtitle_track_available"] = source.subtitleTrack?.cues.isEmpty == false
                            rows[index]["translation_languages"] = source.translationTracks.map(\.languageCode)
                            rows[index]["index_lanes"] = try await service.store.laneStatus(sessionID: id)
                            rows[index]["embedding_channel_counts"] = try await service.store.embeddingChannels(sessionID: id)
                            let header: EmbeddingStore.Header?
                            if let url = source.sourceURL, url.isFileURL {
                                header = EmbeddingStore.key(for: url).flatMap { EmbeddingStore.header(key: $0) }
                            } else { header = nil }
                            rows[index]["frame_index"] = ["ready": header.map { SearchIndexConfig.visualSpec.matches($0) } ?? false,
                                                          "frame_count": header?.count ?? 0]
                            rows[index]["source_id"] = id.uuidString
                        }
                    }
                    result["sources"] = rows
                    result.removeValue(forKey: "sessions")
                }
            case "find_text":
                result = try await find(args, sources: sources, offset: offset, limit: limit)
            case "methods":
                result = try methods(args, offset: offset)
            default: throw KnowledgeToolError.unknownTool(name)
            }
            if let next = result["next_cursor"] as? Int { result["next_cursor"] = cursor(next, namespace: namespace) }
            result["status"] = result["status"] ?? "ok"
            result["complete"] = result["complete"] ?? false
            result["source_version"] = subset.cacheNamespace
            try Task.checkCancellation()
            try await subset.validate()
            return try MCPOpenAIExtensions.result(result)
        } catch {
            return (try? MCPOpenAIExtensions.result(["status": "error", "complete": false, "error": error.localizedDescription], error: true))
                ?? .init(content: [.text(error.localizedDescription)], isError: true)
        }
    }

    private static func selectedSources(_ args: [String: Any], snapshot: KnowledgeScopeSnapshot) throws -> [WorkbenchSession] {
        var requested = args["source_ids"] as? [String]
        if let id = args["source_id"] as? String { requested = [id] }
        if let id = args["evidence_id"] as? String {
            let locator = try Locator.decode(id)
            if let requested, !requested.contains(locator.sourceID.uuidString) { throw KnowledgeToolError.invalidParameter("Conflicting source and evidence") }
            requested = [locator.sourceID.uuidString]
        }
        let visible = Set(snapshot.sessions.map(\.id))
        if let requested {
            let ids = requested.compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty, ids.count == requested.count, Set(ids).count == ids.count, ids.allSatisfy(visible.contains) else {
                throw KnowledgeToolError.invalidParameter("Source is unavailable or unauthorized")
            }
        }
        let from = try KnowledgeToolExecutor.date(args["date_from"] as? String)
        let to = try KnowledgeToolExecutor.date(args["date_to"] as? String)
        guard from == nil || to == nil || from! <= to! else { throw KnowledgeToolError.invalidParameter("Reversed date range") }
        let origin = args["origin"] as? String
        return snapshot.sessions.filter { source in
            let date = args["date_field"] as? String == "modified" ? source.modifiedAt : source.createdAt
            return (requested == nil || requested!.contains(source.id.uuidString)) &&
                (origin == nil || origin == "all" || KnowledgeScopeSnapshot.origin(source).rawValue == origin) &&
                (from == nil || date >= from!) && (to == nil || date <= to!)
        }
    }

    private static func body(_ source: WorkbenchSession, args: [String: Any], material: String? = nil) throws -> KnowledgeTranscriptMaterial? {
        if let revision = args["revision"] as? String, revision != source.knowledgeRevisionID?.uuidString {
            throw KnowledgeToolError.invalidParameter("Requested revision is not current")
        }
        let material = material ?? args["material"] as? String ?? "canonical"
        if material == "canonical" { return KnowledgeTranscriptMaterial.from(source) }
        let role = source.source == .standaloneDub || source.sessionType == .dub ? "voiceover" : "original"
        let track: SubtitleTrack?
        if material == "translation" {
            guard let language = args["language"] as? String else { throw KnowledgeToolError.missingParameter("language") }
            track = source.translationTracks.first { $0.languageCode == language }?.track
        } else { track = role == "voiceover" ? (source.subtitleTrack ?? source.dubSubtitleTrack) : source.subtitleTrack }
        guard let selected = KnowledgeTranscriptMaterial.from(subtitles: track, role: role, revision: source.knowledgeRevisionID?.uuidString) else { return nil }
        return .init(text: selected.text, segments: selected.segments, spans: selected.spans, language: selected.language,
                     provenance: material == "translation" ? "translation_track" : "subtitle_track", role: role,
                     revision: selected.revision, citationChunkBase: selected.citationChunkBase)
    }

    private static func executeNative(_ executor: KnowledgeToolExecutor, name: String, data: Data) async throws -> KnowledgeToolResult {
        let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try await executor.execute(toolName: name, arguments: arguments)
    }

    private static func object(_ result: KnowledgeToolResult) throws -> [String: Any] {
        switch result {
        case .success(let value): return value
        case .error(let error): throw KnowledgeToolError.invalidParameter(error)
        case .control: throw KnowledgeToolError.invalidParameter("Unexpected control result")
        }
    }

    static func passage(_ source: WorkbenchSession, body: KnowledgeTranscriptMaterial, chunk: KnowledgeBodyChunker.Chunk,
                        material: String = "canonical") -> [String: Any] {
        let locator = Locator(sourceID: source.id, material: material, language: body.language, generation: body.generation,
                              lower: chunk.lower, upper: chunk.upper, revision: body.revision)
        return ["evidence_id": locator.id, "source_id": source.id.uuidString, "title": source.title,
                "material_id": source.id.uuidString + ":" + material + ":" + body.role,
                "material_kind": material == "canonical" ? (body.provenance == "subtitle_fallback" ? "subtitle_fallback" : "transcript") : material,
                "role": body.role, "revision": body.revision as Any? ?? NSNull(), "generation": body.generation,
                "text": chunk.text, "context": chunk.context, "character_start": chunk.lower, "character_end": chunk.upper,
                "parents": chunk.spans.map { ["segment": $0.parentIndex, "cue_id": $0.cueID as Any? ?? NSNull()] },
                "speaker": chunk.speakers, "start": chunk.start as Any? ?? NSNull(), "end": chunk.end as Any? ?? NSNull(),
                "timing_precision": chunk.timingPrecision, "provenance": body.provenance,
                "url": "voxstudio://sessions/" + source.id.uuidString,
                "media_locator": ["source_id": source.id.uuidString, "start": chunk.start as Any? ?? NSNull(), "end": chunk.end as Any? ?? NSNull()]]
    }

    @MainActor
    private static func search(_ args: [String: Any], sources: [WorkbenchSession], snapshot: KnowledgeScopeSnapshot,
                               service: SearchService, limit: Int) async throws -> [String: Any] {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw KnowledgeToolError.invalidParameter("query must not be empty") }
        let target = args["target"] as? String ?? "passages"
        var filter = SessionSearchFilter.visible(isSignedIn: snapshot.ownerID != nil, sessionIDs: Set(sources.map(\.id)),
            cloudOwnerUserID: snapshot.ownerID?.uuidString, limit: 40)
        filter.language = args["language"] as? String; filter.speakerLabel = args["speaker"] as? String
        filter.start = args["start"] as? Double; filter.end = args["end"] as? Double
        try validateTime(args)
        var rows: [[String: Any]] = []
        var diagnostics: [String: Any] = ["target": target, "graph_executed": false, "reranker": "skipped"]
        if target == "sources" {
            let cards = try await service.sessionSearch(query: query, filter: filter)
            rows = cards.prefix(limit).map { ["source_id": $0.sessionID.uuidString, "title": $0.title, "text": $0.snippet ?? "", "provenance": $0.matchSource ?? "catalog", "verification_required": true] }
        } else if target == "media_clips" {
            filter.modality = (args["modality"] as? String).flatMap(SessionIndexModality.init(rawValue:))
            var currentManifests: [UUID: String] = [:]
            for source in sources {
                if let manifest = await currentMediaManifest(source),
                   try await service.store.laneManifest(sessionID: source.id, lane: "media") == manifest {
                    currentManifests[source.id] = manifest
                }
            }
            filter.sessionIDs = Set(currentManifests.keys)
            diagnostics["media_index_unavailable_or_stale_sources"] = sources.count - currentManifests.count
            let hits = try await service.clipSearch(query: query, filter: filter)
            for hit in hits.prefix(limit) {
                guard let source = sources.first(where: { $0.id == hit.sessionID }) else { continue }
                rows.append(try clip(hit, source: source, mediaManifest: currentManifests[source.id]))
            }
        } else {
            filter.canonicalGenerations = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                KnowledgeTranscriptMaterial.from(source).map { (source.id, $0.generation) }
            })
            let material = target == "subtitle_passages" ? (args["material"] as? String == "translation" ? "translation" : "subtitles") : "canonical"
            var candidates: [(WorkbenchSession, KnowledgeTranscriptMaterial, KnowledgeBodyChunker.Chunk, Double)] = []
            var directCandidates: [(WorkbenchSession, KnowledgeTranscriptMaterial, KnowledgeBodyChunker.Chunk, Double)] = []
            let indexed = target == "passages" ? try await service.transcriptSearch(query: query, filter: filter) : []
            var hits = indexed
            if args["use_graph"] as? Bool == true {
                let entities = args["entities"] as? [String] ?? []
                guard !entities.isEmpty, entities.count <= 8 else { throw KnowledgeToolError.invalidParameter("Graph requires 1...8 explicit entities") }
                let scopes = Set(sources.map { KnowledgeGraphSchema.scopeKey(origin: KnowledgeScopeSnapshot.origin($0), ownerUserID: snapshot.ownerID?.uuidString) })
                let found = try await service.store.graphEntities(matching: entities, scopes: scopes)
                let graph = try await service.store.graphChunks(entityIDs: found.map(\.id), filter: filter, limit: 30)
                hits = KnowledgeRetrievalService.fuse(hybrid: indexed, graph: graph, limit: 40)
                diagnostics["graph_executed"] = true
            }
            let terms = KnowledgeLexicalTerms.terms(query)
            for source in sources {
                guard let body = try body(source, args: args, material: material),
                      filter.language == nil || body.language == filter.language else { continue }
                let chunks = await KnowledgeTextTokenizer.shared.chunks(for: body)
                let current = hits.filter { $0.sessionID == source.id && $0.materialGeneration == body.generation }
                let manifest = try await service.store.laneManifest(sessionID: source.id, lane: "knowledge")
                let snapshotManifest = SessionIndexSnapshot.from(session: source, sourceOrigin: KnowledgeScopeSnapshot.origin(source), ownerUserID: snapshot.ownerID?.uuidString)?.knowledgeManifest
                let direct = target != "passages" || manifest == nil || manifest != snapshotManifest
                for chunk in chunks {
                    guard accepts(chunk, args: args) else { continue }
                    let match = current.first { $0.characterStart == chunk.lower && $0.characterEnd == chunk.upper }
                    let termsHit = terms.filter { chunk.text.localizedCaseInsensitiveContains($0) }.count
                    if let match { candidates.append((source, body, chunk, match.score)) }
                    else if direct && termsHit > 0 { directCandidates.append((source, body, chunk, Double(termsHit) / Double(max(1, terms.count)))) }
                }
            }
            candidates.sort { $0.3 > $1.3 }
            directCandidates.sort { $0.3 > $1.3 }
            func key(_ candidate: (WorkbenchSession, KnowledgeTranscriptMaterial, KnowledgeBodyChunker.Chunk, Double)) -> String {
                candidate.0.id.uuidString + ":" + candidate.1.generation + ":" + String(candidate.2.lower)
            }
            let byKey = Dictionary((candidates + directCandidates).map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
            candidates = ReciprocalRankFusion.fuse(rankings: [candidates.map(key), directCandidates.map(key)])
                .prefix(40).enumerated().compactMap { rank, id in
                    guard let candidate = byKey[id] else { return nil }
                    return (candidate.0, candidate.1, candidate.2, 61 / Double(61 + rank))
                }
            if args["rerank"] as? String != "none", !candidates.isEmpty {
                do {
                    let texts = candidates.map { $0.2.text }
                    let scores = try await KnowledgeQATimeout.run(.seconds(5)) { try await RerankerService.shared.scores(query: query, chunks: texts) }
                    guard scores.count == candidates.count, scores.allSatisfy(\.isFinite) else { throw KnowledgeQAError.invalidRerankerOutput }
                    for index in candidates.indices { candidates[index].3 = scores[index] }
                    candidates.sort { $0.3 > $1.3 }; diagnostics["reranker"] = "used"
                } catch is CancellationError {
                    try Task.checkCancellation(); diagnostics["reranker"] = "timeout"
                } catch { diagnostics["reranker"] = "unavailable"; diagnostics["degradation"] = error.localizedDescription }
            }
            let scored: [KnowledgeRerankedHit] = candidates.enumerated().map { index, candidate -> KnowledgeRerankedHit in
                let (source, body, chunk, score) = candidate
                let indexed: SessionSearchHit? = hits.first { hit in
                    guard hit.sessionID == source.id, hit.materialGeneration == body.generation else { return false }
                    return hit.characterStart == chunk.lower && hit.characterEnd == chunk.upper
                }
                let unitID = indexed?.unitID ?? -(index + 1)
                let hit = SessionSearchHit(sessionID: source.id, title: source.title, unitID: unitID,
                    kind: .transcriptChunk, start: chunk.start, end: chunk.end, speakerLabels: chunk.speakers,
                    text: chunk.text, score: score, matchSource: indexed?.matchSource ?? "direct", snippet: nil,
                    cueIDs: [], hasVideo: indexed?.hasVideo ?? source.remoteSourceHasVideo ?? false, language: body.language, quoteSpan: nil)
                return KnowledgeRerankedHit(hit: hit, score: score)
            }
            let candidateByID = Dictionary(zip(scored.map(\.hit.unitID), candidates), uniquingKeysWith: { first, _ in first })
            let vectors = (try? await service.store.textEmbeddings(unitIDs: scored.map(\.hit.unitID).filter { $0 > 0 })) ?? [:]
            let selected = KnowledgeMMR.select(scored, vectors: vectors, limit: limit, coverSources: args["source_ids"] != nil)
            rows = selected.compactMap { candidateByID[$0.hit.unitID] }.map { source, body, chunk, score in
                var row = passage(source, body: body, chunk: chunk, material: material); row["score"] = score; return row
            }
            diagnostics["candidate_count"] = candidates.count
        }
        return ["results": rows, "returned_count": rows.count, "complete": false, "candidate_set_only": true,
                "retrieval": diagnostics, "score_semantics": "Ordering only; no confidence or visual verification implied"]
    }

    private static func accepts(_ chunk: KnowledgeBodyChunker.Chunk, args: [String: Any]) -> Bool {
        let start = args["start"] as? Double, end = args["end"] as? Double, speaker = args["speaker"] as? String
        return (start == nil || chunk.end == nil || chunk.end! >= start!) &&
            (end == nil || chunk.start == nil || chunk.start! <= end!) && (speaker == nil || chunk.speakers.contains(speaker!))
    }
    private static func validateTime(_ args: [String: Any]) throws {
        let start = args["start"] as? Double, end = args["end"] as? Double
        guard (start == nil || start! >= 0), (end == nil || end! >= 0), (start == nil || end == nil || start! <= end!) else {
            throw KnowledgeToolError.invalidParameter("Invalid time range")
        }
    }
    @MainActor private static func currentMediaManifest(_ source: WorkbenchSession) async -> String? {
        guard var snapshot = SessionIndexSnapshot.from(session: source, sourceOrigin: KnowledgeScopeSnapshot.origin(source), ownerUserID: nil) else { return nil }
        await snapshot.resolveVideoDurationIfNeeded()
        return snapshot.mediaManifest
    }

    private static func clip(_ hit: SessionSearchHit, source: WorkbenchSession, mediaManifest: String? = nil) throws -> [String: Any] {
        let manifest = mediaManifest ?? SessionIndexSnapshot.from(session: source, sourceOrigin: KnowledgeScopeSnapshot.origin(source), ownerUserID: nil)?.mediaManifest ?? "unavailable"
        let generation = KnowledgeScopeSnapshot.digest(Data((manifest + "|" + (source.knowledgeRevisionID?.uuidString ?? "")).utf8))
        let locator = Locator(sourceID: source.id, material: "media", language: hit.language, generation: generation, lower: 0, upper: 0,
                              clipID: hit.unitID, start: hit.start, end: hit.end, revision: source.knowledgeRevisionID?.uuidString)
        return ["evidence_id": locator.id, "source_id": source.id.uuidString, "clip_id": hit.unitID, "title": hit.title,
                "text": hit.text, "kind": "media_clip", "provenance": "media_candidate", "generation": generation,
                "start": hit.start as Any? ?? NSNull(), "end": hit.end as Any? ?? NSNull(), "cue_ids": hit.cueIDs,
                "matched_modalities": hit.matchedModalities, "score": hit.score, "visual_verified": false,
                "preview_locator": ["source_id": source.id.uuidString, "start": hit.start as Any? ?? NSNull(), "end": hit.end as Any? ?? NSNull()],
                "url": "voxstudio://sessions/" + source.id.uuidString]
    }

    @MainActor
    private static func fetch(_ args: [String: Any], sources: [WorkbenchSession], executor: KnowledgeToolExecutor,
                              service: SearchService, offset: Int, limit: Int) async throws -> [String: Any] {
        guard sources.count == 1, let source = sources.first else { throw KnowledgeToolError.invalidParameter("fetch requires source_id or evidence_id") }
        let locator = try (args["evidence_id"] as? String).map(Locator.decode)
        let view = args["view"] as? String ?? (locator?.material == "media" ? "media" : "body")
        if view == "metadata" { return await executor.metadata(source) }
        if view == "summary" {
            return try object(await executor.execute(toolName: "session.get_summary", arguments: ["session_id": source.id.uuidString, "cursor": offset]))
        }
        if view == "media" {
            guard let locator, locator.material == "media", let start = locator.start, let end = locator.end,
                  let candidate = try await service.resolveClip(sessionID: source.id, start: start, end: end) else {
                throw KnowledgeToolError.invalidParameter("Current media candidate unavailable")
            }
            guard let id = locator.clipID, let hit = try await service.store.mediaClip(id: id, sessionID: source.id),
                  hit.start == start, hit.end == end else { throw KnowledgeToolError.invalidParameter("Media candidate expired") }
            guard let manifest = await currentMediaManifest(source),
                  try await service.store.laneManifest(sessionID: source.id, lane: "media") == manifest else {
                throw KnowledgeToolError.invalidParameter("Media index expired; wait for the current media lane")
            }
            let result = try clip(hit, source: source, mediaManifest: manifest)
            guard result["generation"] as? String == locator.generation else { throw KnowledgeToolError.invalidParameter("Evidence expired") }
            return result.merging(["complete": true, "media_path": candidate.mediaPath, "visual_verified": false]) { _, rhs in rhs }
        }
        let material = locator?.material ?? args["material"] as? String ?? "canonical"
        if view == "cues", material != "subtitles", material != "translation" {
            throw KnowledgeToolError.invalidParameter("view=cues requires material=subtitles or translation")
        }
        var bodyArgs = args
        if let language = locator?.language { bodyArgs["language"] = language }
        guard let body = try body(source, args: bodyArgs, material: material) else {
            return ["status": "unavailable", "complete": false, "segments": [], "coverage_note": "No readable selected body; media clips may still be available"]
        }
        if let locator, locator.generation != body.generation { throw KnowledgeToolError.invalidParameter("Evidence expired; search current material again") }
        try validateTime(args)
        // Reading subtitles must preserve the saved editor boundaries. Retrieval
        // passages deliberately pack many cues and remain the default body view.
        let selectedChunks: [KnowledgeBodyChunker.Chunk]
        if view == "cues" {
            let text = body.text as NSString
            selectedChunks = body.spans.map { span in
                .init(text: text.substring(with: NSRange(location: span.lower, length: span.upper - span.lower)),
                      context: "", lower: span.lower, upper: span.upper, spans: [span])
            }
        } else { selectedChunks = await KnowledgeTextTokenizer.shared.chunks(for: body) }
        var chunks = selectedChunks.filter { accepts($0, args: args) }
        if let locator { chunks = chunks.filter { $0.lower < locator.upper && $0.upper > locator.lower } }
        guard offset <= chunks.count else { throw KnowledgeToolError.invalidParameter("Cursor outside body") }
        var page: [KnowledgeBodyChunker.Chunk] = [], characters = 0
        for chunk in chunks.dropFirst(offset).prefix(min(100, limit)) {
            if characters + chunk.text.count > 16_000 { break }
            page.append(chunk); characters += chunk.text.count
        }
        let rows = page.map { chunk in
            var row = passage(source, body: body, chunk: chunk, material: material)
            if view == "cues", let span = chunk.spans.first {
                row["cue_id"] = span.cueID as Any? ?? NSNull()
                row["timing_precision"] = span.timingPrecision
            }
            return row
        }
        var result: [String: Any] = ["source_id": source.id.uuidString, "segments": rows,
            "returned_count": page.count, "total_count": chunks.count, "original_segment_count": body.segments.count,
            "complete": offset + page.count == chunks.count, "next_cursor": offset + page.count < chunks.count ? offset + page.count : NSNull(),
            "provenance": body.provenance, "generation": body.generation,
            "coverage_note": "Available selected text only; does not establish full-media transcription coverage"]
        if view == "timeline" {
            let hits = page.enumerated().map { index, chunk in SessionSearchHit(sessionID: source.id, title: source.title, unitID: index,
                kind: .transcriptChunk, start: chunk.start, end: chunk.end, speakerLabels: chunk.speakers, text: chunk.text, score: 1,
                matchSource: "body", snippet: nil, cueIDs: [], hasVideo: false, language: body.language, quoteSpan: nil, timingPrecision: chunk.timingPrecision) }
            result["buckets"] = KnowledgeToolExecutor.bucketTimeline(hits: hits, bucketSeconds: 60)
        }
        return result
    }

    @MainActor
    private static func find(_ args: [String: Any], sources: [WorkbenchSession], offset: Int, limit: Int) async throws -> [String: Any] {
        try validateTime(args)
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1_000 else { throw KnowledgeToolError.invalidParameter("text must be 1...1000 characters") }
        let pattern = text.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var matches: [[String: Any]] = [], unavailable: [String] = [], parents = Set<String>(), foundSources = Set<UUID>()
        for source in sources {
            try Task.checkCancellation()
            guard let body = try body(source, args: args) else { unavailable.append(source.id.uuidString); continue }
            let original = body.text as NSString
            for match in regex.matches(in: body.text, range: NSRange(location: 0, length: original.length)) {
                let spans = body.spans.filter { $0.lower < NSMaxRange(match.range) && $0.upper > match.range.location }
                let range = original.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, match.range.location - 120),
                    length: min(original.length, NSMaxRange(match.range) + 240) - max(0, match.range.location - 120)))
                let chunk = KnowledgeBodyChunker.Chunk(text: original.substring(with: range), context: "", lower: range.location, upper: NSMaxRange(range), spans: spans)
                guard accepts(chunk, args: args) else { continue }
                var row = passage(source, body: body, chunk: chunk, material: args["material"] as? String ?? "canonical")
                row["match_start"] = match.range.location; row["match_end"] = NSMaxRange(match.range)
                matches.append(row); foundSources.insert(source.id)
                for span in spans { parents.insert(source.id.uuidString + ":" + String(span.parentIndex)) }
            }
        }
        guard offset <= matches.count else { throw KnowledgeToolError.invalidParameter("Cursor outside matches") }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        return ["results": page, "returned_count": page.count, "occurrence_count": matches.count,
                "matched_segment_count": parents.count, "matched_source_count": foundSources.count,
                "scope_source_count": sources.count, "unavailable_source_ids": unavailable, "all_sources_readable": unavailable.isEmpty,
                "complete": offset + page.count == matches.count, "next_cursor": offset + page.count < matches.count ? offset + page.count : NSNull(),
                "match_semantics": "Case-insensitive literal phrase; whitespace normalized; UTF-16 character positions"]
    }

    @MainActor
    private static func methods(_ args: [String: Any], offset: Int) throws -> [String: Any] {
        let methods = SkillStore.shared.knowledgeSkills().filter(KnowledgeToolRegistry.validateSkill)
        let mapping = ["knowledge.search": "search", "knowledge.search_sources": "search", "session.list": "list_sources",
            "session.aggregate": "aggregate", "knowledge.find_text": "find_text", "read_skill": "methods",
            "session.get_segments": "fetch", "session.get_summary": "fetch", "session.get_timeline": "fetch",
            "session.get_speakers": "fetch", "knowledge.get_session_metadata": "fetch"]
        if args["action"] as? String == "read" {
            guard let id = args["method_id"] as? String, let skill = methods.first(where: { $0.id == id }) else {
                throw KnowledgeToolError.invalidParameter("Unknown or disabled method")
            }
            let text = try String(contentsOf: skill.path, encoding: .utf8)
            let body = SkillFrontmatter.parse(text).body
            guard offset <= body.count else { throw KnowledgeToolError.invalidParameter("Cursor outside method") }
            let page = String(body.dropFirst(offset).prefix(16_000))
            return ["method_id": id, "method": page, "version": KnowledgeScopeSnapshot.digest(Data(text.utf8)),
                    "next_cursor": offset + page.count < body.count ? offset + page.count : NSNull(),
                    "tool_bindings": mapping, "permissions": "Advisory only; no permissions granted", "complete": offset + page.count == body.count]
        }
        return ["methods": methods.map { ["method_id": $0.id, "name": $0.name, "description": $0.description,
                                          "version": KnowledgeScopeSnapshot.digest((try? Data(contentsOf: $0.path)) ?? Data()),
                                          "origin": $0.path.path.contains("/KnowledgeSkills/") ? "built_in" : "loaded",
                                          "allowed_tools": $0.metadata?.allowedTools ?? [], "tool_bindings": mapping] },
                "complete": true]
    }
}
