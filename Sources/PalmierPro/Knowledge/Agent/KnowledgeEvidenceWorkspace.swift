import AVFoundation
import CryptoKit
import Foundation

/// Immutable authorization and source versions for one plan revision. Never derives
/// media duration from transcript/dub endpoints or the legacy index duration.
struct KnowledgeScopeSnapshot: Sendable {
    let scope: KnowledgeQAScope
    let ownerID: UUID?
    let sessions: [WorkbenchSession]
    let generations: [UUID: String]
    var authorizationGeneration: UUID? = nil
    var isLive = true

    @concurrent
    static func capture(scope: KnowledgeQAScope, origins: Set<KnowledgeSourceOrigin>?) async -> Self {
        let captured = await MainActor.run {
            let account = AccountService.shared
            let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: account.isSignedIn, uiFilter: origins)
            let sessions = WorkbenchStore.shared.sessions.filter { session in
                (scope == .all || scope.sessionIDs.contains(session.id)) && allowed.contains(origin(session))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return (account.userID, account.knowledgeAuthorizationGeneration, sessions)
        }
        return Self(scope: scope, ownerID: captured.0, sessions: captured.2,
                    generations: Dictionary(uniqueKeysWithValues: captured.2.map { ($0.id, generation($0)) }),
                    authorizationGeneration: captured.1)
    }

    static func origin(_ session: WorkbenchSession) -> KnowledgeSourceOrigin {
        .resolve(isCloudStorage: session.storage == .cloud,
                 hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly)
    }

    static func generation(_ session: WorkbenchSession) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let transcript = (try? encoder.encode(session.transcript ?? session.dubTranscript)) ?? Data()
        let cues = (try? encoder.encode(session.subtitleTrack?.cues)) ?? Data()
        let attributes = session.sourceURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let mediaVersion = String(describing: attributes?[.modificationDate]) + ":" + String(describing: attributes?[.size])
        let fields = [mediaVersion, session.id.uuidString, String(session.modifiedAt.timeIntervalSince1970), session.title,
                      session.summaryMarkdown ?? "", String(session.durationHint ?? -1),
                      session.sourceURL?.absoluteString ?? "", session.remoteSessionID?.uuidString ?? ""]
        return digest(Data(fields.joined(separator: "\u{0}").utf8) + transcript + cues)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validateAccess() async throws {
        try Task.checkCancellation()
        if isLive {
            let current = await MainActor.run { (AccountService.shared.userID, AccountService.shared.knowledgeAuthorizationGeneration) }
            guard current.0 == ownerID, authorizationGeneration == nil || current.1 == authorizationGeneration else {
                Log.knowledge.notice("native_scope_invalidated reason=authorization_changed")
                throw CancellationError()
            }
        }
    }

    @concurrent
    func validate() async throws {
        try await validateAccess()
        guard isLive else { return }
        let current = await MainActor.run { (AccountService.shared.userID, WorkbenchStore.shared.sessions) }
        guard current.0 == ownerID else { throw CancellationError() }
        // Deletion, re-transcription and source mutation invalidate in-flight results.
        for session in sessions {
            guard let live = current.1.first(where: { $0.id == session.id }) else {
                Log.knowledge.notice("native_scope_invalidated reason=source_deleted source_id=\(session.id.uuidString)")
                throw CancellationError()
            }
            guard Self.generation(live) == generations[session.id] else {
                Log.knowledge.notice("native_scope_invalidated reason=source_changed source_id=\(session.id.uuidString) modified=\(live.modifiedAt != session.modifiedAt) transcript=\(live.transcript != session.transcript) summary=\(live.summaryMarkdown != session.summaryMarkdown) cues=\(live.subtitleTrack?.cues != session.subtitleTrack?.cues)")
                throw CancellationError()
            }
        }
    }

    var cacheNamespace: String {
        Self.digest(Data(([ownerID?.uuidString ?? "local", authorizationGeneration?.uuidString ?? "fixture", scope.storageKey] + sessions.map {
            $0.id.uuidString + ":" + (generations[$0.id] ?? "")
        }).joined(separator: "|").utf8))
    }
}

struct KnowledgeMediaFacts: Equatable, Sendable {
    var mediaDuration: Double?
    var provenance: String
    var lastSpokenEnd: Double?
    var transcribedStart: Double?
    var transcribedEnd: Double?

    static func from(_ session: WorkbenchSession, probedDuration: Double? = nil) -> Self {
        let segments = (session.transcript ?? session.dubTranscript)?.segments ?? []
        let spoken = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ends = spoken.map(\.end).filter { $0.isFinite && $0 >= 0 }
        let starts = spoken.map(\.start).filter { $0.isFinite && $0 >= 0 }
        let duration = probedDuration.flatMap(validDuration) ?? session.durationHint.flatMap(validDuration)
        return Self(mediaDuration: duration,
                    provenance: probedDuration.flatMap(validDuration) != nil ? "local_media_metadata" :
                        (duration != nil ? "source_duration_hint" : "unknown; legacy index duration is not media duration"),
                    lastSpokenEnd: ends.max(), transcribedStart: starts.min(), transcribedEnd: ends.max())
    }

    private static func validDuration(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }
}

actor KnowledgeMediaDurationCache {
    static let shared = KnowledgeMediaDurationCache()
    private var durations: [String: Double] = [:]

    func facts(for session: WorkbenchSession) async -> KnowledgeMediaFacts {
        guard let url = session.sourceURL, url.isFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .from(session)
        }
        let key = url.path + ":" + String(describing: attrs[.modificationDate]) + ":" + String(describing: attrs[.size])
        if let cached = durations[key] { return .from(session, probedDuration: cached) }
        let seconds = try? await KnowledgeQATimeout.run(.seconds(2)) {
            try await AVURLAsset(url: url).load(.duration).seconds
        }
        if let seconds, seconds.isFinite, seconds >= 0 {
            if durations.count >= 256 { durations.removeAll() }
            durations[key] = seconds
        }
        return .from(session, probedDuration: seconds)
    }
}

struct KnowledgeToolObservation: Sendable {
    let json: String
    let isError: Bool
    let citations: [KnowledgeSourceRef]

    static func error(_ message: String) -> Self {
        Self(json: KnowledgeJSON.encode(["error": message, "recoverable": true]), isError: true, citations: [])
    }
}

enum KnowledgeJSON {
    static func encode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Tool result could not be encoded\",\"recoverable\":true}"
        }
        return text
    }

    static func citation(_ ref: KnowledgeSourceRef) -> [String: Any] {
        var result: [String: Any] = ["id": ref.id, "source_id": ref.sourceID, "source_type": ref.sourceType, "title": ref.title]
        result["start_time"] = ref.startTime
        result["end_time"] = ref.endTime
        result["chunk_index"] = ref.chunkIndex
        result["speaker"] = ref.speaker
        result["snippet"] = ref.snippet
        result["match_text"] = ref.matchText
        return result
    }

    static func reference(_ row: [String: Any]) -> KnowledgeSourceRef? {
        guard let id = row["source_id"] as? String, let type = row["source_type"] as? String else { return nil }
        return KnowledgeSourceRef(sourceID: id, sourceType: type, title: row["title"] as? String ?? "",
                                  uri: nil, page: nil, startTime: row["start_time"] as? Double,
                                  endTime: row["end_time"] as? Double, parentID: nil,
                                  chunkIndex: row["chunk_index"] as? Int, language: nil,
                                  speaker: row["speaker"] as? String, snippet: row["snippet"] as? String,
                                  matchText: row["match_text"] as? String)
    }
}

/// Model-maintained semantic coverage is distinct from mechanically observed read
/// ranges. No tool marks a semantic absence merely because search returned zero.
struct KnowledgeAnalysisCell: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case unchecked, notFound = "not_found", supported, conflict, absent, unavailable
    }
    let sourceID: UUID
    let dimension: String
    var status: Status = .unchecked
    var finding: String = ""
    var evidenceIDs: [String] = []
}

struct KnowledgeAnalysisView: Codable, Sendable {
    let sourceIDs: [UUID]
    let dimensions: [String]
    var cells: [KnowledgeAnalysisCell]

    init(sourceIDs: [UUID], dimensions: [String]) {
        self.sourceIDs = sourceIDs
        self.dimensions = dimensions
        cells = sourceIDs.flatMap { id in dimensions.map { KnowledgeAnalysisCell(sourceID: id, dimension: $0) } }
    }
}

struct KnowledgeWorkspaceMemory: Sendable {
    let references: [KnowledgeSourceRef]
    let evidenceIDs: [String: String]
    let payloads: [String: String]
    let analysis: KnowledgeAnalysisView?
    let readCoverage: [UUID: [String]]
}

actor KnowledgeEvidenceWorkspace {
    let snapshot: KnowledgeScopeSnapshot
    private var references: [KnowledgeSourceRef] = []
    private var evidenceIDs: [String: String] = [:]
    private var payloads: [String: String] = [:]
    private var analysis: KnowledgeAnalysisView?
    private var readCoverage: [UUID: [String]] = [:]
    private var repeatedCalls: [String: Int] = [:]

    init(snapshot: KnowledgeScopeSnapshot) { self.snapshot = snapshot }

    func restore(_ memory: KnowledgeWorkspaceMemory) {
        references = memory.references
        evidenceIDs = memory.evidenceIDs
        payloads = memory.payloads
        analysis = memory.analysis
        readCoverage = memory.readCoverage
    }

    func memory() -> KnowledgeWorkspaceMemory {
        KnowledgeWorkspaceMemory(references: references, evidenceIDs: evidenceIDs, payloads: payloads,
                                 analysis: analysis, readCoverage: readCoverage)
    }

    private func evidenceIndexRow(_ ref: KnowledgeSourceRef) -> [String: Any] {
        var row = KnowledgeJSON.citation(ref)
        row.removeValue(forKey: "match_text")
        row["title"] = String(ref.title.prefix(240))
        row["snippet"] = ref.snippet.map { String($0.prefix(180)) }
        row["excerpt_complete"] = (ref.snippet?.count ?? 0) <= 180
        row["speaker"] = ref.speaker.map { String($0.prefix(100)) }
        row["evidence_id"] = evidenceIDs.first(where: { $0.value == ref.id })?.key
        row["citation_number"] = (references.firstIndex(where: { $0.id == ref.id }) ?? 0) + 1
        return row
    }

    func priorEvidenceIndex() -> String {
        let index = references.suffix(24).map(evidenceIndexRow)
        var data: [String: Any] = ["prior_evidence": index, "total_evidence_count": references.count,
                                  "complete_index": references.count <= 24, "saved_payload_refs": Array(payloads.keys.sorted().suffix(16))]
        if let analysis, let encoded = try? JSONEncoder().encode(analysis),
           let object = try? JSONSerialization.jsonObject(with: encoded) { data["analysis"] = object }
        // Detailed views remain in recoverable observations, never silently flood context.
        let json = KnowledgeJSON.encode(data)
        return json.count <= 16_000 ? json : KnowledgeJSON.encode(["prior_evidence": index, "analysis_available": analysis != nil])
    }

    func record(_ json: String) -> KnowledgeToolObservation {
        guard let data = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .error("Invalid evidence payload")
        }
        return record(data)
    }

    private func record(_ data: [String: Any]) -> KnowledgeToolObservation {
        var data = data
        if let rawID = data["session_id"] as? String, let id = UUID(uuidString: rawID),
           data["returned_range"] != nil || data["summary_markdown"] != nil {
            readCoverage[id, default: []].append(KnowledgeJSON.encode(data.filter { ["returned_range", "returned_count", "total_count", "complete", "next_cursor", "read_provenance", "generated_summary"].contains($0.key) }))
        }
        let refs = (data["citations"] as? [[String: Any]] ?? []).compactMap(KnowledgeJSON.reference)
        data["citations"] = refs.map { ref in
            if !references.contains(where: { $0.id == ref.id }) { references.append(ref) }
            let generation = ref.sessionUUID.flatMap { snapshot.generations[$0] } ?? snapshot.cacheNamespace
            let evidenceID = "ev_" + KnowledgeScopeSnapshot.digest(Data((ref.id + generation).utf8))
            evidenceIDs[evidenceID] = ref.id
            var row = KnowledgeJSON.citation(ref)
            row["evidence_id"] = evidenceID
            row["source_generation"] = generation
            row["citation_number"] = (references.firstIndex(where: { $0.id == ref.id }) ?? 0) + 1
            return row
        }
        let encoded = KnowledgeJSON.encode(data)
        let handle = "payload_" + KnowledgeScopeSnapshot.digest(Data(encoded.utf8))
        payloads[handle] = encoded
        data["payload_ref"] = handle
        return KnowledgeToolObservation(json: KnowledgeJSON.encode(data), isError: false, citations: references)
    }

    func sourceEvidence(_ id: UUID) -> String {
        let sourceReferences = references.filter { $0.sessionUUID == id }
        return KnowledgeJSON.encode(["evidence": sourceReferences.suffix(24).map(evidenceIndexRow),
                                     "total_evidence_count": sourceReferences.count,
                                     "complete_index": sourceReferences.count <= 24,
                                     "reading_tools_available": true])
    }

    func validateWorkerFindings(_ json: String, sourceID: UUID) -> KnowledgeToolObservation {
        guard var data = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let findings = data["findings"] as? [[String: Any]], data["unresolved"] is [String],
              data["coverage"] != nil else { return .error("Worker result must include findings, unresolved and coverage") }
        for finding in findings {
            guard finding["finding"] is String, let ids = finding["evidence_ids"] as? [String], !ids.isEmpty,
                  ids.allSatisfy({ evidenceIDs[$0]?.hasPrefix(sourceID.uuidString) == true }) else {
                return .error("Worker findings require existing evidence IDs from the assigned source")
            }
        }
        let ids = Set(findings.flatMap { $0["evidence_ids"] as? [String] ?? [] })
        let referenceIDs = Set(ids.compactMap { evidenceIDs[$0] })
        let foundReferences = references.filter { referenceIDs.contains($0.id) }
        data["evidence_index"] = foundReferences.prefix(24).map(evidenceIndexRow)
        data["evidence_index_complete"] = foundReferences.count <= 24
        let associatedPayloads = payloads.compactMap { handle, payload -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let citations = object["citations"] as? [[String: Any]],
                  citations.contains(where: { ($0["evidence_id"] as? String).map(ids.contains) == true }) else { return nil }
            return handle
        }.sorted()
        data["evidence_payload_refs"] = Array(associatedPayloads.prefix(8))
        data["evidence_payload_refs_complete"] = associatedPayloads.count <= 8
        data["evidence_reading"] = "Index excerpts are bounded. Use read_payload and its next_cursor for original observations, or read source context to verify findings."
        data["session_id"] = sourceID.uuidString
        data["coverage"] = ["reads": readCoverage[sourceID] ?? [], "semantic_completeness": "not mechanically established"]
        return record(data)
    }

    func allowCall(_ key: String) -> Bool {
        repeatedCalls[key, default: 0] += 1
        return repeatedCalls[key, default: 0] <= 2
    }

    func citations() -> [KnowledgeSourceRef] { references }

    func readPayload(_ handle: String, offset: Int, allowedSources: Set<UUID>? = nil) -> KnowledgeToolObservation {
        guard let payload = payloads[handle], offset >= 0, offset <= payload.count else {
            return .error("Unknown payload or invalid offset")
        }
        if let allowedSources {
            guard let data = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                return .error("Invalid saved payload")
            }
            let refs = (data["citations"] as? [[String: Any]] ?? []).compactMap(KnowledgeJSON.reference)
            let source = (data["session_id"] as? String).flatMap(UUID.init(uuidString:))
            // Source workers may recover only payloads with explicit evidence from
            // their assigned source; global analysis/aggregate handles stay private.
            guard source.map({ allowedSources.contains($0) }) ?? !refs.isEmpty,
                  refs.allSatisfy({ $0.sessionUUID.map { allowedSources.contains($0) } == true }) else {
                return .error("Payload is outside this task's authorized sources")
            }
        }
        let page = String(payload.dropFirst(offset).prefix(8_000))
        return KnowledgeToolObservation(json: KnowledgeJSON.encode([
            "payload_ref": handle, "text": page, "offset": offset, "total_characters": payload.count,
            "complete": offset + page.count == payload.count,
            "next_cursor": offset + page.count < payload.count ? offset + page.count : NSNull(),
        ]), isError: false, citations: references)
    }

    func updateAnalysis(_ json: String) throws -> KnowledgeToolObservation {
        guard let args = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw KnowledgeToolError.invalidParameter("Analysis must be an object")
        }
        if let dimensions = args["dimensions"] as? [String], let ids = args["session_ids"] as? [String] {
            let parsed = ids.compactMap(UUID.init(uuidString:))
            guard !dimensions.isEmpty, dimensions.count <= 12, parsed.count == ids.count, !parsed.isEmpty,
                  parsed.allSatisfy({ snapshot.generations[$0] != nil }), parsed.count <= 100 else {
                throw KnowledgeToolError.invalidParameter("Analysis needs visible sources and 1–12 dimensions")
            }
            if analysis?.sourceIDs != parsed || analysis?.dimensions != dimensions {
                var next = KnowledgeAnalysisView(sourceIDs: parsed, dimensions: dimensions)
                if let prior = analysis {
                    for index in next.cells.indices {
                        if let old = prior.cells.first(where: { $0.sourceID == next.cells[index].sourceID && $0.dimension == next.cells[index].dimension }) {
                            next.cells[index] = old
                        }
                    }
                }
                analysis = next
            }
        }
        guard var view = analysis else { throw KnowledgeToolError.invalidParameter("Initialize dimensions and session_ids first") }
        for row in args["cells"] as? [[String: Any]] ?? [] {
            guard let id = (row["session_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let dimension = row["dimension"] as? String,
                  let status = (row["status"] as? String).flatMap(KnowledgeAnalysisCell.Status.init(rawValue:)),
                  let index = view.cells.firstIndex(where: { $0.sourceID == id && $0.dimension == dimension }) else {
                throw KnowledgeToolError.invalidParameter("Invalid analysis source, dimension or status")
            }
            let ids = row["evidence_ids"] as? [String] ?? []
            guard ids.allSatisfy({ evidenceIDs[$0] != nil }),
                  ids.allSatisfy({ evidenceIDs[$0]?.hasPrefix(id.uuidString) == true }),
                  ![.supported, .conflict, .absent].contains(status) || !ids.isEmpty else {
                throw KnowledgeToolError.invalidParameter("Findings require existing evidence IDs from that source")
            }
            view.cells[index].status = status
            view.cells[index].finding = row["finding"] as? String ?? ""
            view.cells[index].evidenceIDs = ids
        }
        analysis = view
        let data = try JSONEncoder().encode(view)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return record(["analysis": json, "unresolved_count": view.cells.filter {
            [.unchecked, .notFound, .conflict, .unavailable].contains($0.status)
        }.count])
    }
}

/// Conversation-only raw evidence reuse. Authorization, full source versions,
/// scope and exact arguments form the key; provider-private state is never cached.
actor KnowledgeEvidenceCache {
    static let shared = KnowledgeEvidenceCache()
    private var entries: [String: KnowledgeToolObservation] = [:]
    private var order: [String] = []
    private var memories: [String: KnowledgeWorkspaceMemory] = [:]
    private var memoryOrder: [String] = []

    func memory(_ key: String) -> KnowledgeWorkspaceMemory? { memories[key] }
    func saveMemory(_ memory: KnowledgeWorkspaceMemory, key: String) {
        if memories[key] == nil { memoryOrder.append(key) }
        memories[key] = memory
        while memoryOrder.count > 8 { memories.removeValue(forKey: memoryOrder.removeFirst()) }
    }

    func get(_ key: String) -> KnowledgeToolObservation? { entries[key] }
    func put(_ value: KnowledgeToolObservation, key: String) {
        guard !value.isError else { return }
        if entries[key] == nil { order.append(key) }
        entries[key] = value
        while order.count > 64 { entries.removeValue(forKey: order.removeFirst()) }
    }
}
