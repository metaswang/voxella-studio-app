import Foundation
import MCP

/// Presentation state is addressed explicitly, never by the shared MCP connection.
/// Source content and authorization remain owned by the canonical evidence service.
actor MCPWorkspaceStore {
    struct Operation: Sendable {
        let workspaceID: String
        let turnID: String
        let id: UUID
        let snapshot: KnowledgeScopeSnapshot
    }
    private struct Turn {
        let id: String
        let query: String
        let snapshot: KnowledgeScopeSnapshot
        let scope: Value
        var pending: Set<UUID> = []
        var candidates: [Value] = []
        var reads: [Value] = []
        var observations: [String: Value] = [:]
        var evidence: Set<String> = []
        var citedEvidence: [String] = []
        var citedObservations: [String] = []
        var outcome: String?
        var error: String?
        var frozenView: [String: Value]?
    }
    private struct Workspace {
        let id: String
        let access: KnowledgeScopeSnapshot
        var touched = Date()
        var revision = 1
        var viewRevision = 0
        var view: [String: Value] = ["pinned": false]
        var nextScope: Value = .object([:])
        var readingSnapshot: KnowledgeScopeSnapshot?
        var active: String?
        var turns: [String: Turn] = [:]
        var order: [String] = []
        var receipts: [String: (Value, String)] = [:]
    }
    private var workspaces: [String: Workspace] = [:]
    private let idleSeconds: TimeInterval
    private let capacity: Int
    init(idleSeconds: TimeInterval = 3600, capacity: Int = 64) {
        self.idleSeconds = idleSeconds; self.capacity = capacity
    }
    private func checked(_ id: String, touch: Bool = true) async throws -> Workspace {
        prune()
        guard let workspace = workspaces[id] else { throw WorkspaceError("workspace_expired", "Workspace expired. Reopen the panel or start a new question.") }
        do { try await workspace.access.validateAccess() }
        catch { workspaces.removeValue(forKey: id); throw WorkspaceError("authorization_changed", "Account access changed. Reopen this workspace.") }
        guard var current = workspaces[id] else { throw WorkspaceError("workspace_expired", "Workspace expired.") }
        if touch { current.touched = Date(); workspaces[id] = current }
        return current
    }
    private func prune() {
        let now = Date()
        workspaces = workspaces.filter { now.timeIntervalSince($0.value.touched) < idleSeconds }
    }
    func clear() { workspaces.removeAll() }
    func receiptWorkspace(requestID: String) async throws -> String? {
        prune()
        guard let id = workspaces.first(where: { $0.value.receipts[requestID] != nil })?.key else { return nil }
        _ = try await checked(id)
        return id
    }
    func open(id: String?, snapshot: KnowledgeScopeSnapshot) async throws -> Value {
        if let id { return try await state(id: id, turnID: nil, after: nil) }
        prune()
        if workspaces.count >= capacity, let oldest = workspaces.min(by: { $0.value.touched < $1.value.touched })?.key { workspaces.removeValue(forKey: oldest) }
        let id = UUID().uuidString
        workspaces[id] = Workspace(id: id, access: snapshot)
        return render(workspaces[id]!, turn: nil)
    }
    func resumeBegin(id: String, requestID: String, query: String, scope: Value?) async throws -> Value? {
        let workspace = try await checked(id)
        guard let receipt = workspace.receipts[requestID], let turn = workspace.turns[receipt.1] else { return nil }
        guard turn.query == query, scope == nil || turn.scope == scope else { throw WorkspaceError("request_conflict", "request_id already belongs to another question") }
        try await turn.snapshot.validate()
        return render(try await checked(id), turn: turn, historical: true)
    }
    func nextScope(id: String) async throws -> Value { try await checked(id).nextScope }
    // Continue a catalog shown by a frozen question without reopening the turn
    // or changing its observations/citations. The cursor keeps its original scope.
    func listingPage(id: String, turnID: String, observationID: String, cursor: String) async throws -> (KnowledgeScopeSnapshot, [String: Value]) {
        let workspace = try await checked(id, touch: false)
        guard let turn = workspace.turns[turnID],
              let observation = turn.observations[observationID]?.objectValue,
              observation["tool"]?.stringValue == "list_sources",
              var arguments = observation["arguments"]?.objectValue else {
            throw WorkspaceError("invalid_page", "The session list is unavailable; reopen it.")
        }
        try await turn.snapshot.validate()
        arguments["cursor"] = .string(cursor)
        return (turn.snapshot, arguments)
    }
    func begin(id: String, query: String, scope: Value, snapshot: KnowledgeScopeSnapshot, requestID: String) async throws -> Value {
        _ = try await checked(id)
        try await snapshot.validate()
        var workspace = try await checked(id)
        let fingerprint: Value = .object(["query": .string(query), "scope": scope])
        if let receipt = workspace.receipts[requestID] {
            guard receipt.0 == fingerprint else { throw WorkspaceError("request_conflict", "request_id already belongs to another question") }
            guard let turn = workspace.turns[receipt.1] else { throw WorkspaceError("turn_expired", "Question expired; use a new request_id.") }
            return render(workspace, turn: turn)
        }
        let turnID = UUID().uuidString
        if let active = workspace.active, var previous = workspace.turns[active], previous.outcome == nil {
            previous.frozenView = workspace.view
            workspace.turns[active] = previous
        }
        workspace.turns[turnID] = Turn(id: turnID, query: query, snapshot: snapshot, scope: scope)
        workspace.active = turnID; workspace.order.append(turnID)
        workspace.receipts[requestID] = (fingerprint, turnID)
        if workspace.view["pinned"]?.boolValue != true {
            workspace.viewRevision += 1
            workspace.readingSnapshot = nil
            for key in ["source_id", "evidence_id", "manual_turn_id", "anchor", "material", "language", "reading_view"] { workspace.view.removeValue(forKey: key) }
        }
        workspace.revision += 1
        // Keep recent immutable card snapshots bounded as well as workspace count.
        while workspace.order.count > 64 {
            let old = workspace.order.removeFirst(); workspace.turns.removeValue(forKey: old)
            workspace.receipts = workspace.receipts.filter { $0.value.1 != old }
        }
        workspaces[id] = workspace
        return render(workspace, turn: workspace.turns[turnID])
    }
    func startOperation(id: String, turnID: String) async throws -> Operation {
        let workspace = try await checked(id)
        guard let turn = workspace.turns[turnID] else { throw WorkspaceError("turn_expired", "Question is unavailable") }
        try await turn.snapshot.validate()
        var current = try await checked(id)
        guard var latest = current.turns[turnID] else { throw WorkspaceError("turn_expired", "Question is unavailable") }
        let operation = Operation(workspaceID: id, turnID: turnID, id: UUID(), snapshot: turn.snapshot)
        if latest.outcome == nil { latest.pending.insert(operation.id); current.turns[turnID] = latest; current.revision += 1; workspaces[id] = current }
        return operation
    }
    func record(_ operation: Operation, name: String, arguments: [String: Value], result: Value, isError: Bool) async throws -> String? {
        var workspace = try await checked(operation.workspaceID)
        guard var turn = workspace.turns[operation.turnID] else { return nil }
        guard turn.outcome == nil else { return nil }
        turn.pending.remove(operation.id)
        if isError { turn.error = result.objectValue?["error"]?.stringValue ?? "Evidence read failed" }
        else {
            try await operation.snapshot.validate()
            // Authorization validation awaits; reread state to preserve concurrent results.
            workspace = try await checked(operation.workspaceID)
            guard let latest = workspace.turns[operation.turnID], latest.outcome == nil else { return nil }
            turn = latest; turn.pending.remove(operation.id)
            let observation = UUID().uuidString
            guard turn.observations.count < 256 else { throw WorkspaceError("turn_limit", "Evidence operation limit reached; start another question") }
            turn.observations[observation] = .object(["tool": .string(name), "arguments": .object(arguments), "sequence": .int(turn.observations.count), "result": result])
            let rows = result.objectValue?["results"]?.arrayValue ?? result.objectValue?["sources"]?.arrayValue ?? []
            if name == "search" { turn.candidates = deduplicated(turn.candidates + rows) }
            if name == "fetch" {
                let segments = result.objectValue?["segments"]?.arrayValue ?? []
                turn.reads = deduplicated(turn.reads + segments)
                turn.evidence.formUnion(segments.compactMap { $0.objectValue?["evidence_id"]?.stringValue })
                if !segments.isEmpty, let requested = arguments["evidence_id"]?.stringValue { turn.evidence.insert(requested) }
                // Select deterministically only when the highest-ranked source has a verified span.
                if workspace.active == operation.turnID, workspace.view["pinned"]?.boolValue != true,
                   workspace.view["manual_turn_id"]?.stringValue != operation.turnID, workspace.view["source_id"] == nil {
                    let firstSource = turn.candidates.first?.objectValue?["source_id"]?.stringValue
                    let selected = turn.reads.first { firstSource == nil || $0.objectValue?["source_id"]?.stringValue == firstSource }
                    if let selected {
                        workspace.view["source_id"] = selected.objectValue?["source_id"]
                        workspace.view["evidence_id"] = selected.objectValue?["evidence_id"]
                        workspace.readingSnapshot = operation.snapshot
                        workspace.viewRevision += 1
                    }
                }
            }
            workspace.turns[operation.turnID] = turn; workspace.revision += 1
            workspaces[workspace.id] = workspace
            return observation
        }
        workspace.turns[operation.turnID] = turn; workspace.revision += 1; workspaces[workspace.id] = workspace
        return nil
    }
    func finish(id: String, turnID: String, evidence: [String], observations: [String], outcome: String) async throws -> Value {
        let initial = try await checked(id)
        guard let turn = initial.turns[turnID] else { throw WorkspaceError("turn_expired", "Question is unavailable") }
        try await turn.snapshot.validate()
        var workspace = try await checked(id)
        guard var current = workspace.turns[turnID] else { throw WorkspaceError("turn_expired", "Question is unavailable") }
        guard ["answered", "no_evidence", "clarification", "failed"].contains(outcome) else { throw WorkspaceError("invalid_argument", "Invalid outcome") }
        guard Set(evidence).isSubset(of: current.evidence), observations.allSatisfy({ ["fetch", "aggregate", "list_sources", "find_text"].contains(current.observations[$0]?.objectValue?["tool"]?.stringValue ?? "") }) else {
            throw WorkspaceError("unread_evidence", "Only successfully read evidence and observations from this turn can be cited")
        }
        if let prior = current.outcome {
            guard prior == outcome, current.citedEvidence == evidence, current.citedObservations == observations else { throw WorkspaceError("turn_finished", "Completed question is immutable") }
        } else {
            // If the top candidate could not be read, select the best source that
            // was actually checked. Do this once, after all answer reads are known.
            if workspace.active == turnID, workspace.view["source_id"] == nil,
               workspace.view["pinned"]?.boolValue != true,
               workspace.view["manual_turn_id"]?.stringValue != turnID,
               let selected = primaryRead(current) {
                workspace.view["source_id"] = selected.objectValue?["source_id"]
                workspace.view["evidence_id"] = selected.objectValue?["evidence_id"]
                workspace.readingSnapshot = current.snapshot
                workspace.viewRevision += 1
            }
            var snapshotView = workspace.active == turnID ? workspace.view : (current.frozenView ?? ["pinned": false])
            if snapshotView["source_id"] == nil, let selected = primaryRead(current) {
                snapshotView["source_id"] = selected.objectValue?["source_id"]
                snapshotView["evidence_id"] = selected.objectValue?["evidence_id"]
            }
            current.frozenView = snapshotView
            current.outcome = outcome; current.citedEvidence = evidence; current.citedObservations = observations
            current.pending.removeAll(); workspace.turns[turnID] = current; workspace.revision += 1; workspaces[id] = workspace
        }
        return render(workspace, turn: current)
    }
    func updateView(id: String, expected: Int, values: [String: Value]) async throws -> Value {
        var workspace = try await checked(id)
        guard expected == workspace.viewRevision else { throw WorkspaceError("view_conflict", "Reading position changed; refresh before updating") }
        let allowed = Set(["source_id", "evidence_id", "material", "language", "anchor", "pinned", "manual_turn_id", "next_scope", "reading_view"])
        guard Set(values.keys).isSubset(of: allowed) else { throw WorkspaceError("invalid_argument", "Unknown view field") }
        for (key, value) in values {
            let valid: Bool
            switch key {
            case "source_id", "evidence_id", "manual_turn_id": valid = value.isNull || value.stringValue != nil
            case "material": valid = ["canonical", "subtitles", "translation"].contains(value.stringValue ?? "")
            case "reading_view": valid = ["body", "summary"].contains(value.stringValue ?? "")
            case "language": valid = value.stringValue != nil
            case "anchor": valid = (value.intValue ?? -1) >= 0
            case "pinned": valid = value.boolValue != nil
            case "next_scope": valid = value.objectValue != nil
            default: valid = false
            }
            guard valid else { throw WorkspaceError("invalid_argument", "Invalid view field: " + key) }
        }
        if let source = values["source_id"]?.stringValue {
            let live = workspace.access.isLive ? await KnowledgeScopeSnapshot.capture(scope: .all, origins: nil) : workspace.access
            guard live.sessions.contains(where: { $0.id.uuidString == source }) else { throw WorkspaceError("unauthorized_source", "Session is unavailable") }
            try await live.validate()
            workspace = try await checked(id)
            workspace.readingSnapshot = KnowledgeScopeSnapshot(scope: .session(UUID(uuidString: source)!), ownerID: live.ownerID, sessions: live.sessions.filter { $0.id.uuidString == source }, generations: live.generations, authorizationGeneration: live.authorizationGeneration, isLive: live.isLive)
            guard expected == workspace.viewRevision else { throw WorkspaceError("view_conflict", "Reading position changed; refresh before updating") }
        }
        if let scope = values["next_scope"] { _ = try MCPWorkspaceTools.scope(scope); workspace.nextScope = scope }
        for (key, value) in values where key != "next_scope" {
            if value.isNull { workspace.view.removeValue(forKey: key) } else { workspace.view[key] = value }
        }
        if let evidence = workspace.view["evidence_id"]?.stringValue {
            let locator = try MCPKnowledgeBaseTools.Locator.decode(evidence)
            guard workspace.view["source_id"]?.stringValue == locator.sourceID.uuidString else { throw WorkspaceError("invalid_argument", "Evidence and reading source must match") }
        }
        workspace.viewRevision += 1; workspace.revision += 1; workspaces[id] = workspace
        return render(workspace, turn: workspace.active.flatMap { workspace.turns[$0] })
    }
    func state(id: String, turnID: String?, after: Int?) async throws -> Value {
        let workspace = try await checked(id, touch: false)
        let selected = turnID ?? workspace.active
        let turn = selected.flatMap { workspace.turns[$0] }
        if selected != nil, turn == nil { throw WorkspaceError("turn_expired", "Question snapshot expired") }
        if let turn { try await turn.snapshot.validate() }
        if turnID == nil, let reading = workspace.readingSnapshot { try await reading.validate() }
        // A poll never extends the lifetime or serves data after account changes.
        let current = try await checked(id, touch: false)
        // Validation can yield while the next question starts. Never associate
        // the old question's content with the new workspace revision.
        if turnID == nil, current.active != workspace.active { return try await state(id: id, turnID: nil, after: after) }
        if after == current.revision { return .object(["workspace_id": .string(id), "revision": .int(current.revision), "unchanged": true]) }
        return render(current, turn: selected.flatMap { current.turns[$0] }, historical: turnID != nil)
    }
    private func deduplicated(_ rows: [Value]) -> [Value] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = row.objectValue?["evidence_id"]?.stringValue ?? row.objectValue?["source_id"]?.stringValue ?? String(describing: row)
            return seen.insert(key).inserted
        }.prefix(128).map { $0 }
    }
    private func primaryRead(_ turn: Turn) -> Value? {
        for candidate in turn.candidates {
            if let source = candidate.objectValue?["source_id"]?.stringValue,
               let read = turn.reads.first(where: { $0.objectValue?["source_id"]?.stringValue == source }) { return read }
        }
        return turn.reads.first
    }
    private func render(_ workspace: Workspace, turn: Turn?, historical: Bool = false) -> Value {
        var result: [String: Value] = ["workspace_id": .string(workspace.id), "revision": .int(workspace.revision),
            "view_revision": .int(workspace.viewRevision), "view": .object(historical ? (turn?.frozenView ?? workspace.view) : workspace.view), "next_scope": workspace.nextScope,
            "active_turn_id": workspace.active.map(Value.string) ?? .null, "status": "idle", "complete": true]
        if let turn {
            result.merge(["turn_id": .string(turn.id), "query": .string(turn.query), "scope": turn.scope,
                "status": .string(turn.outcome ?? (turn.pending.isEmpty ? "sources_ready" : "retrieving")),
                "complete": .bool(turn.outcome != nil), "candidates": .array(turn.candidates), "read_evidence": .array(turn.reads),
                "cited_evidence_ids": .array(turn.citedEvidence.map(Value.string)),
                "cited_observation_ids": .array(turn.citedObservations.map(Value.string)),
                "observations": .object(turn.observations), "error": turn.error.map(Value.string) ?? .null]) { _, new in new }
        }
        return .object(result)
    }
}

struct WorkspaceError: LocalizedError, Sendable {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
