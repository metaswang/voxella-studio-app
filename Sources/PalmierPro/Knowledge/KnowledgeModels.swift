import Foundation

enum KnowledgeQAModelPolicy {
    static let includeReranker = true

    /// Local MLX answer model from Settings, if/when cataloged.
    /// P0 answer is hosted/BYOK (`AITransportPolicy`); nil = cloud-only answer.
    /// Cloud answer still requires local WeMM (see `knowledgeQAPlan`).
    @MainActor
    static var localAnswerModelID: LocalModelID? { nil }

    @MainActor
    static func currentPlan(models: LocalModelManager = .shared) -> LocalModelInstallPlan {
        models.knowledgeQAInstallPlan(
            answerModelID: localAnswerModelID,
            includeReranker: includeReranker
        )
    }
}

enum KnowledgeQAReadyGate {
    static func shouldFlushPending(
        pendingQuery: String?,
        missingCount: Int,
        isAnswering: Bool
    ) -> Bool {
        let query = pendingQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !query.isEmpty && missingCount == 0 && !isAnswering
    }
}

enum KnowledgeQAScope: Hashable, Sendable {
    case all
    case session(UUID)
    /// Ordered unique selection. `storageKey` uses sorted IDs so conversation identity is order-stable.
    case sessions([UUID])

    /// Normalize click/selection into the canonical scope case.
    static func fromSelection(_ ids: [UUID]) -> KnowledgeQAScope {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            ordered.append(id)
        }
        switch ordered.count {
        case 0: return .all
        case 1: return .session(ordered[0])
        default: return .sessions(ordered)
        }
    }

    var sessionID: UUID? {
        switch self {
        case .all: return nil
        case let .session(id): return id
        case let .sessions(ids): return ids.count == 1 ? ids[0] : nil
        }
    }

    /// Selection IDs in display order (empty for `.all`).
    var sessionIDs: [UUID] {
        switch self {
        case .all: return []
        case let .session(id): return [id]
        case let .sessions(ids): return ids
        }
    }

    var storageKey: String {
        switch self {
        case .all:
            return "all"
        case let .session(id):
            return "session.\(id.uuidString)"
        case let .sessions(ids):
            let sorted = ids.map(\.uuidString).sorted()
            return "sessions.\(sorted.joined(separator: ","))"
        }
    }

    var title: String {
        switch self {
        case .all: "All knowledge"
        case .session: "Session"
        case let .sessions(ids): "\(ids.count) sessions"
        }
    }

    static func == (lhs: KnowledgeQAScope, rhs: KnowledgeQAScope) -> Bool {
        lhs.storageKey == rhs.storageKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storageKey)
    }
}

extension KnowledgeQAScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case sessionID
        case sessionIDs
    }

    private enum Kind: String, Codable {
        case all
        case session
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .all:
            self = .all
        case .session:
            let id = try container.decode(UUID.self, forKey: .sessionID)
            self = .session(id)
        case .sessions:
            let ids = try container.decode([UUID].self, forKey: .sessionIDs)
            self = KnowledgeQAScope.fromSelection(ids)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case let .session(id):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(id, forKey: .sessionID)
        case let .sessions(ids):
            try container.encode(Kind.sessions, forKey: .kind)
            try container.encode(ids, forKey: .sessionIDs)
        }
    }
}

enum KnowledgeAnswerMode: String, Codable, Sendable {
    case concise
    case normal
    case detailed
}

enum KnowledgeSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case recording
    case meeting
    case upload
    case netVideo = "net_video"
    case dub
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All types"
        case .recording: "Recording"
        case .meeting: "Meeting"
        case .upload: "Upload"
        case .netVideo: "Net video"
        case .dub: "Voiceover"
        case .other: "Other"
        }
    }

    /// Best-effort **display** labels for the Mac session list.
    /// Not a 1:1 enum with voxella-web `source_type` — do not add cases just to match web.
    ///
    /// Mapping (Mac `WorkbenchSessionType` → display `KnowledgeSourceType`):
    /// | WorkbenchSessionType        | Display     | Notes |
    /// | record, live                | recording   | screen/mic + live transcribe |
    /// | meetingRecord, googleMeet   | meeting     | Meet bot |
    /// | upload                      | upload      | file transcribe |
    /// | netVideo                    | net_video   | YouTube / net video |
    /// | dub                         | dub         | AI voiceover; no web analog required |
    ///
    /// Web `source_type` values (file, url, youtube, meeting, …) stay on web.
    static func from(sessionType: WorkbenchSessionType) -> KnowledgeSourceType {
        switch sessionType {
        case .record, .live: .recording
        case .meetingRecord, .googleMeet: .meeting
        case .upload: .upload
        case .netVideo: .netVideo
        case .dub: .dub
        }
    }
}

enum KnowledgeIndexFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case indexed
    /// P0: Indexing filter is placeholder. Real indexing progress flags (lexical/embedding ready) land in P1.
    case indexing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All status"
        case .indexed: "Indexed (approx.)"
        case .indexing: "Indexing"
        }
    }
}

enum KnowledgeOriginFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case local
    case cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All origins"
        case .local: "Local"
        case .cloud: "Cloud"
        }
    }

    var origins: Set<KnowledgeSourceOrigin>? {
        switch self {
        case .all: nil
        case .local: [.local]
        case .cloud: [.cloud]
        }
    }
}

/// Pure list filtering for the Knowledge left pane (testable; not MainActor).
enum KnowledgeListQuery {
    static func filterRows(
        _ rows: [KnowledgeListRow],
        typeFilter: KnowledgeSourceType,
        indexFilter: KnowledgeIndexFilter,
        originFilter: KnowledgeOriginFilter = .all,
        allowedOrigins: Set<KnowledgeSourceOrigin>,
        query: String
    ) -> [KnowledgeListRow] {
        let uiOrigins = originFilter.origins
        let effective = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: allowedOrigins.contains(.cloud),
            uiFilter: uiOrigins
        )
        return rows.filter { row in
            if !effective.contains(row.sourceOrigin) { return false }
            if typeFilter != .all, row.sourceType != typeFilter { return false }
            switch indexFilter {
            case .all: break
            case .indexed:
                if !row.isIndexed { return false }
            case .indexing:
                if !row.isIndexing { return false }
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return row.title.localizedCaseInsensitiveContains(q)
                || row.sessionType.label.localizedCaseInsensitiveContains(q)
                || row.metaLabel.localizedCaseInsensitiveContains(q)
        }
    }
}

struct KnowledgeSourceRef: Equatable, Hashable, Codable, Identifiable, Sendable {
    var id: String { "\(sourceID)|\(startTime ?? -1)|\(endTime ?? -1)|\(chunkIndex ?? -1)" }

    var sourceID: String
    var sourceType: String
    var title: String
    var uri: String?
    var page: Int?
    var startTime: Double?
    var endTime: Double?
    var parentID: String?
    var chunkIndex: Int?
    var language: String?
    var speaker: String?
    var snippet: String?
    /// The retrieved text to highlight in the transcript.
    var matchText: String?

    var sessionUUID: UUID? { UUID(uuidString: sourceID) }

    var timestampLabel: String? {
        guard let startTime else { return nil }
        return Self.formatTimestamp(startTime)
    }

    var chipLabel: String {
        var parts = [title]
        if let speaker, !speaker.isEmpty { parts.append(speaker) }
        if let timestampLabel { parts.append(timestampLabel) }
        return parts.joined(separator: " · ")
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct KnowledgeTranscriptTarget: Equatable, Sendable {
    let startTime: Double?
    let endTime: Double?
    let matchText: String?

    init(startTime: Double?, endTime: Double?, matchText: String?) {
        self.startTime = startTime
        self.endTime = endTime
        self.matchText = matchText
    }

    init(source: KnowledgeSourceRef) {
        self.init(
            startTime: source.startTime,
            endTime: source.endTime,
            matchText: source.matchText ?? source.snippet
        )
    }
}

enum KnowledgeTranscriptNavigation {
    static func segmentIndex(
        for target: KnowledgeTranscriptTarget,
        in segments: [TranscriptionSegment]
    ) -> Int? {
        guard !segments.isEmpty else { return nil }

        if let start = target.startTime, start.isFinite {
            let end = if let candidate = target.endTime, candidate.isFinite {
                max(start, candidate)
            } else {
                start
            }
            let validIndices = segments.indices.filter { index in
                segments[index].start.isFinite && segments[index].end.isFinite
            }
            if let overlapping = validIndices.first(where: { index in
                let segment = segments[index]
                return segment.start <= end && segment.end >= start
            }) {
                return overlapping
            }

            return validIndices.min { lhs, rhs in
                abs(segments[lhs].start - start) < abs(segments[rhs].start - start)
            }
        }

        return nil
    }
}

struct KnowledgeQARequest: Sendable {
    /// Identifies one user submission so late events from a cancelled request
    /// cannot mutate the next request's UI state.
    let requestID: UUID
    var queryText: String
    var conversationID: UUID
    var scope: KnowledgeQAScope
    var answerMode: KnowledgeAnswerMode
    var allowCloud: Bool
    var originFilter: Set<KnowledgeSourceOrigin>?
    var history: [KnowledgeMessage]

    init(
        queryText: String,
        conversationID: UUID,
        scope: KnowledgeQAScope,
        answerMode: KnowledgeAnswerMode = .normal,
        allowCloud: Bool = true,
        originFilter: Set<KnowledgeSourceOrigin>? = nil,
        history: [KnowledgeMessage] = [],
        requestID: UUID = UUID()
    ) {
        self.requestID = requestID
        self.queryText = queryText
        self.conversationID = conversationID
        self.scope = scope
        self.answerMode = answerMode
        self.allowCloud = allowCloud
        self.originFilter = originFilter
        self.history = history
    }
}

enum KnowledgeAnswerEvent: Sendable {
    case status(String)
    case delta(String)
    case citations([KnowledgeSourceRef])
    case recoveryActions([KnowledgeRecoveryAction])
    case clarification(String)
    case finished(String)
    case failed(String)
}

enum KnowledgeRecoveryAction: String, Codable, CaseIterable, Sendable {
    case account
    case aiSettings
}

enum KnowledgeMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct KnowledgeMessage: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var conversationID: UUID
    var role: KnowledgeMessageRole
    var content: String
    var citations: [KnowledgeSourceRef]
    var createdAt: Date
    var isStreaming: Bool
    var recoveryActions: [KnowledgeRecoveryAction]

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: KnowledgeMessageRole,
        content: String,
        citations: [KnowledgeSourceRef] = [],
        createdAt: Date = .now,
        isStreaming: Bool = false,
        recoveryActions: [KnowledgeRecoveryAction] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.citations = citations
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.recoveryActions = recoveryActions
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, role, content, citations, createdAt, isStreaming, recoveryActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        conversationID = try container.decode(UUID.self, forKey: .conversationID)
        role = try container.decode(KnowledgeMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        citations = try container.decodeIfPresent([KnowledgeSourceRef].self, forKey: .citations) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        recoveryActions = try container.decodeIfPresent([KnowledgeRecoveryAction].self, forKey: .recoveryActions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(citations, forKey: .citations)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(recoveryActions, forKey: .recoveryActions)
    }
}

@MainActor
enum KnowledgeAnswerAvailability: Equatable {
    case ready
    case localAccessRequired
    case signInOrBYOKRequired
    case byokAnswerRouteRequired
    case byokGraphRouteRequired
    case hostedCreditsExhausted

    static func current() -> Self {
        guard AccountService.shared.hasFeatureAccess else { return .localAccessRequired }
        switch AITransportPolicy.current {
        case .unavailable:
            return .signInOrBYOKRequired
        case .hosted:
            return HostedCreditAvailability.shared.isExhausted ? .hostedCreditsExhausted : .ready
        case .byok:
            guard LLMSettingsStore.shared.hasConfiguredModel(for: .chat) else {
                return .byokAnswerRouteRequired
            }
            if KnowledgeGraphSettings.shared.isEnabled,
               (!LLMSettingsStore.shared.hasConfiguredModel(for: .graphExtraction)
                    || !LLMSettingsStore.shared.hasConfiguredModel(for: .graphQueryUnderstanding))
            {
                return .byokGraphRouteRequired
            }
            return .ready
        }
    }

    var message: String? {
        switch self {
        case .ready: nil
        case .localAccessRequired: "Trial or Lifetime access is required to use the local Knowledge Base."
        case .signInOrBYOKRequired: "Sign in or configure BYOK to ask your knowledge base."
        case .byokAnswerRouteRequired: "Configure an AI provider and API key in Settings → AI before asking."
        case .byokGraphRouteRequired: "Configure the Knowledge Base AI tasks in Settings → AI, or turn off graph recall."
        case .hostedCreditsExhausted: "Hosted AI credits are exhausted. Manage credits or configure BYOK in Settings → AI."
        }
    }

    var recoveryActions: [KnowledgeRecoveryAction] {
        switch self {
        case .signInOrBYOKRequired: [.account, .aiSettings]
        case .byokAnswerRouteRequired, .byokGraphRouteRequired: [.aiSettings]
        case .hostedCreditsExhausted: [.account, .aiSettings]
        case .ready, .localAccessRequired: []
        }
    }
}

struct KnowledgeConversation: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var scope: KnowledgeQAScope
    var sessionID: UUID?
    var title: String
    var updatedAt: Date
    var createdAt: Date

    init(
        id: UUID = UUID(),
        scope: KnowledgeQAScope,
        title: String = "Knowledge chat",
        updatedAt: Date = .now,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scope = scope
        self.sessionID = scope.sessionID
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

struct KnowledgeListRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sessionType: WorkbenchSessionType
    var sourceType: KnowledgeSourceType
    var sourceOrigin: KnowledgeSourceOrigin
    var modifiedAt: Date
    var duration: Double?
    /// P0 approximation of SessionIndex `lexical_ready`. Real flag is P1.
    var lexicalReady: Bool
    /// P0 does not know embedding readiness; left false until SessionIndex flags land in P1.
    var embeddingReady: Bool
    var hasTranscript: Bool

    /// P0: "indexed" ~ has transcript / searchable result. Not SessionIndex lexical/embedding.
    var isIndexed: Bool { lexicalReady }
    var isIndexing: Bool { hasTranscript && !lexicalReady }
    /// Unindexed rows (no transcript) can be listed when "Show all" is on, but cannot be asked.
    var isQAAble: Bool { isIndexed }

    var statusLabel: String {
        if isIndexed { return "Indexed (approx.)" }
        if isIndexing { return "Indexing" }
        return "No transcript"
    }

    var indexStatusHelp: String {
        if isQAAble {
            return "Approximate: based on transcript presence. Real SessionIndex lexical/embedding flags land in P1."
        }
        return "Transcription is required first before this session can be used for QA."
    }

    /// P0 searchable / indexed approximation. Real SessionIndex flags are P1.
    static func p0IsSearchable(hasTranscript: Bool, hasUsableResult: Bool) -> Bool {
        hasTranscript || hasUsableResult
    }

    var originBadge: String { sourceOrigin.label }

    var metaLabel: String {
        var parts: [String] = [originBadge, sessionType.label]
        if let duration, duration > 0 {
            parts.append(Self.formatDuration(duration))
        }
        parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    @MainActor
    var localizedMetaLabel: String {
        var parts: [String] = [
            L10n.string(originBadge),
            L10n.string(key: sessionType.label),
        ]
        if let duration, duration > 0 {
            parts.append(Self.formatDuration(duration))
        }
        parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            let h = m / 60
            let rm = m % 60
            return String(format: "%dh %02dm", h, rm)
        }
        return String(format: "%d:%02d", m, s)
    }
}
