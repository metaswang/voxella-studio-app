import Foundation
import CoreFoundation

/// Registry of knowledge agent tools: schema definitions and Mac whitelist.
/// Tools use dotted names (e.g., `knowledge.search`) and JSON-encoded arguments/results.
enum KnowledgeToolRegistry {
    static let allTools: [KnowledgeToolDefinition] = [
        .knowledgeSearch,
        .sessionList,
        .knowledgeGetSessionMetadata,
        .sessionGetSummary,
        .sessionGetSegments,
        .sessionSearchSegments,
        .sessionGetTimeline,
        .knowledgeCompareSessions,
        .sessionGetSpeakers,
        .sessionAggregate,
        .sourceSearch,
        .readSkill,
        .readPayload,
        .analysisUpdate,
        .askClarification,
    ]
    
    static func tool(named name: String) -> KnowledgeToolDefinition? {
        allTools.first { $0.name == name }
    }
    
    static func isAllowed(_ name: String) -> Bool {
        allTools.contains { $0.name == name }
    }
    
    static func validateSkill(_ skill: Skill) -> Bool {
        guard let metadata = skill.metadata else { return true }
        return metadata.allowedTools.allSatisfy(isAllowed)
    }
}

struct KnowledgeToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [KnowledgeToolParameter]
    
    static let knowledgeSearch = KnowledgeToolDefinition(
        name: "knowledge.search",
        description: "Search transcript content across sessions using hybrid lexical + semantic retrieval with graph recall when available. Returns hits with citations.",
        parameters: [
            .init(name: "query", type: "string", description: "Search query", required: true),
            .init(name: "session_ids", type: "array", description: "Optional session UUID list to scope search", required: false),
            .init(name: "limit", type: "integer", description: "Max hits (default 8, up to 32)", required: false),
            .init(name: "use_graph", type: "boolean", description: "Explicitly enable graph hints for entity/multi-hop queries", required: false),
        ]
    )
    
    static let sessionList = KnowledgeToolDefinition(
        name: "session.list",
        description: "List sessions filtered by query text, type, origin, or date range. Respects login visibility.",
        parameters: [
            .init(name: "query", type: "string", description: "Text query to filter titles", required: false),
            .init(name: "type", type: "string", description: "Session type filter (recording, meeting, upload, net_video, dub)", required: false),
            .init(name: "origin", type: "string", description: "Origin filter (local, cloud, all)", required: false),
            .init(name: "date_from", type: "string", description: "ISO8601 date lower bound", required: false),
            .init(name: "date_to", type: "string", description: "ISO8601 date upper bound", required: false),
            .init(name: "limit", type: "integer", description: "Page size (default 32, max 100); follow next_cursor for the full inventory", required: false),
            .init(name: "cursor", type: "integer", description: "Offset from next_cursor", required: false),
            .init(name: "date_field", type: "string", description: "created or modified (default created); neither is a recording date", required: false),
        ]
    )
    
    static let knowledgeGetSessionMetadata = KnowledgeToolDefinition(
        name: "knowledge.get_session_metadata",
        description: "Get metadata for one session: title, type, duration, dates, origin, has_transcript.",
        parameters: [
            .init(name: "session_id", type: "string", description: "Session UUID", required: true),
        ]
    )
    
    static let sessionGetSummary = KnowledgeToolDefinition(
        name: "session.get_summary",
        description: "Get the summary markdown for one session.",
        parameters: [
            .init(name: "session_id", type: "string", description: "Session UUID", required: true),
            .init(name: "cursor", type: "integer", description: "Character offset for summary paging", required: false),
        ]
    )
    
    static let sessionGetSegments = KnowledgeToolDefinition(
        name: "session.get_segments",
        description: "Retrieve consecutive transcript segments from a session, optionally bounded by time range.",
        parameters: [
            .init(name: "session_id", type: "string", description: "Session UUID", required: true),
            .init(name: "start", type: "number", description: "Start time in seconds (optional)", required: false),
            .init(name: "end", type: "number", description: "End time in seconds (optional)", required: false),
            .init(name: "limit", type: "integer", description: "Page size (default 80, max 200)", required: false),
            .init(name: "cursor", type: "integer", description: "Offset from next_cursor", required: false),
            .init(name: "speaker", type: "string", description: "Optional exact speaker label", required: false),
        ]
    )
    
    static let sessionSearchSegments = KnowledgeToolDefinition(
        name: "session.search_segments",
        description: "Search transcript segments within one or more sessions using hybrid lexical + semantic retrieval with graph recall when available. Returns timed hits with speaker labels and citations.",
        parameters: [
            .init(name: "session_ids", type: "array", description: "Session UUID list", required: true),
            .init(name: "query", type: "string", description: "Search query", required: true),
            .init(name: "limit", type: "integer", description: "Max hits (default 8, up to 32)", required: false),
            .init(name: "use_graph", type: "boolean", description: "Explicitly enable graph hints for entity/multi-hop queries", required: false),
        ]
    )
    
    static let sessionGetTimeline = KnowledgeToolDefinition(
        name: "session.get_timeline", description: "Read a paginated bucketed timeline; follow next_cursor to cover the full source.",
        parameters: sessionGetSegments.parameters + [
            .init(name: "bucket_seconds", type: "integer", description: "Positive bucket size (default 60)", required: false)])

    static let knowledgeCompareSessions = KnowledgeToolDefinition(
        name: "knowledge.compare_sessions",
        description: "Compare themes across 2+ sessions. Returns structured comparison evidence.",
        parameters: [
            .init(name: "session_ids", type: "array", description: "Session UUID list (≥2)", required: true),
            .init(name: "focus_query", type: "string", description: "Optional focus query for thematic comparison", required: false),
            .init(name: "mode", type: "string", description: "Comparison mode: themes, speakers, timeline (default themes)", required: false),
        ]
    )
    
    static let sessionGetSpeakers = KnowledgeToolDefinition(
        name: "session.get_speakers", description: "Read speaker labels; missing labels do not prove nobody spoke.",
        parameters: [.init(name: "session_id", type: "string", description: "Session UUID", required: true)])
    static let sessionAggregate = KnowledgeToolDefinition(
        name: "session.aggregate", description: "Exact count, duration sum, grouping and sorting over the FULL filtered metadata inventory; cannot count semantic themes.",
        parameters: sessionList.parameters + [
            .init(name: "group_by", type: "string", description: "type or origin (optional)", required: false),
            .init(name: "sort_by", type: "string", description: "created, modified or duration (descending)", required: false)])
    static let sourceSearch = KnowledgeToolDefinition(
        name: "knowledge.search_sources", description: "Discover source candidates through summary AND transcript search. Top-K candidates are not a complete inventory.",
        parameters: [.init(name: "query", type: "string", description: "Source discovery query", required: true),
                     .init(name: "limit", type: "integer", description: "Max sources, up to 32", required: false)])
    static let readSkill = KnowledgeToolDefinition(
        name: "read_skill", description: "Read a skill method on demand. Does not expand core permissions.",
        parameters: [.init(name: "skill_id", type: "string", description: "Skill ID from the catalog", required: true)])
    static let readPayload = KnowledgeToolDefinition(
        name: "read_payload", description: "Re-read a saved observation by handle with explicit paging.",
        parameters: [.init(name: "payload_ref", type: "string", description: "Payload handle", required: true),
                     .init(name: "cursor", type: "integer", description: "Character offset", required: false)])
    static let analysisUpdate = KnowledgeToolDefinition(
        name: "analysis.update", description: "Initialize or update source × dimension evidence coverage. Retain unchecked, not_found, conflict, unavailable and explicit absent separately. Supported/conflict/absent require evidence IDs.",
        parameters: [.init(name: "session_ids", type: "array", description: "Visible source UUIDs to initialize", required: false),
                     .init(name: "dimensions", type: "array", description: "Question dimensions to initialize", required: false),
                     .init(name: "cells", type: "array", description: "Updates with session_id, dimension, status, finding and evidence_ids", required: false)])

    static let askClarification = KnowledgeToolDefinition(
        name: "ask_clarification",
        description: "Control tool: ask user a clarification question when evidence is insufficient or query is ambiguous.",
        parameters: [
            .init(name: "question", type: "string", description: "Clarification question to ask user", required: true),
        ]
    )
}

struct KnowledgeToolParameter: Sendable {
    let name: String
    let type: String
    let description: String
    let required: Bool
}

extension KnowledgeToolDefinition {
    var nativeName: String { name.replacingOccurrences(of: ".", with: "_") }

    var schema: AgentToolSchema {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            var field: [String: Any] = ["type": parameter.type, "description": parameter.description]
            if parameter.type == "array" {
                field["items"] = ["type": "string"]
                if parameter.name == "cells" {
                    field["items"] = ["type": "object", "additionalProperties": false,
                        "properties": [
                            "session_id": ["type": "string"], "dimension": ["type": "string"],
                            "status": ["type": "string", "enum": ["unchecked", "not_found", "supported", "conflict", "absent", "unavailable"]],
                            "finding": ["type": "string"], "evidence_ids": ["type": "array", "items": ["type": "string"]]],
                        "required": ["session_id", "dimension", "status", "finding", "evidence_ids"]]
                }
            }
            properties[parameter.name] = field
        }
        return AgentToolSchema(name: nativeName, description: description, inputSchema: [
            "type": "object", "properties": properties,
            "required": parameters.filter(\.required).map(\.name), "additionalProperties": false])
    }

    func validate(_ args: [String: Any]) throws {
        for key in args.keys where !parameters.contains(where: { $0.name == key }) {
            throw KnowledgeToolError.invalidParameter("Unexpected parameter: \(key)")
        }
        for parameter in parameters {
            guard let value = args[parameter.name], !(value is NSNull) else {
                if parameter.required { throw KnowledgeToolError.missingParameter(parameter.name) }
                continue
            }
            let number = value as? NSNumber
            let isBoolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            let valid: Bool
            switch parameter.type {
            case "string": valid = value is String
            case "array": valid = parameter.name == "cells" ? value is [[String: Any]] : value is [String]
            case "boolean": valid = isBoolean
            case "integer": valid = number.map { !isBoolean && $0.doubleValue.isFinite && $0.doubleValue.rounded() == $0.doubleValue && abs($0.doubleValue) <= 1_000_000 } ?? false
            case "number": valid = number.map { !isBoolean && $0.doubleValue.isFinite } ?? false
            default: valid = false
            }
            guard valid else { throw KnowledgeToolError.invalidParameter(parameter.name + " has the wrong type") }
        }
    }
}
