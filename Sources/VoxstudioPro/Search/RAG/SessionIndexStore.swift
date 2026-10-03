import Foundation

actor SessionIndexStore {
    static let embeddingDimension = SearchIndexConfig.embeddingDimension
    static let lexicalLimit = 30
    static let vectorLimit = 30

    let sqlite: SessionSQLite

    init(url: URL) throws {
        sqlite = try SessionSQLite(url: url)
        try sqlite.execute(Self.schemaSQL)
        // Existing DBs created before origin columns: additive migration (DEFAULT local).
        let columns = try sqlite.query("PRAGMA table_info(sessions)").compactMap { $0.text("name") }
        if !columns.contains("source_origin") {
            try sqlite.execute(
                "ALTER TABLE sessions ADD COLUMN source_origin TEXT NOT NULL DEFAULT 'local'"
            )
        }
        if !columns.contains("remote_session_id") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN remote_session_id TEXT")
        }
        if !columns.contains("owner_user_id") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN owner_user_id TEXT")
        }
        if !columns.contains("indexed_at") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN indexed_at REAL")
        }
        if !columns.contains("session_type") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN session_type TEXT NOT NULL DEFAULT 'upload'")
        }
        if !columns.contains("source_created_at") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN source_created_at REAL")
        }
        if !columns.contains("source_modified_at") {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN source_modified_at REAL")
        }
        for (name, type) in [("media_duration_sec", "REAL"), ("last_spoken_end_sec", "REAL"),
                             ("transcribed_start_sec", "REAL"), ("transcribed_end_sec", "REAL"),
                             ("duration_provenance", "TEXT NOT NULL DEFAULT 'legacy_unknown'")] where !columns.contains(name) {
            try sqlite.execute("ALTER TABLE sessions ADD COLUMN \(name) \(type)")
        }
        try sqlite.execute(
            "UPDATE sessions SET source_modified_at = source_mtime WHERE source_modified_at IS NULL AND source_mtime IS NOT NULL"
        )
        // Legacy rows have no original creation field. Preserve the best
        // available source timestamp so catalog consumers never confuse a
        // missing date with the index rebuild time.
        try sqlite.execute(
            "UPDATE sessions SET source_created_at = COALESCE(source_created_at, source_mtime, created_at) WHERE source_created_at IS NULL"
        )
        let unitColumns = try sqlite.query("PRAGMA table_info(units)").compactMap { $0.text("name") }
        let graphColumns = try sqlite.query("PRAGMA table_info(graph_source_state)").compactMap { $0.text("name") }
        if !graphColumns.contains("source_manifest") { try sqlite.execute("ALTER TABLE graph_source_state ADD COLUMN source_manifest TEXT") }
        for (name, type) in [("body_generation", "TEXT"), ("provenance", "TEXT"), ("material_role", "TEXT"), ("revision", "TEXT"),
                             ("char_start", "INTEGER"), ("char_end", "INTEGER"), ("timing_precision", "TEXT"), ("context", "TEXT"), ("spans_json", "TEXT")] where !unitColumns.contains(name) {
            try sqlite.execute("ALTER TABLE units ADD COLUMN \(name) \(type)")
        }
    }

    @discardableResult
    func replaceLexical(snapshot: SessionIndexSnapshot, clips: [CuePacker.Clip], force: Bool = false) throws -> Bool {
        try sqlite.transaction {
            let oldKnowledge = try laneManifest(sessionID: snapshot.sessionID, lane: "knowledge")
            let oldMedia = try laneManifest(sessionID: snapshot.sessionID, lane: "media")
            let knowledgeChanged = force || oldKnowledge != snapshot.knowledgeManifest
            let adoptLegacyMedia: Bool
            if oldMedia == nil { adoptLegacyMedia = try legacyMediaMatches(snapshot: snapshot, clips: clips) }
            else { adoptLegacyMedia = false }
            let mediaChanged = !adoptLegacyMedia && oldMedia != snapshot.mediaManifest
            let now = Date().timeIntervalSince1970
            try sqlite.run(
                """
                INSERT INTO sessions(
                    id, title, tag, summary_markdown, language, duration_sec, has_video,
                    media_path, source_mtime, ingest_generation, lexical_ready, embedding_ready,
                    created_at, modified_at, source_origin, remote_session_id, owner_user_id, indexed_at,
                    session_type, source_created_at, source_modified_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, tag=excluded.tag, summary_markdown=excluded.summary_markdown,
                    language=excluded.language, duration_sec=excluded.duration_sec, has_video=excluded.has_video, media_path=excluded.media_path,
                    source_mtime=excluded.source_mtime, ingest_generation=excluded.ingest_generation, lexical_ready=1,
                    source_origin=excluded.source_origin, remote_session_id=excluded.remote_session_id, owner_user_id=excluded.owner_user_id,
                    indexed_at=excluded.indexed_at, session_type=excluded.session_type, source_created_at=excluded.source_created_at,
                    source_modified_at=excluded.source_modified_at, modified_at=excluded.modified_at
                """,
                binds: [
                    .text(snapshot.sessionID.uuidString),
                    .text(snapshot.title),
                    .optional(snapshot.tag),
                    .optional(snapshot.summaryMarkdown),
                    .optional(snapshot.language),
                    .double(snapshot.duration),
                    .bool(snapshot.hasVideo),
                    .text(snapshot.mediaPath),
                    .optional(snapshot.sourceMTime),
                    .int(snapshot.generation),
                    .double(snapshot.sourceCreatedAt ?? now),
                    .double(snapshot.sourceModifiedAt ?? snapshot.sourceMTime ?? now),
                    .text(snapshot.sourceOrigin.rawValue),
                    .optional(snapshot.remoteSessionID?.uuidString),
                    .optional(snapshot.ownerUserID),
                    .double(now),
                    .text(snapshot.sessionType.rawValue),
                    .optional(snapshot.sourceCreatedAt),
                    .optional(snapshot.sourceModifiedAt ?? snapshot.sourceMTime),
                ]
            )
            try patchDurationFacts(snapshot: snapshot)
            try sqlite.run("DELETE FROM speakers WHERE session_id = ?", binds: [.text(snapshot.sessionID.uuidString)])
            for speaker in snapshot.speakers {
                try sqlite.run(
                    "INSERT INTO speakers(session_id, label, display_name) VALUES (?, ?, ?)",
                    binds: [
                        .text(snapshot.sessionID.uuidString),
                        .text(speaker.label),
                        .text(speaker.displayName),
                    ]
                )
            }

            let cardText = sessionCardText(snapshot)
            let previousCard = try sqlite.query("SELECT id, text FROM units WHERE session_id = ? AND kind = 'session_card'", binds: [.text(snapshot.sessionID.uuidString)]).first
            let cardID: Int
            if let id = previousCard?.int("id") {
                cardID = id
                if previousCard?.text("text") != cardText {
                    try sqlite.run("UPDATE units SET text = ? WHERE id = ?", binds: [.text(cardText), .int(id)])
                    try sqlite.run("DELETE FROM vec_text WHERE unit_id = ?", binds: [.int(id)])
                    try sqlite.run("DELETE FROM units_fts WHERE rowid = ?", binds: [.int(id)])
                    try sqlite.run("INSERT INTO units_fts(rowid, text, translation_text, title, summary) VALUES (?, ?, NULL, ?, ?)",
                                   binds: [.int(id), .text(KnowledgeLexicalTerms.indexText(cardText)), .text(KnowledgeLexicalTerms.indexText(snapshot.title)), .optional(snapshot.summaryMarkdown.map(KnowledgeLexicalTerms.indexText))])
                }
            } else {
                cardID = try insertUnit(snapshot: snapshot, kind: .sessionCard, start: nil, end: nil, speaker: nil,
                    speakers: snapshot.speakers.map(\.label), text: cardText, cueIDs: [], parentID: nil, modality: .text, title: snapshot.title, summary: snapshot.summaryMarkdown)
            }
            if knowledgeChanged {
                try deleteGraphSource(sessionID: snapshot.sessionID)
                try deleteUnits(sessionID: snapshot.sessionID, kind: .transcriptChunk)
            }
            if mediaChanged { try deleteUnits(sessionID: snapshot.sessionID, kind: .mediaClip) }
            if adoptLegacyMedia {
                // Upgrade lexical tokenization without replacing media IDs or vectors.
                let rows = try sqlite.query("SELECT id,text FROM units WHERE session_id=? AND kind='media_clip'",
                                            binds: [.text(snapshot.sessionID.uuidString)])
                for row in rows {
                    guard let id = row.int("id"), let text = row.text("text") else { continue }
                    try sqlite.run("DELETE FROM units_fts WHERE rowid=?", binds: [.int(id)])
                    try sqlite.run("INSERT INTO units_fts(rowid,text,translation_text,title,summary) VALUES (?,?,NULL,?,NULL)",
                                   binds: [.int(id), .text(KnowledgeLexicalTerms.indexText(text)), .text(KnowledgeLexicalTerms.indexText(snapshot.title))])
                }
            }
            if knowledgeChanged, let body = snapshot.selectedBody {
                for chunk in snapshot.preparedChunks ?? KnowledgeBodyChunker.pack(body) {
                    let id = try insertUnit(snapshot: snapshot, kind: .transcriptChunk, start: chunk.start, end: chunk.end,
                        speaker: chunk.speakers.first, speakers: chunk.speakers, text: chunk.text,
                        cueIDs: chunk.spans.compactMap(\.cueID), parentID: cardID, modality: .text, title: snapshot.title, summary: nil)
                    let spansJSON = String(decoding: try JSONEncoder().encode(chunk.spans), as: UTF8.self)
                    try sqlite.run("UPDATE units SET body_generation=?, provenance=?, material_role=?, revision=?, char_start=?, char_end=?, timing_precision=?, context=?, spans_json=? WHERE id=?",
                        binds: [.text(body.generation), .text(body.provenance), .text(body.role), .optional(body.revision), .int(chunk.lower), .int(chunk.upper), .text(chunk.timingPrecision), .text(chunk.context), .text(spansJSON), .int(id)])
                }
            }
            for clip in mediaChanged ? clips : [] {
                let modality: SessionIndexModality = snapshot.hasVideo
                    ? (clip.text.isEmpty ? .video : .mixed)
                    : .text
                try insertUnit(
                    snapshot: snapshot,
                    kind: .mediaClip,
                    start: clip.start,
                    end: clip.end,
                    speaker: clip.speakerLabels.first,
                    speakers: clip.speakerLabels,
                    text: clip.text,
                    cueIDs: clip.cueIDs,
                    parentID: cardID,
                    modality: modality,
                    title: snapshot.title,
                    summary: nil
                )
            }
            for (lane, manifest, changed) in [("knowledge", snapshot.knowledgeManifest, knowledgeChanged), ("media", snapshot.mediaManifest, mediaChanged)] {
                try sqlite.run("INSERT INTO index_lane_state(session_id,lane,manifest,lexical_ready,embedding_ready) VALUES (?,?,?,1,0) ON CONFLICT(session_id,lane) DO UPDATE SET manifest=excluded.manifest, lexical_ready=1, embedding_ready=CASE WHEN ? THEN 0 ELSE index_lane_state.embedding_ready END",
                    binds: [.text(snapshot.sessionID.uuidString), .text(lane), .text(manifest), .bool(changed)])
            }
            if knowledgeChanged || mediaChanged || previousCard?.text("text") != cardText {
                try sqlite.run("UPDATE sessions SET embedding_ready=0 WHERE id=?", binds: [.text(snapshot.sessionID.uuidString)])
            }
            return knowledgeChanged
        }
    }

    func patchSessionCard(snapshot: SessionIndexSnapshot) throws {
        try sqlite.transaction {
            try sqlite.run(
                """
                UPDATE sessions SET title = ?, tag = ?, summary_markdown = ?,
                    session_type = ?, source_created_at = ?, source_modified_at = ?, source_mtime = ?,
                    source_origin = ?, remote_session_id = ?, owner_user_id = ?, indexed_at = ?
                WHERE id = ?
                """,
                binds: [
                    .text(snapshot.title),
                    .optional(snapshot.tag),
                    .optional(snapshot.summaryMarkdown),
                    .text(snapshot.sessionType.rawValue),
                    .optional(snapshot.sourceCreatedAt),
                    .optional(snapshot.sourceModifiedAt ?? snapshot.sourceMTime),
                    .optional(snapshot.sourceModifiedAt ?? snapshot.sourceMTime),
                    .text(snapshot.sourceOrigin.rawValue),
                    .optional(snapshot.remoteSessionID?.uuidString),
                    .optional(snapshot.ownerUserID),
                    .double(Date().timeIntervalSince1970),
                    .text(snapshot.sessionID.uuidString),
                ]
            )
            let rows = try sqlite.query(
                "SELECT id FROM units WHERE session_id = ? AND kind = ?",
                binds: [.text(snapshot.sessionID.uuidString), .text(SessionIndexUnitKind.sessionCard.rawValue)]
            )
            guard let unitID = rows.first?.int("id") else { return }
            let text = sessionCardText(snapshot)
            try sqlite.run(
                "UPDATE units SET text = ? WHERE id = ?",
                binds: [.text(text), .int(unitID)]
            )
            try sqlite.run("DELETE FROM vec_text WHERE unit_id = ?", binds: [.int(unitID)])
            try sqlite.run(
                "UPDATE sessions SET embedding_ready = 0, indexed_at = ? WHERE id = ?",
                binds: [.double(Date().timeIntervalSince1970), .text(snapshot.sessionID.uuidString)]
            )
            try sqlite.run("DELETE FROM units_fts WHERE rowid = ?", binds: [.int(unitID)])
            try sqlite.run(
                "INSERT INTO units_fts(rowid, text, translation_text, title, summary) VALUES (?, ?, ?, ?, ?)",
                binds: [
                    .int(unitID),
                    .text(KnowledgeLexicalTerms.indexText(text)),
                    .null,
                    .text(KnowledgeLexicalTerms.indexText(snapshot.title)),
                    .optional(snapshot.summaryMarkdown.map(KnowledgeLexicalTerms.indexText)),
                ]
            )
        }
    }

    func patchSpeakers(_ speakers: [SessionSpeaker], sessionID: UUID) throws {
        try sqlite.transaction {
            try sqlite.run(
                "DELETE FROM speakers WHERE session_id = ?",
                binds: [.text(sessionID.uuidString)]
            )
            for speaker in speakers {
                try sqlite.run(
                    "INSERT INTO speakers(session_id, label, display_name) VALUES (?, ?, ?)",
                    binds: [
                        .text(sessionID.uuidString),
                        .text(speaker.label),
                        .text(speaker.displayName),
                    ]
                )
            }
        }
    }

    func markEmbeddingReady(_ sessionID: UUID, ready: Bool) throws {
        for (lane, kind) in [("knowledge", SessionIndexUnitKind.transcriptChunk), ("media", .mediaClip)] {
            let remaining = try unitsNeedingEmbedding(sessionID: sessionID).contains { $0.kind == kind }
            try sqlite.run("UPDATE index_lane_state SET embedding_ready=? WHERE session_id=? AND lane=?", binds: [.bool(!remaining), .text(sessionID.uuidString), .text(lane)])
        }
        try sqlite.run(
            "UPDATE sessions SET embedding_ready = ?, indexed_at = ? WHERE id = ?",
            binds: [
                .bool(ready),
                .double(Date().timeIntervalSince1970),
                .text(sessionID.uuidString),
            ]
        )
    }

    func removeSession(_ sessionID: UUID) throws {
        try sqlite.transaction {
            try deleteSessionRows(sessionID)
        }
    }

    func freshness(sessionID: UUID, knowledgeManifest: String? = nil, mediaManifest: String? = nil) throws -> SessionIndexFreshness? {
        let rows = try sqlite.query(
            "SELECT ingest_generation, lexical_ready, embedding_ready FROM sessions WHERE id = ?",
            binds: [.text(sessionID.uuidString)]
        )
        guard let row = rows.first, let generation = row.int("ingest_generation") else { return nil }
        if let knowledgeManifest, try laneManifest(sessionID: sessionID, lane: "knowledge") != knowledgeManifest { return nil }
        if let mediaManifest, try laneManifest(sessionID: sessionID, lane: "media") != mediaManifest { return nil }
        return SessionIndexFreshness(
            generation: generation,
            lexicalReady: row.bool("lexical_ready"),
            embeddingReady: row.bool("embedding_ready")
        )
    }

    func sessionsNeedingEmbedding() throws -> [UUID] {
        try sqlite.query(
            "SELECT id FROM sessions WHERE lexical_ready = 1 AND embedding_ready = 0"
        ).compactMap { row in
            row.text("id").flatMap(UUID.init(uuidString:))
        }
    }

    func unitsNeedingEmbedding(sessionID: UUID) throws -> [SessionIndexUnitRecord] {
        let units = try loadUnits(
            sql: """
            SELECT u.* FROM units u
            WHERE u.session_id = ?
              AND u.kind IN (?, ?, ?)
            ORDER BY u.id
            """,
            binds: [
                .text(sessionID.uuidString),
                .text(SessionIndexUnitKind.sessionCard.rawValue),
                .text(SessionIndexUnitKind.transcriptChunk.rawValue),
                .text(SessionIndexUnitKind.mediaClip.rawValue),
            ]
        )
        var needed: [SessionIndexUnitRecord] = []
        for unit in units {
            if try needsEmbedding(unit) { needed.append(unit) }
        }
        return needed
    }

    func unitExists(id: Int, sessionID: UUID, text: String) throws -> Bool {
        try sqlite.query("SELECT id FROM units WHERE id=? AND session_id=? AND text=?", binds: [.int(id), .text(sessionID.uuidString), .text(text)]).first != nil
    }

    func upsertEmbedding(unitID: Int, modality: SessionIndexModality, vector: [Float]) throws {
        guard try sqlite.query("SELECT id FROM units WHERE id=?", binds: [.int(unitID)]).first != nil else { return }
        let table = vecTable(modality)
        try sqlite.run("DELETE FROM \(table) WHERE unit_id = ?", binds: [.int(unitID)])
        try sqlite.run(
            "INSERT INTO \(table)(unit_id, embedding) VALUES (?, ?)",
            binds: [.int(unitID), .blob(Self.packed(vector))]
        )
    }

    func sourceOrigin(sessionID: UUID) throws -> KnowledgeSourceOrigin? {
        let rows = try sqlite.query(
            "SELECT source_origin FROM sessions WHERE id = ?",
            binds: [.text(sessionID.uuidString)]
        )
        guard let raw = rows.first?.text("source_origin") else { return nil }
        return KnowledgeSourceOrigin(rawValue: raw) ?? .local
    }

    func sessionIDs() throws -> [UUID] {
        try sqlite.query("SELECT id FROM sessions").compactMap { row in
            row.text("id").flatMap(UUID.init(uuidString:))
        }
    }

    func sessionCard(id: UUID) throws -> SessionCard? {
        let rows = try sqlite.query(
            "SELECT * FROM sessions WHERE id = ?",
            binds: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try card(from: row)
    }

    /// Lists session metadata without requiring a text match. This powers
    /// inventory-style QA queries and index diagnostics.
    func sessionCatalog(filter: SessionSearchFilter = .init()) throws -> [SessionCatalogEntry] {
        var sql = "SELECT * FROM sessions s WHERE 1 = 1"
        var binds: [SessionSQLiteValue] = []
        sql += Self.catalogFilterSQL(filter, binds: &binds)
        sql += " ORDER BY COALESCE(s.source_modified_at, s.source_mtime, s.indexed_at, 0) DESC LIMIT ?"
        binds.append(.int(filter.limit))
        return try sqlite.query(sql, binds: binds).compactMap { row in
            guard let id = row.text("id").flatMap(UUID.init(uuidString:)),
                  let title = row.text("title") else { return nil }
            let origin = row.text("source_origin").flatMap(KnowledgeSourceOrigin.init(rawValue:)) ?? .local
            return SessionCatalogEntry(
                sessionID: id,
                title: title,
                tag: row.text("tag"),
                summaryMarkdown: row.text("summary_markdown"),
                language: row.text("language"),
                duration: row.double("duration_sec") ?? 0,
                hasVideo: row.bool("has_video"),
                mediaPath: row.text("media_path") ?? "",
                sessionType: WorkbenchSessionType(rawValue: row.text("session_type") ?? "upload") ?? .upload,
                sourceOrigin: origin,
                remoteSessionID: row.text("remote_session_id").flatMap(UUID.init(uuidString:)),
                ownerUserID: row.text("owner_user_id"),
                sourceCreatedAt: row.double("source_created_at"),
                sourceModifiedAt: row.double("source_modified_at") ?? row.double("source_mtime"),
                lexicalReady: row.bool("lexical_ready"),
                embeddingReady: row.bool("embedding_ready"),
                indexedAt: row.double("indexed_at")
            )
        }
    }

    /// Repairs identity and source metadata without rebuilding transcript units.
    func patchSessionMetadata(snapshot: SessionIndexSnapshot) throws {
        try sqlite.run(
            """
            UPDATE sessions SET title = ?, tag = ?, summary_markdown = ?, language = ?,
                duration_sec = ?, has_video = ?, media_path = ?, source_mtime = ?,
                source_origin = ?, remote_session_id = ?, owner_user_id = ?, session_type = ?,
                source_created_at = ?, source_modified_at = ?, indexed_at = ?
            WHERE id = ?
            """,
            binds: [
                .text(snapshot.title), .optional(snapshot.tag), .optional(snapshot.summaryMarkdown),
                .optional(snapshot.language), .double(snapshot.duration), .bool(snapshot.hasVideo),
                .text(snapshot.mediaPath), .optional(snapshot.sourceModifiedAt ?? snapshot.sourceMTime),
                .text(snapshot.sourceOrigin.rawValue), .optional(snapshot.remoteSessionID?.uuidString),
                .optional(snapshot.ownerUserID), .text(snapshot.sessionType.rawValue),
                .optional(snapshot.sourceCreatedAt), .optional(snapshot.sourceModifiedAt ?? snapshot.sourceMTime),
                .double(Date().timeIntervalSince1970), .text(snapshot.sessionID.uuidString),
            ]
        )
        try patchDurationFacts(snapshot: snapshot)
    }

    /// Additive metadata repair; never touches units, vectors or ingest generation.
    func patchMediaFacts(sessionID: UUID, mediaDuration: Double?, provenance: String,
                         lastSpokenEnd: Double?, transcribedStart: Double?, transcribedEnd: Double?) throws {
        try sqlite.run("""
            UPDATE sessions SET media_duration_sec = ?, duration_provenance = ?,
                last_spoken_end_sec = ?, transcribed_start_sec = ?, transcribed_end_sec = ? WHERE id = ?
            """, binds: [.optional(mediaDuration), .text(provenance), .optional(lastSpokenEnd),
                         .optional(transcribedStart), .optional(transcribedEnd), .text(sessionID.uuidString)])
    }

    func durationFacts(sessionID: UUID) throws -> (media: Double?, provenance: String, lastSpoken: Double?)? {
        guard let row = try sqlite.query("SELECT media_duration_sec, duration_provenance, last_spoken_end_sec FROM sessions WHERE id = ?",
                                         binds: [.text(sessionID.uuidString)]).first else { return nil }
        return (row.double("media_duration_sec"), row.text("duration_provenance") ?? "legacy_unknown", row.double("last_spoken_end_sec"))
    }

    private func patchDurationFacts(snapshot: SessionIndexSnapshot) throws {
        try patchMediaFacts(sessionID: snapshot.sessionID, mediaDuration: snapshot.mediaDurationSec,
            provenance: snapshot.durationProvenance, lastSpokenEnd: snapshot.lastSpokenEndSec,
            transcribedStart: snapshot.transcribedStartSec, transcribedEnd: snapshot.transcribedEndSec)
    }

    /// Actual consecutive original indexed units, independent of FTS query.
    /// Visibility and exact speaker/time filters also apply to the count query.
    func transcriptPage(filter: SessionSearchFilter, offset: Int) throws -> (hits: [SessionSearchHit], total: Int) {
        guard filter.sourceOrigins?.isEmpty != true, filter.sessionIDs?.isEmpty != true else { return ([], 0) }
        var binds: [SessionSQLiteValue] = []
        var conditions = " WHERE u.kind = 'transcript_chunk'" + Self.filterSQL(filter, binds: &binds)
        if let start = filter.start, filter.end == nil {
            conditions += " AND u.end_s >= ?"
            binds.append(.double(start))
        }
        if let end = filter.end, filter.start == nil {
            conditions += " AND u.start_s <= ?"
            binds.append(.double(end))
        }
        let from = " FROM units u JOIN sessions s ON s.id = u.session_id"
        let total = try sqlite.query("SELECT COUNT(*) AS total" + from + conditions, binds: binds).first?.int("total") ?? 0
        let sql = "SELECT u.*, s.title, s.has_video, s.language, s.source_origin, s.duration_sec" + from + conditions + " ORDER BY u.start_s, u.id LIMIT ? OFFSET ?"
        let rows = try sqlite.query(sql, binds: binds + [.int(filter.limit), .int(offset)])
        let hits = rows.compactMap { hit(from: $0, matchSource: "indexed_read", invertRank: false) }
        return (try decorateSpeakers(hits), total)
    }

    func searchLexical(
        query: String,
        kinds: [SessionIndexUnitKind],
        filter: SessionSearchFilter
    ) throws -> [SessionSearchHit] {
        let fts = Self.ftsQuery(query)
        guard !fts.isEmpty else { return [] }
        let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        var sql = """
        SELECT u.*,
               u.cue_ids, s.title, s.has_video, s.language, s.duration_sec, s.source_origin,
               s.session_type, s.source_created_at, s.source_modified_at, s.source_mtime,
               bm25(units_fts) AS rank
        FROM units_fts
        JOIN units u ON u.id = units_fts.rowid
        JOIN sessions s ON s.id = u.session_id
        WHERE units_fts MATCH ?
          AND u.kind IN (\(kindList))
        """
        var binds: [SessionSQLiteValue] = [.text(fts)]
        sql += Self.filterSQL(filter, binds: &binds)
        sql += " ORDER BY rank LIMIT ?"
        binds.append(.int(Self.lexicalLimit))
        return try decorateSpeakers(
            sqlite.query(sql, binds: binds).compactMap { row in
                hit(from: row, matchSource: "bm25", invertRank: true)
            }
        )
    }

    func searchVector(
        vector: [Float],
        modality: SessionIndexModality,
        filter: SessionSearchFilter,
        allowedKinds: [SessionIndexUnitKind]? = nil
    ) throws -> [SessionSearchHit] {
        guard filter.sessionIDs?.isEmpty != true, filter.sourceOrigins?.isEmpty != true, allowedKinds?.isEmpty != true else { return [] }
        let table = vecTable(modality)
        var sql = """
        SELECT u.*,
               u.cue_ids, s.title, s.has_video, s.language, s.duration_sec, s.source_origin,
               s.session_type, s.source_created_at, s.source_modified_at, s.source_mtime,
               v.distance AS rank
        FROM \(table) v
        JOIN units u ON u.id = v.unit_id
        JOIN sessions s ON s.id = u.session_id
        WHERE v.embedding MATCH ? AND k = ?
        """
        var binds: [SessionSQLiteValue] = [.blob(Self.packed(vector)), .int(Self.vectorLimit)]
        var eligible = "SELECT u.id FROM units u JOIN sessions s ON s.id=u.session_id WHERE 1"
        if let allowedKinds {
            eligible += " AND u.kind IN (" + allowedKinds.map { "'" + $0.rawValue + "'" }.joined(separator: ",") + ")"
        }
        eligible += Self.filterSQL(filter, binds: &binds)
        sql += " AND v.unit_id IN (" + eligible + ")"
        sql += " ORDER BY rank LIMIT ?"
        binds.append(.int(Self.vectorLimit))
        return try decorateSpeakers(
            sqlite.query(sql, binds: binds).compactMap { row in
                hit(from: row, matchSource: "vector-\(modality.rawValue)", invertRank: false)
            }
        )
    }

    func contextUnits(
        sessionID: UUID,
        kind: SessionIndexUnitKind,
        start: Double,
        end: Double
    ) throws -> [SessionSearchHit] {
        try loadUnits(
            sql: """
            SELECT u.*, s.title, s.has_video, s.language
            FROM units u
            JOIN sessions s ON s.id = u.session_id
            WHERE u.session_id = ? AND u.kind = ?
              AND u.start_s < ? AND u.end_s > ?
            ORDER BY u.start_s
            """,
            binds: [
                .text(sessionID.uuidString),
                .text(kind.rawValue),
                .double(end),
                .double(start),
            ]
        ).map { record in
            SessionSearchHit(
                sessionID: record.sessionID,
                title: record.title,
                unitID: record.id,
                kind: record.kind,
                start: record.start,
                end: record.end,
                speakerLabels: record.speakers,
                text: record.text,
                score: 0,
                matchSource: "context",
                snippet: record.text,
                cueIDs: record.cueIDs,
                hasVideo: record.hasVideo,
                language: record.language,
                quoteSpan: nil
            )
        }
    }

    func speakers(sessionID: UUID) throws -> [SessionSpeaker] {
        try sqlite.query(
            "SELECT label, display_name FROM speakers WHERE session_id = ? ORDER BY label",
            binds: [.text(sessionID.uuidString)]
        ).compactMap { row in
            guard let label = row.text("label"), let name = row.text("display_name") else { return nil }
            return SessionSpeaker(label: label, displayName: name)
        }
    }

    func resolveClip(sessionID: UUID, start: Double, end: Double) throws -> ClipCandidate? {
        guard let card = try sessionCard(id: sessionID) else { return nil }
        let clips = try contextUnits(sessionID: sessionID, kind: .mediaClip, start: start, end: end)
        let chunks = try contextUnits(sessionID: sessionID, kind: .transcriptChunk, start: start, end: end)
        let text = chunks.map(\.text).joined(separator: "\n")
        let clipText = clips.map(\.text).joined(separator: "\n")
        return ClipCandidate(
            sessionID: sessionID,
            start: start,
            end: end,
            speakerLabel: chunks.first?.speakerLabels.first ?? clips.first?.speakerLabels.first,
            text: text.isEmpty ? clipText : text,
            cueIDs: clips.flatMap(\.cueIDs),
            mediaPath: card.mediaPath
        )
    }

    @discardableResult
    private func insertUnit(
        snapshot: SessionIndexSnapshot,
        kind: SessionIndexUnitKind,
        start: Double?,
        end: Double?,
        speaker: String?,
        speakers: [String],
        text: String,
        cueIDs: [Int],
        parentID: Int?,
        modality: SessionIndexModality,
        title: String,
        summary: String?
    ) throws -> Int {
        let cueJSON = (try? String(data: JSONEncoder().encode(cueIDs), encoding: .utf8)) ?? "[]"
        let unitID = try sqlite.run(
            """
            INSERT INTO units(
                session_id, kind, start_s, end_s, speaker_label, text, translation_text,
                cue_ids, parent_id, modality
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            binds: [
                .text(snapshot.sessionID.uuidString),
                .text(kind.rawValue),
                .optional(start),
                .optional(end),
                .optional(speaker),
                .text(text),
                .null,
                .text(cueJSON),
                .optional(parentID),
                .text(modality.rawValue),
            ]
        )
        try sqlite.run(
            "INSERT INTO units_fts(rowid, text, translation_text, title, summary) VALUES (?, ?, ?, ?, ?)",
            binds: [
                .int(unitID),
                .text(KnowledgeLexicalTerms.indexText(text)),
                .null,
                .text(KnowledgeLexicalTerms.indexText(title)),
                .optional(summary.map(KnowledgeLexicalTerms.indexText)),
            ]
        )
        for label in speakers {
            try sqlite.run(
                "INSERT OR IGNORE INTO unit_speakers(unit_id, speaker_label) VALUES (?, ?)",
                binds: [.int(unitID), .text(label)]
            )
        }
        return unitID
    }

    func laneManifest(sessionID: UUID, lane: String) throws -> String? {
        try sqlite.query("SELECT manifest FROM index_lane_state WHERE session_id=? AND lane=?", binds: [.text(sessionID.uuidString), .text(lane)]).first?.text("manifest")
    }

    func mediaClip(id: Int, sessionID: UUID) throws -> SessionSearchHit? {
        try sqlite.query("SELECT u.*, s.title, s.has_video, s.language FROM units u JOIN sessions s ON s.id=u.session_id WHERE u.id=? AND u.session_id=? AND u.kind='media_clip'",
                         binds: [.int(id), .text(sessionID.uuidString)]).first.flatMap { hit(from: $0, matchSource: "media_locator", invertRank: false) }
    }

    func laneStatus(sessionID: UUID) throws -> [[String: String]] {
        try sqlite.query("SELECT * FROM index_lane_state WHERE session_id=?", binds: [.text(sessionID.uuidString)]).map {
            ["lane": $0.text("lane") ?? "", "manifest": $0.text("manifest") ?? "", "lexical_ready": String($0.bool("lexical_ready")), "embedding_ready": String($0.bool("embedding_ready"))]
        }
    }

    func embeddingChannels(sessionID: UUID) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, table) in [("text", "vec_text"), ("video", "vec_video"), ("mixed", "vec_mixed")] {
            result[name] = try sqlite.query("SELECT COUNT(*) AS count FROM \(table) v JOIN units u ON u.id=v.unit_id WHERE u.session_id=?",
                                           binds: [.text(sessionID.uuidString)]).first?.int("count") ?? 0
        }
        return result
    }

    private func legacyMediaMatches(snapshot: SessionIndexSnapshot, clips: [CuePacker.Clip]) throws -> Bool {
        guard let source = try sqlite.query("SELECT media_path,has_video,indexed_at FROM sessions WHERE id=?",
                                            binds: [.text(snapshot.sessionID.uuidString)]).first,
              source.text("media_path") == snapshot.mediaPath, source.bool("has_video") == snapshot.hasVideo,
              let indexedAt = source.double("indexed_at") else { return false }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.mediaPath),
           let modified = attributes[.modificationDate] as? Date, modified.timeIntervalSince1970 > indexedAt { return false }
        let rows = try sqlite.query("SELECT * FROM units WHERE session_id=? AND kind='media_clip' ORDER BY start_s,end_s,id",
                                    binds: [.text(snapshot.sessionID.uuidString)])
        let expected = clips.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard rows.count == expected.count else { return false }
        for (row, clip) in zip(rows, expected) {
            guard row.double("start_s") == clip.start, row.double("end_s") == clip.end,
                  row.text("text") == clip.text, Self.decodeCueIDs(row.text("cue_ids")) == clip.cueIDs,
                  row.text("modality") == (snapshot.hasVideo ? (clip.text.isEmpty ? "video" : "mixed") : "text") else { return false }
            let speakers = try sqlite.query("SELECT speaker_label FROM unit_speakers WHERE unit_id=?", binds: [.int(row.int("id")!)])
                .compactMap { $0.text("speaker_label") }.sorted()
            guard speakers == clip.speakerLabels.sorted() else { return false }
        }
        return true
    }

    private func deleteUnits(sessionID: UUID, kind: SessionIndexUnitKind) throws {
        let rows = try sqlite.query("SELECT id FROM units WHERE session_id=? AND kind=?", binds: [.text(sessionID.uuidString), .text(kind.rawValue)])
        for row in rows {
            guard let id = row.int("id") else { continue }
            for table in ["vec_text", "vec_video", "vec_mixed"] { try sqlite.run("DELETE FROM \(table) WHERE unit_id=?", binds: [.int(id)]) }
            try sqlite.run("DELETE FROM units_fts WHERE rowid=?", binds: [.int(id)])
            try sqlite.run("DELETE FROM unit_speakers WHERE unit_id=?", binds: [.int(id)])
            try sqlite.run("DELETE FROM units WHERE id=?", binds: [.int(id)])
        }
    }

    private func deleteSessionRows(_ sessionID: UUID) throws {
        try deleteGraphSource(sessionID: sessionID)
        try sqlite.run("DELETE FROM index_lane_state WHERE session_id=?", binds: [.text(sessionID.uuidString)])
        let unitRows = try sqlite.query(
            "SELECT id FROM units WHERE session_id = ?",
            binds: [.text(sessionID.uuidString)]
        )
        let ids = unitRows.compactMap { $0.int("id") }
        for id in ids {
            try sqlite.run("DELETE FROM units_fts WHERE rowid = ?", binds: [.int(id)])
            try sqlite.run("DELETE FROM vec_text WHERE unit_id = ?", binds: [.int(id)])
            try sqlite.run("DELETE FROM vec_video WHERE unit_id = ?", binds: [.int(id)])
            try sqlite.run("DELETE FROM vec_mixed WHERE unit_id = ?", binds: [.int(id)])
            try sqlite.run("DELETE FROM unit_speakers WHERE unit_id = ?", binds: [.int(id)])
        }
        try sqlite.run("DELETE FROM units WHERE session_id = ?", binds: [.text(sessionID.uuidString)])
        try sqlite.run("DELETE FROM speakers WHERE session_id = ?", binds: [.text(sessionID.uuidString)])
        try sqlite.run("DELETE FROM sessions WHERE id = ?", binds: [.text(sessionID.uuidString)])
    }

    private func loadUnits(sql: String, binds: [SessionSQLiteValue]) throws -> [SessionIndexUnitRecord] {
        let records = try sqlite.query(sql, binds: binds).compactMap { row -> SessionIndexUnitRecord? in
            guard let id = row.int("id"),
                  let sessionID = row.text("session_id").flatMap(UUID.init(uuidString:)),
                  let kind = row.text("kind").flatMap(SessionIndexUnitKind.init(rawValue:)),
                  let modality = row.text("modality").flatMap(SessionIndexModality.init(rawValue:)),
                  let text = row.text("text")
            else { return nil }
            return SessionIndexUnitRecord(
                id: id,
                sessionID: sessionID,
                kind: kind,
                start: row.double("start_s"),
                end: row.double("end_s"),
                speakers: row.text("speaker_label").map { [$0] } ?? [],
                text: text,
                cueIDs: Self.decodeCueIDs(row.text("cue_ids")),
                modality: modality,
                title: row.text("title") ?? "",
                hasVideo: row.bool("has_video"),
                language: row.text("language")
            )
        }
        let speakers = try speakerLabels(for: records.map(\.id))
        return records.map { record in
            var copy = record
            if let labels = speakers[record.id], !labels.isEmpty {
                copy.speakers = labels
            }
            return copy
        }
    }

    private func card(from row: SessionSQLiteRow) throws -> SessionCard? {
        guard let sessionID = row.text("id").flatMap(UUID.init(uuidString:)),
              let title = row.text("title")
        else { return nil }
        let speakers = try speakers(sessionID: sessionID)
        let origin = row.text("source_origin").flatMap(KnowledgeSourceOrigin.init(rawValue:)) ?? .local
        return SessionCard(
            sessionID: sessionID,
            title: title,
            tag: row.text("tag"),
            duration: row.double("duration_sec") ?? 0,
            hasVideo: row.bool("has_video"),
            language: row.text("language"),
            mediaPath: row.text("media_path") ?? "",
            speakers: speakers,
            summaryMarkdown: row.text("summary_markdown"),
            summaryExcerpt: excerpt(row.text("summary_markdown")),
            matchSource: nil,
            snippet: nil,
            lexicalReady: row.bool("lexical_ready"),
            embeddingReady: row.bool("embedding_ready"),
            sourceOrigin: origin,
            remoteSessionID: row.text("remote_session_id").flatMap(UUID.init(uuidString:)),
            ownerUserID: row.text("owner_user_id"),
            sessionType: WorkbenchSessionType(rawValue: row.text("session_type") ?? "upload") ?? .upload,
            sourceCreatedAt: row.double("source_created_at"),
            sourceModifiedAt: row.double("source_modified_at") ?? row.double("source_mtime")
        )
    }

    private func hit(from row: SessionSQLiteRow, matchSource: String, invertRank: Bool) -> SessionSearchHit? {
        guard let id = row.int("id"),
              let sessionID = row.text("session_id").flatMap(UUID.init(uuidString:)),
              let kind = row.text("kind").flatMap(SessionIndexUnitKind.init(rawValue:)),
              let text = row.text("text")
        else { return nil }
        let rank = row.double("rank") ?? 0
        let score = invertRank ? -rank : (1 / (1 + max(rank, 0)))
        return SessionSearchHit(
            sessionID: sessionID,
            title: row.text("title") ?? "",
            unitID: id,
            kind: kind,
            start: row.double("start_s"),
            end: row.double("end_s"),
            speakerLabels: row.text("speaker_label").map { [$0] } ?? [],
            text: text,
            score: score,
            matchSource: matchSource,
            snippet: excerpt(text),
            cueIDs: Self.decodeCueIDs(row.text("cue_ids")),
            hasVideo: row.bool("has_video"),
            language: row.text("language"),
            quoteSpan: nil,
            duration: row.double("duration_sec") ?? 0,
            sourceOrigin: row.text("source_origin").flatMap(KnowledgeSourceOrigin.init(rawValue:)) ?? .local,
            sessionType: WorkbenchSessionType(rawValue: row.text("session_type") ?? "upload") ?? .upload,
            sourceCreatedAt: row.double("source_created_at"),
            sourceModifiedAt: row.double("source_modified_at") ?? row.double("source_mtime"),
            materialGeneration: row.text("body_generation"), provenance: row.text("provenance"), materialRole: row.text("material_role"),
            revision: row.text("revision"), characterStart: row.int("char_start"), characterEnd: row.int("char_end"),
            timingPrecision: row.text("timing_precision") ?? "unknown", matchedModalities: matchSource.hasPrefix("vector-") ? [String(matchSource.dropFirst(7))] : [], context: row.text("context") ?? ""
        )
    }

    private func sessionCardText(_ snapshot: SessionIndexSnapshot) -> String {
        var parts = [snapshot.title]
        if let tag = snapshot.tag, !tag.isEmpty { parts.append(tag) }
        if !snapshot.speakers.isEmpty {
            parts.append(snapshot.speakers.map(\.displayName).joined(separator: ", "))
        }
        if let summary = snapshot.summaryMarkdown, !summary.isEmpty {
            parts.append(summary)
        }
        return parts.joined(separator: "\n")
    }

    private func decorateSpeakers(_ hits: [SessionSearchHit]) throws -> [SessionSearchHit] {
        let labels = try speakerLabels(for: hits.map(\.unitID))
        return hits.map { hit in
            guard let speakers = labels[hit.unitID], !speakers.isEmpty else { return hit }
            var copy = hit
            copy.speakerLabels = speakers
            return copy
        }
    }

    private func speakerLabels(for unitIDs: [Int]) throws -> [Int: [String]] {
        guard !unitIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: unitIDs.count).joined(separator: ",")
        let rows = try sqlite.query(
            "SELECT unit_id, speaker_label FROM unit_speakers WHERE unit_id IN (\(placeholders))",
            binds: unitIDs.map { .int($0) }
        )
        var map: [Int: [String]] = [:]
        for row in rows {
            guard let id = row.int("unit_id"), let label = row.text("speaker_label") else { continue }
            if map[id]?.contains(label) != true {
                map[id, default: []].append(label)
            }
        }
        return map
    }

    private func vecTable(_ modality: SessionIndexModality) -> String {
        switch modality {
        case .text: "vec_text"
        case .video: "vec_video"
        case .mixed: "vec_mixed"
        }
    }

    func missingEmbeddingModalities(for unit: SessionIndexUnitRecord) throws -> [SessionIndexModality] {
        var required: [SessionIndexModality] = []
        switch unit.kind {
        case .sessionCard, .transcriptChunk:
            required = [.text]
        case .mediaClip:
            if !unit.text.isEmpty { required.append(.text) }
            if unit.modality != .text { required.append(.video) }
            if unit.modality == .mixed && !unit.text.isEmpty { required.append(.mixed) }
        }
        return try required.filter { try !hasEmbedding(unitID: unit.id, modality: $0) }
    }

    private func needsEmbedding(_ unit: SessionIndexUnitRecord) throws -> Bool {
        try !missingEmbeddingModalities(for: unit).isEmpty
    }

    private func hasEmbedding(unitID: Int, modality: SessionIndexModality) throws -> Bool {
        let rows = try sqlite.query(
            "SELECT unit_id FROM \(vecTable(modality)) WHERE unit_id = ?",
            binds: [.int(unitID)]
        )
        return rows.first != nil
    }

    private func excerpt(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= 240 { return text }
        return String(text.prefix(240))
    }

    private static func decodeCueIDs(_ raw: String?) -> [Int] {
        guard let raw, let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int].self, from: data)
        else { return [] }
        return ids
    }

    static func ftsQuery(_ raw: String) -> String { KnowledgeLexicalTerms.query(raw) }

    private static func legacyFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        let pieces = (tokens.isEmpty ? [Substring(trimmed)] : Array(tokens)).map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "")
            return "\"\(escaped)\""
        }
        return pieces.joined(separator: " AND ")
    }

    private static func catalogFilterSQL(_ filter: SessionSearchFilter, binds: inout [SessionSQLiteValue]) -> String {
        var sql = ""
        if let ids = filter.sessionIDs, !ids.isEmpty {
            let sorted = ids.map(\.uuidString).sorted()
            let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ",")
            sql += " AND s.id IN (\(placeholders))"
            binds.append(contentsOf: sorted.map { .text($0) })
        } else if let id = filter.sessionID {
            sql += " AND s.id = ?"
            binds.append(.text(id.uuidString))
        }
        if let hasVideo = filter.hasVideo {
            sql += " AND s.has_video = ?"
            binds.append(.bool(hasVideo))
        }
        if let language = filter.language {
            sql += " AND s.language = ?"
            binds.append(.text(language))
        }
        if let origins = filter.sourceOrigins, !origins.isEmpty {
            let sorted = origins.sorted { $0.rawValue < $1.rawValue }
            let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ",")
            sql += " AND COALESCE(s.source_origin, 'local') IN (\(placeholders))"
            binds.append(contentsOf: sorted.map { .text($0.rawValue) })
            if origins.contains(.cloud) {
                if let owner = filter.cloudOwnerUserID {
                    if origins.contains(.local) {
                        sql += " AND (COALESCE(s.source_origin, 'local') = 'local' OR s.owner_user_id = ?)"
                    } else {
                        sql += " AND s.owner_user_id = ?"
                    }
                    binds.append(.text(owner))
                } else if origins.contains(.local) {
                    sql += " AND COALESCE(s.source_origin, 'local') = 'local'"
                } else {
                    sql += " AND 0"
                }
            }
        }
        return sql
    }

    private static func filterSQL(_ filter: SessionSearchFilter, binds: inout [SessionSQLiteValue]) -> String {
        var sql = ""
        if let generations = filter.canonicalGenerations {
            let clauses = generations.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, generation in
                binds.append(.text(id.uuidString)); binds.append(.text(generation))
                return "(u.session_id=? AND u.body_generation=?)"
            }
            sql += clauses.isEmpty ? " AND u.kind <> 'transcript_chunk'" :
                " AND (u.kind <> 'transcript_chunk' OR (" + clauses.joined(separator: " OR ") + "))"
        }
        if let sessionIDs = filter.sessionIDs, !sessionIDs.isEmpty {
            let sorted = sessionIDs.map(\.uuidString).sorted()
            let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ",")
            sql += " AND u.session_id IN (\(placeholders))"
            for id in sorted {
                binds.append(.text(id))
            }
        } else if let sessionID = filter.sessionID {
            sql += " AND u.session_id = ?"
            binds.append(.text(sessionID.uuidString))
        }
        if let speaker = filter.speakerLabel {
            sql += """
             AND EXISTS (
                SELECT 1 FROM unit_speakers us
                JOIN speakers sp ON sp.session_id = u.session_id AND sp.label = us.speaker_label
                WHERE us.unit_id = u.id AND (us.speaker_label = ? OR sp.display_name = ?)
             )
            """
            binds.append(.text(speaker))
            binds.append(.text(speaker))
        }
        if let start = filter.start { sql += " AND (u.end_s IS NULL OR u.end_s >= ?)"; binds.append(.double(start)) }
        if let end = filter.end { sql += " AND (u.start_s IS NULL OR u.start_s <= ?)"; binds.append(.double(end)) }
        if let hasVideo = filter.hasVideo {
            sql += " AND s.has_video = ?"
            binds.append(.bool(hasVideo))
        }
        if let language = filter.language {
            sql += " AND s.language = ?"
            binds.append(.text(language))
        }
        if let modality = filter.modality {
            sql += " AND u.modality = ?"
            binds.append(.text(modality.rawValue))
        }
        if let origins = filter.sourceOrigins, !origins.isEmpty {
            let placeholders = Array(repeating: "?", count: origins.count).joined(separator: ",")
            sql += " AND COALESCE(s.source_origin, 'local') IN (\(placeholders))"
            for origin in origins.sorted(by: { $0.rawValue < $1.rawValue }) {
                binds.append(.text(origin.rawValue))
            }
            if origins.contains(.cloud) {
                if let owner = filter.cloudOwnerUserID {
                    if origins.contains(.local) {
                        sql += " AND (COALESCE(s.source_origin, 'local') = 'local' OR s.owner_user_id = ?)"
                    } else {
                        sql += " AND s.owner_user_id = ?"
                    }
                    binds.append(.text(owner))
                } else if origins.contains(.local) {
                    sql += " AND COALESCE(s.source_origin, 'local') = 'local'"
                } else {
                    sql += " AND 0"
                }
            }
        }
        return sql
    }

    static func packed(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        tag TEXT,
        summary_markdown TEXT,
        language TEXT,
        duration_sec REAL NOT NULL,
        has_video INTEGER NOT NULL,
        media_path TEXT NOT NULL,
        source_mtime REAL,
        ingest_generation INTEGER NOT NULL,
        lexical_ready INTEGER NOT NULL,
        embedding_ready INTEGER NOT NULL,
        created_at REAL NOT NULL,
        modified_at REAL NOT NULL,
        source_origin TEXT NOT NULL DEFAULT 'local',
        remote_session_id TEXT,
        owner_user_id TEXT,
        indexed_at REAL,
        session_type TEXT NOT NULL DEFAULT 'upload',
        source_created_at REAL,
        source_modified_at REAL
    );
    CREATE TABLE IF NOT EXISTS speakers (
        session_id TEXT NOT NULL,
        label TEXT NOT NULL,
        display_name TEXT NOT NULL,
        PRIMARY KEY (session_id, label)
    );
    CREATE TABLE IF NOT EXISTS units (
        id INTEGER PRIMARY KEY,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        start_s REAL,
        end_s REAL,
        speaker_label TEXT,
        text TEXT NOT NULL,
        translation_text TEXT,
        cue_ids TEXT,
        parent_id INTEGER,
        modality TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS index_lane_state (
        session_id TEXT NOT NULL,
        lane TEXT NOT NULL,
        manifest TEXT NOT NULL,
        lexical_ready INTEGER NOT NULL,
        embedding_ready INTEGER NOT NULL,
        PRIMARY KEY(session_id,lane)
    );
    CREATE TABLE IF NOT EXISTS unit_speakers (
        unit_id INTEGER NOT NULL,
        speaker_label TEXT NOT NULL,
        PRIMARY KEY (unit_id, speaker_label)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS units_fts USING fts5(
        text,
        translation_text,
        title,
        summary,
        tokenize='unicode61'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_text USING vec0(
        unit_id INTEGER PRIMARY KEY,
        embedding float[256] distance_metric=cosine
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_video USING vec0(
        unit_id INTEGER PRIMARY KEY,
        embedding float[256] distance_metric=cosine
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_mixed USING vec0(
        unit_id INTEGER PRIMARY KEY,
        embedding float[256] distance_metric=cosine
    );
    CREATE TABLE IF NOT EXISTS graph_source_state (
        session_id TEXT PRIMARY KEY,
        source_generation INTEGER NOT NULL,
        schema_version INTEGER NOT NULL,
        source_origin TEXT NOT NULL,
        owner_user_id TEXT,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS graph_entities (
        id INTEGER PRIMARY KEY,
        scope_key TEXT NOT NULL,
        canonical_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        UNIQUE(scope_key, normalized_name)
    );
    CREATE TABLE IF NOT EXISTS graph_aliases (
        entity_id INTEGER NOT NULL,
        normalized_name TEXT NOT NULL,
        PRIMARY KEY(entity_id, normalized_name)
    );
    CREATE INDEX IF NOT EXISTS graph_aliases_name ON graph_aliases(normalized_name);
    CREATE TABLE IF NOT EXISTS graph_relations (
        id INTEGER PRIMARY KEY,
        subject_entity_id INTEGER NOT NULL,
        predicate TEXT NOT NULL,
        object_entity_id INTEGER NOT NULL,
        UNIQUE(subject_entity_id, predicate, object_entity_id)
    );
    CREATE TABLE IF NOT EXISTS graph_relation_evidence (
        relation_id INTEGER NOT NULL,
        session_id TEXT NOT NULL,
        unit_id INTEGER NOT NULL,
        PRIMARY KEY(relation_id, session_id, unit_id)
    );
    CREATE TABLE IF NOT EXISTS graph_entity_chunks (
        entity_id INTEGER NOT NULL,
        session_id TEXT NOT NULL,
        unit_id INTEGER NOT NULL,
        PRIMARY KEY(entity_id, session_id, unit_id)
    );
    CREATE INDEX IF NOT EXISTS graph_entity_chunks_entity ON graph_entity_chunks(entity_id);
    CREATE INDEX IF NOT EXISTS graph_entity_chunks_unit ON graph_entity_chunks(unit_id);
    """
}

struct SessionIndexUnitRecord: Sendable {
    var id: Int
    var sessionID: UUID
    var kind: SessionIndexUnitKind
    var start: Double?
    var end: Double?
    var speakers: [String]
    var text: String
    var cueIDs: [Int]
    var modality: SessionIndexModality
    var title: String
    var hasVideo: Bool
    var language: String?
}
