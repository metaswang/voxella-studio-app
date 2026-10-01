import Foundation

enum KnowledgeGraphSchema {
    static let version = 1

    static let entityTypes: Set<String> = [
        "person", "organization", "project", "place", "event", "concept", "other",
    ]

    static let predicates: Set<String> = [
        "ASSOCIATED_WITH", "ATTENDS", "AUTHORS", "DECIDES", "DISCUSSES", "LEADS",
        "LOCATED_IN", "MENTIONS", "OWNS", "RELATED_TO", "REQUIRES", "WORKS_ON",
    ]

    static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }
            .joined(separator: " ")
    }

    static func scopeKey(origin: KnowledgeSourceOrigin, ownerUserID: String?) -> String {
        origin == .cloud ? "cloud:\(ownerUserID ?? "unknown")" : "local"
    }
}

struct KnowledgeGraphEntity: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var aliases: [String]
    var chunkIDs: [Int]

    init(name: String, type: String = "other", aliases: [String] = [], chunkIDs: [Int] = []) {
        self.name = name
        self.type = type
        self.aliases = aliases
        self.chunkIDs = chunkIDs
    }
}

struct KnowledgeGraphRelation: Codable, Equatable, Sendable {
    var subject: String
    var predicate: String
    var object: String
    var evidenceChunkIDs: [Int]
}

struct KnowledgeGraphExtraction: Codable, Equatable, Sendable {
    var entities: [KnowledgeGraphEntity]
    var relations: [KnowledgeGraphRelation]

    static let empty = KnowledgeGraphExtraction(entities: [], relations: [])

    func validated(allowedChunkIDs: Set<Int>) -> KnowledgeGraphExtraction {
        let entities = entities.compactMap { entity -> KnowledgeGraphEntity? in
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = KnowledgeGraphSchema.normalizedName(name)
            guard !normalized.isEmpty else { return nil }
            let type = KnowledgeGraphSchema.entityTypes.contains(entity.type) ? entity.type : "other"
            let aliases = Array(Set(entity.aliases.map(KnowledgeGraphSchema.normalizedName)))
                .filter { !$0.isEmpty && $0 != normalized }
                .sorted()
            let chunkIDs = Array(Set(entity.chunkIDs.filter(allowedChunkIDs.contains))).sorted()
            return KnowledgeGraphEntity(name: name, type: type, aliases: aliases, chunkIDs: chunkIDs)
        }
        let knownNames = Set(entities.map { KnowledgeGraphSchema.normalizedName($0.name) })
        let relations = relations.compactMap { relation -> KnowledgeGraphRelation? in
            let subject = KnowledgeGraphSchema.normalizedName(relation.subject)
            let object = KnowledgeGraphSchema.normalizedName(relation.object)
            let predicate = relation.predicate.uppercased()
            let evidence = Array(Set(relation.evidenceChunkIDs.filter(allowedChunkIDs.contains))).sorted()
            guard knownNames.contains(subject), knownNames.contains(object),
                  KnowledgeGraphSchema.predicates.contains(predicate), !evidence.isEmpty
            else { return nil }
            return KnowledgeGraphRelation(
                subject: subject,
                predicate: predicate,
                object: object,
                evidenceChunkIDs: evidence
            )
        }
        return KnowledgeGraphExtraction(entities: entities, relations: relations)
    }
}

struct KnowledgeGraphSource: Sendable {
    var sessionID: UUID
    var generation: Int
    var sourceOrigin: KnowledgeSourceOrigin
    var ownerUserID: String?
    var chunks: [SessionSearchHit]
}

struct KnowledgeGraphEntityRecord: Hashable, Sendable {
    var id: Int
    var scopeKey: String
    var name: String
}

struct KnowledgeGraphRelationRecord: Sendable {
    var subjectID: Int
    var objectID: Int
}

extension SessionIndexStore {
    func graphSource(sessionID: UUID) throws -> KnowledgeGraphSource? {
        let sourceRows = try sqlite.query(
            "SELECT ingest_generation, source_origin, owner_user_id FROM sessions WHERE id = ? AND lexical_ready = 1",
            binds: [.text(sessionID.uuidString)]
        )
        guard let source = sourceRows.first, let generation = source.int("ingest_generation") else {
            return nil
        }
        let unitRows = try sqlite.query(
            """
            SELECT u.id, u.session_id, u.kind, u.start_s, u.end_s, u.speaker_label, u.text,
                   u.cue_ids, s.title, s.has_video, s.language
            FROM units u JOIN sessions s ON s.id = u.session_id
            WHERE u.session_id = ? AND u.kind = ? ORDER BY u.start_s, u.id
            """,
            binds: [.text(sessionID.uuidString), .text(SessionIndexUnitKind.transcriptChunk.rawValue)]
        )
        let chunks = unitRows.compactMap(graphHit)
        guard !chunks.isEmpty else { return nil }
        return KnowledgeGraphSource(
            sessionID: sessionID,
            generation: generation,
            sourceOrigin: source.text("source_origin").flatMap(KnowledgeSourceOrigin.init(rawValue:)) ?? .local,
            ownerUserID: source.text("owner_user_id"),
            chunks: chunks
        )
    }

    func graphSourcesNeedingRebuild(
        sourceOrigins: Set<KnowledgeSourceOrigin>,
        cloudOwnerUserID: String?,
        limit: Int = 200
    ) throws -> [KnowledgeGraphSource] {
        guard !sourceOrigins.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: sourceOrigins.count).joined(separator: ",")
        var binds = sourceOrigins.sorted(by: { $0.rawValue < $1.rawValue }).map {
            SessionSQLiteValue.text($0.rawValue)
        }
        var sql = """
        SELECT s.id FROM sessions s
        LEFT JOIN graph_source_state gs ON gs.session_id = s.id
        WHERE s.lexical_ready = 1
          AND s.source_origin IN (\(placeholders))
          AND (gs.session_id IS NULL OR gs.source_generation != s.ingest_generation
               OR gs.schema_version != \(KnowledgeGraphSchema.version))
        """
        if sourceOrigins.contains(.cloud) {
            if let cloudOwnerUserID {
                if sourceOrigins.contains(.local) {
                    sql += " AND (s.source_origin = 'local' OR s.owner_user_id = ?)"
                } else {
                    sql += " AND s.owner_user_id = ?"
                }
                binds.append(.text(cloudOwnerUserID))
            } else if sourceOrigins.contains(.local) {
                sql += " AND s.source_origin = 'local'"
            } else {
                sql += " AND 0"
            }
        }
        sql += " ORDER BY s.modified_at DESC LIMIT ?"
        binds.append(.int(max(1, min(limit, 500))))
        return try sqlite.query(sql, binds: binds)
            .compactMap { $0.text("id").flatMap(UUID.init(uuidString:)) }
            .compactMap { try graphSource(sessionID: $0) }
    }

    @discardableResult
    func replaceGraph(source: KnowledgeGraphSource, extraction: KnowledgeGraphExtraction) throws -> Bool {
        let allowedChunkIDs = Set(source.chunks.map(\.unitID))
        let extraction = extraction.validated(allowedChunkIDs: allowedChunkIDs)
        return try sqlite.transaction {
            let current = try sqlite.query(
                "SELECT ingest_generation FROM sessions WHERE id = ?",
                binds: [.text(source.sessionID.uuidString)]
            ).first?.int("ingest_generation")
            guard current == source.generation else { return false }

            try deleteGraphSource(sessionID: source.sessionID)
            let scope = KnowledgeGraphSchema.scopeKey(
                origin: source.sourceOrigin,
                ownerUserID: source.ownerUserID
            )
            var entities: [String: Int] = [:]
            for entity in extraction.entities {
                let name = KnowledgeGraphSchema.normalizedName(entity.name)
                guard !name.isEmpty else { continue }
                let entityID: Int
                if let existing = try sqlite.query(
                    "SELECT id FROM graph_entities WHERE scope_key = ? AND normalized_name = ?",
                    binds: [.text(scope), .text(name)]
                ).first?.int("id") {
                    entityID = existing
                } else {
                    entityID = try sqlite.run(
                        "INSERT INTO graph_entities(scope_key, canonical_name, normalized_name, entity_type) VALUES (?, ?, ?, ?)",
                        binds: [.text(scope), .text(entity.name), .text(name), .text(entity.type)]
                    )
                }
                entities[name] = entityID
                for alias in Set([name] + entity.aliases.map(KnowledgeGraphSchema.normalizedName)) where !alias.isEmpty {
                    try sqlite.run(
                        "INSERT OR IGNORE INTO graph_aliases(entity_id, normalized_name) VALUES (?, ?)",
                        binds: [.int(entityID), .text(alias)]
                    )
                }
                for chunkID in entity.chunkIDs where allowedChunkIDs.contains(chunkID) {
                    try sqlite.run(
                        "INSERT OR IGNORE INTO graph_entity_chunks(entity_id, session_id, unit_id) VALUES (?, ?, ?)",
                        binds: [.int(entityID), .text(source.sessionID.uuidString), .int(chunkID)]
                    )
                }
            }
            for relation in extraction.relations {
                guard let subject = entities[relation.subject], let object = entities[relation.object] else {
                    continue
                }
                let relationID: Int
                if let existing = try sqlite.query(
                    "SELECT id FROM graph_relations WHERE subject_entity_id = ? AND predicate = ? AND object_entity_id = ?",
                    binds: [.int(subject), .text(relation.predicate), .int(object)]
                ).first?.int("id") {
                    relationID = existing
                } else {
                    relationID = try sqlite.run(
                        "INSERT INTO graph_relations(subject_entity_id, predicate, object_entity_id) VALUES (?, ?, ?)",
                        binds: [.int(subject), .text(relation.predicate), .int(object)]
                    )
                }
                for chunkID in relation.evidenceChunkIDs where allowedChunkIDs.contains(chunkID) {
                    try sqlite.run(
                        "INSERT OR IGNORE INTO graph_relation_evidence(relation_id, session_id, unit_id) VALUES (?, ?, ?)",
                        binds: [.int(relationID), .text(source.sessionID.uuidString), .int(chunkID)]
                    )
                    try sqlite.run(
                        "INSERT OR IGNORE INTO graph_entity_chunks(entity_id, session_id, unit_id) VALUES (?, ?, ?)",
                        binds: [.int(subject), .text(source.sessionID.uuidString), .int(chunkID)]
                    )
                    try sqlite.run(
                        "INSERT OR IGNORE INTO graph_entity_chunks(entity_id, session_id, unit_id) VALUES (?, ?, ?)",
                        binds: [.int(object), .text(source.sessionID.uuidString), .int(chunkID)]
                    )
                }
            }
            try sqlite.run(
                "INSERT INTO graph_source_state(session_id, source_generation, schema_version, source_origin, owner_user_id, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                binds: [
                    .text(source.sessionID.uuidString), .int(source.generation),
                    .int(KnowledgeGraphSchema.version), .text(source.sourceOrigin.rawValue),
                    .optional(source.ownerUserID), .double(Date().timeIntervalSince1970),
                ]
            )
            try removeGraphOrphans()
            return true
        }
    }

    func graphEntities(matching names: [String], scopes: Set<String>, limit: Int = 20) throws -> [KnowledgeGraphEntityRecord] {
        let normalized = Array(Set(names.map(KnowledgeGraphSchema.normalizedName))).filter { !$0.isEmpty }
        guard !normalized.isEmpty, !scopes.isEmpty else { return [] }
        let namePlaceholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")
        let scopePlaceholders = Array(repeating: "?", count: scopes.count).joined(separator: ",")
        let binds = normalized.map(SessionSQLiteValue.text)
            + scopes.sorted().map(SessionSQLiteValue.text)
            + [.int(max(1, min(limit, 80)))]
        return try sqlite.query(
            """
            SELECT DISTINCT e.id, e.scope_key, e.canonical_name
            FROM graph_aliases a JOIN graph_entities e ON e.id = a.entity_id
            WHERE a.normalized_name IN (\(namePlaceholders)) AND e.scope_key IN (\(scopePlaceholders))
            LIMIT ?
            """,
            binds: binds
        ).compactMap { row in
            guard let id = row.int("id"), let scope = row.text("scope_key"), let name = row.text("canonical_name") else {
                return nil
            }
            return KnowledgeGraphEntityRecord(id: id, scopeKey: scope, name: name)
        }
    }

    func graphNeighbors(entityIDs: [Int], limit: Int = 20) throws -> [KnowledgeGraphRelationRecord] {
        let ids = Array(Set(entityIDs))
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let binds = ids.map(SessionSQLiteValue.int)
            + ids.map(SessionSQLiteValue.int)
            + [.int(max(1, min(limit, 80)))]
        return try sqlite.query(
            """
            SELECT subject_entity_id, object_entity_id FROM graph_relations
            WHERE subject_entity_id IN (\(placeholders)) OR object_entity_id IN (\(placeholders))
            LIMIT ?
            """,
            binds: binds
        ).compactMap { row in
            guard let subject = row.int("subject_entity_id"), let object = row.int("object_entity_id") else {
                return nil
            }
            return KnowledgeGraphRelationRecord(subjectID: subject, objectID: object)
        }
    }

    func graphChunks(entityIDs: [Int], filter: SessionSearchFilter, limit: Int = 20) throws -> [SessionSearchHit] {
        let ids = Array(Set(entityIDs))
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var binds = ids.map(SessionSQLiteValue.int)
        var sql = """
        SELECT DISTINCT u.id, u.session_id, u.kind, u.start_s, u.end_s, u.speaker_label, u.text,
               u.cue_ids, s.title, s.has_video, s.language
        FROM graph_entity_chunks gec
        JOIN units u ON u.id = gec.unit_id
        JOIN sessions s ON s.id = u.session_id
        WHERE gec.entity_id IN (\(placeholders)) AND u.kind = ?
        """
        binds.append(.text(SessionIndexUnitKind.transcriptChunk.rawValue))
        sql += graphFilterSQL(filter, binds: &binds)
        sql += " ORDER BY u.start_s, u.id LIMIT ?"
        binds.append(.int(max(1, min(limit, 20))))
        return try sqlite.query(sql, binds: binds).compactMap(graphHit)
    }

    func textEmbeddings(unitIDs: [Int]) throws -> [Int: [Float]] {
        let ids = Array(Set(unitIDs))
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var values: [Int: [Float]] = [:]
        for row in try sqlite.query(
            "SELECT unit_id, embedding FROM vec_text WHERE unit_id IN (\(placeholders))",
            binds: ids.map(SessionSQLiteValue.int)
        ) {
            guard let id = row.int("unit_id"), let data = row.blob("embedding") else { continue }
            values[id] = Self.unpacked(data)
        }
        return values
    }

    func contextNeighbors(for anchor: SessionSearchHit) throws -> [SessionSearchHit] {
        guard anchor.kind == .transcriptChunk else { return [] }
        let rows = try sqlite.query(
            """
            SELECT u.id, u.session_id, u.kind, u.start_s, u.end_s, u.speaker_label, u.text,
                   u.cue_ids, s.title, s.has_video, s.language
            FROM units u JOIN sessions s ON s.id = u.session_id
            WHERE u.session_id = ? AND u.kind = ? ORDER BY u.start_s, u.id
            """,
            binds: [.text(anchor.sessionID.uuidString), .text(SessionIndexUnitKind.transcriptChunk.rawValue)]
        ).compactMap(graphHit)
        guard let index = rows.firstIndex(where: { $0.unitID == anchor.unitID }) else { return [] }
        var neighbors: [SessionSearchHit] = []
        if rows.indices.contains(index - 1) { neighbors.append(rows[index - 1]) }
        if rows.indices.contains(index + 1) { neighbors.append(rows[index + 1]) }
        return neighbors
    }

    func deleteGraphSource(sessionID: UUID) throws {
        try sqlite.run("DELETE FROM graph_relation_evidence WHERE session_id = ?", binds: [.text(sessionID.uuidString)])
        try sqlite.run("DELETE FROM graph_entity_chunks WHERE session_id = ?", binds: [.text(sessionID.uuidString)])
        try sqlite.run("DELETE FROM graph_source_state WHERE session_id = ?", binds: [.text(sessionID.uuidString)])
        try removeGraphOrphans()
    }

    private func removeGraphOrphans() throws {
        try sqlite.run("DELETE FROM graph_relations WHERE NOT EXISTS (SELECT 1 FROM graph_relation_evidence e WHERE e.relation_id = graph_relations.id)")
        try sqlite.run("DELETE FROM graph_aliases WHERE NOT EXISTS (SELECT 1 FROM graph_entities e WHERE e.id = graph_aliases.entity_id)")
        try sqlite.run("DELETE FROM graph_entities WHERE NOT EXISTS (SELECT 1 FROM graph_entity_chunks c WHERE c.entity_id = graph_entities.id) AND NOT EXISTS (SELECT 1 FROM graph_relations r WHERE r.subject_entity_id = graph_entities.id OR r.object_entity_id = graph_entities.id)")
        try sqlite.run("DELETE FROM graph_aliases WHERE NOT EXISTS (SELECT 1 FROM graph_entities e WHERE e.id = graph_aliases.entity_id)")
    }

    private func graphHit(_ row: SessionSQLiteRow) -> SessionSearchHit? {
        guard let id = row.int("id"),
              let sessionID = row.text("session_id").flatMap(UUID.init(uuidString:)),
              let kind = row.text("kind").flatMap(SessionIndexUnitKind.init(rawValue:)),
              let text = row.text("text")
        else { return nil }
        return SessionSearchHit(
            sessionID: sessionID,
            title: row.text("title") ?? "",
            unitID: id,
            kind: kind,
            start: row.double("start_s"),
            end: row.double("end_s"),
            speakerLabels: row.text("speaker_label").map { [$0] } ?? [],
            text: text,
            score: 0,
            matchSource: "graph",
            snippet: text.count > 240 ? String(text.prefix(240)) : text,
            cueIDs: [],
            hasVideo: row.bool("has_video"),
            language: row.text("language"),
            quoteSpan: nil
        )
    }

    private func graphFilterSQL(_ filter: SessionSearchFilter, binds: inout [SessionSQLiteValue]) -> String {
        var sql = ""
        if let sessionIDs = filter.sessionIDs, !sessionIDs.isEmpty {
            let sorted = sessionIDs.map(\.uuidString).sorted()
            sql += " AND u.session_id IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ",")))"
            binds.append(contentsOf: sorted.map(SessionSQLiteValue.text))
        } else if let sessionID = filter.sessionID {
            sql += " AND u.session_id = ?"
            binds.append(.text(sessionID.uuidString))
        }
        if let origins = filter.sourceOrigins, !origins.isEmpty {
            let sorted = origins.sorted { $0.rawValue < $1.rawValue }
            sql += " AND COALESCE(s.source_origin, 'local') IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ",")))"
            binds.append(contentsOf: sorted.map { .text($0.rawValue) })
            if origins.contains(.cloud) {
                if let owner = filter.cloudOwnerUserID {
                    sql += origins.contains(.local)
                        ? " AND (COALESCE(s.source_origin, 'local') = 'local' OR s.owner_user_id = ?)"
                        : " AND s.owner_user_id = ?"
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

    private static func unpacked(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else { return [] }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
    }
}
