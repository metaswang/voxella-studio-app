import Foundation

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
        .finishWithEvidence,
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
            .init(name: "limit", type: "integer", description: "Max hits (default 8)", required: false),
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
            .init(name: "limit", type: "integer", description: "Max results (default 50; enough for the visible collection)", required: false),
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
        ]
    )
    
    static let sessionGetSegments = KnowledgeToolDefinition(
        name: "session.get_segments",
        description: "Retrieve consecutive transcript segments from a session, optionally bounded by time range.",
        parameters: [
            .init(name: "session_id", type: "string", description: "Session UUID", required: true),
            .init(name: "start", type: "number", description: "Start time in seconds (optional)", required: false),
            .init(name: "end", type: "number", description: "End time in seconds (optional)", required: false),
            .init(name: "limit", type: "integer", description: "Max segments (default 20)", required: false),
        ]
    )
    
    static let sessionSearchSegments = KnowledgeToolDefinition(
        name: "session.search_segments",
        description: "Search transcript segments within one or more sessions using hybrid lexical + semantic retrieval with graph recall when available. Returns timed hits with speaker labels and citations.",
        parameters: [
            .init(name: "session_ids", type: "array", description: "Session UUID list", required: true),
            .init(name: "query", type: "string", description: "Search query", required: true),
            .init(name: "limit", type: "integer", description: "Max hits (default 8)", required: false),
        ]
    )
    
    static let sessionGetTimeline = KnowledgeToolDefinition(
        name: "session.get_timeline",
        description: "Get bucketed timeline of transcript segments for temporal analysis.",
        parameters: [
            .init(name: "session_id", type: "string", description: "Session UUID", required: true),
            .init(name: "bucket_seconds", type: "integer", description: "Bucket size in seconds (default 60)", required: false),
        ]
    )
    
    static let knowledgeCompareSessions = KnowledgeToolDefinition(
        name: "knowledge.compare_sessions",
        description: "Compare themes across 2+ sessions. Returns structured comparison evidence.",
        parameters: [
            .init(name: "session_ids", type: "array", description: "Session UUID list (≥2)", required: true),
            .init(name: "focus_query", type: "string", description: "Optional focus query for thematic comparison", required: false),
            .init(name: "mode", type: "string", description: "Comparison mode: themes, speakers, timeline (default themes)", required: false),
        ]
    )
    
    static let finishWithEvidence = KnowledgeToolDefinition(
        name: "finish_with_evidence",
        description: "Control tool: finish with accepted evidence refs. Agent must call this when sufficient evidence is gathered.",
        parameters: [
            .init(name: "accepted_refs", type: "array", description: "List of accepted citation ref IDs", required: true),
        ]
    )
    
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
