import Foundation

enum SessionIndexUnitKind: String, Codable, Sendable {
    case sessionCard = "session_card"
    case transcriptChunk = "transcript_chunk"
    case mediaClip = "media_clip"
}

enum SessionIndexModality: String, Codable, Sendable {
    case text
    case video
    case mixed
}

/// Whether the indexed session originated on-device or from cloud sync.
/// Stored on ingest; runtime filter uses login state. Logout does not delete cloud rows.
enum KnowledgeSourceOrigin: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Local"
        case .cloud: "Cloud"
        }
    }

    static func resolve(isCloudStorage: Bool, hasRemoteSessionID: Bool) -> KnowledgeSourceOrigin {
        (isCloudStorage || hasRemoteSessionID) ? .cloud : .local
    }

    /// Unsigned: local only. Signed-in: local+cloud, intersected with optional UI filter.
    static func effectiveOrigins(
        isSignedIn: Bool,
        uiFilter: Set<KnowledgeSourceOrigin>? = nil
    ) -> Set<KnowledgeSourceOrigin> {
        let allowed: Set<KnowledgeSourceOrigin> = isSignedIn ? [.local, .cloud] : [.local]
        guard let uiFilter else { return allowed }
        return uiFilter.intersection(allowed)
    }
}

struct SessionSearchFilter: Equatable, Sendable {
    var sessionID: UUID?
    /// When set, restricts hits to this session set (multi-select KB scope).
    var sessionIDs: Set<UUID>?
    var speakerLabel: String?
    var start: Double?
    var end: Double?
    var hasVideo: Bool?
    var language: String?
    var modality: SessionIndexModality?
    /// nil = do not constrain origin (tests / internal). User-facing search should set this.
    var sourceOrigins: Set<KnowledgeSourceOrigin>?
    /// Cloud rows are private to the signed-in owner. Local rows are device scoped.
    var cloudOwnerUserID: String?
    var limit: Int

    init(
        sessionID: UUID? = nil,
        sessionIDs: Set<UUID>? = nil,
        speakerLabel: String? = nil,
        start: Double? = nil,
        end: Double? = nil,
        hasVideo: Bool? = nil,
        language: String? = nil,
        modality: SessionIndexModality? = nil,
        sourceOrigins: Set<KnowledgeSourceOrigin>? = nil,
        cloudOwnerUserID: String? = nil,
        limit: Int = 20
    ) {
        self.sessionID = sessionID
        self.sessionIDs = sessionIDs
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.hasVideo = hasVideo
        self.language = language
        self.modality = modality
        self.sourceOrigins = sourceOrigins
        self.cloudOwnerUserID = cloudOwnerUserID
        self.limit = max(1, min(limit, 50))
    }

    static func visible(
        isSignedIn: Bool,
        sessionID: UUID? = nil,
        sessionIDs: Set<UUID>? = nil,
        uiFilter: Set<KnowledgeSourceOrigin>? = nil,
        cloudOwnerUserID: String? = nil,
        limit: Int = 20
    ) -> SessionSearchFilter {
        SessionSearchFilter(
            sessionID: sessionID,
            sessionIDs: sessionIDs,
            sourceOrigins: KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: isSignedIn, uiFilter: uiFilter),
            cloudOwnerUserID: cloudOwnerUserID,
            limit: limit
        )
    }
}

struct SessionSearchHit: Equatable, Sendable {
    var sessionID: UUID
    var title: String
    var unitID: Int
    var kind: SessionIndexUnitKind
    var start: Double?
    var end: Double?
    var speakerLabels: [String]
    var text: String
    var score: Double
    var matchSource: String
    var snippet: String?
    var cueIDs: [Int]
    var hasVideo: Bool
    var language: String?
    var quoteSpan: WordSpanMapper.QuoteSpan?
    /// Session metadata copied onto hits so QA and clients do not need a second lookup.
    var duration: Double = 0
    var sourceOrigin: KnowledgeSourceOrigin = .local
    var sessionType: WorkbenchSessionType = .upload
    var sourceCreatedAt: Double? = nil
    var sourceModifiedAt: Double? = nil
}

struct SessionCard: Equatable, Sendable {
    var sessionID: UUID
    var title: String
    var tag: String?
    var duration: Double
    var hasVideo: Bool
    var language: String?
    var mediaPath: String
    var speakers: [SessionSpeaker]
    var summaryMarkdown: String?
    var summaryExcerpt: String?
    var matchSource: String?
    var snippet: String?
    var lexicalReady: Bool
    var embeddingReady: Bool
    var sourceOrigin: KnowledgeSourceOrigin = .local
    var remoteSessionID: UUID? = nil
    var ownerUserID: String? = nil
    var sessionType: WorkbenchSessionType = .upload
    var sourceCreatedAt: Double? = nil
    var sourceModifiedAt: Double? = nil
}

/// Complete, metadata-only view of an indexed session. This is intentionally
/// separate from transcript hits so inventory questions can query every session
/// even when no transcript term matches.
struct SessionCatalogEntry: Equatable, Sendable {
    var sessionID: UUID
    var title: String
    var tag: String?
    var summaryMarkdown: String?
    var language: String?
    var duration: Double
    var hasVideo: Bool
    var mediaPath: String
    var sessionType: WorkbenchSessionType
    var sourceOrigin: KnowledgeSourceOrigin
    var remoteSessionID: UUID?
    var ownerUserID: String?
    var sourceCreatedAt: Double?
    var sourceModifiedAt: Double?
    var lexicalReady: Bool
    var embeddingReady: Bool
    var indexedAt: Double?
}

struct SessionSpeaker: Equatable, Sendable {
    var label: String
    var displayName: String
}

struct ClipCandidate: Equatable, Sendable {
    var sessionID: UUID
    var start: Double
    var end: Double
    var speakerLabel: String?
    var text: String
    var cueIDs: [Int]
    var mediaPath: String
}

struct SessionIndexFreshness: Equatable, Sendable {
    var generation: Int
    var lexicalReady: Bool
    var embeddingReady: Bool
}

enum SessionIndexIngestAction: Equatable, Sendable {
    case replace
    case embedOnly
    case skip

    static func resolve(freshness: SessionIndexFreshness?, generation: Int) -> SessionIndexIngestAction {
        guard let freshness, freshness.lexicalReady, freshness.generation == generation else {
            return .replace
        }
        return freshness.embeddingReady ? .skip : .embedOnly
    }
}

struct SessionIndexSnapshot: Sendable {
    /// Bump when lexical unit shape changes so historical rows rebuild.
    static let ingestFormat = 4

    var sessionID: UUID
    var title: String
    var tag: String?
    var summaryMarkdown: String?
    var language: String?
    var duration: Double
    var mediaDurationSec: Double? = nil
    var durationProvenance: String = "legacy_unknown"
    var lastSpokenEndSec: Double? = nil
    var transcribedStartSec: Double? = nil
    var transcribedEndSec: Double? = nil
    var hasVideo: Bool
    var mediaPath: String
    var sourceMTime: Double?
    /// Original session dates, distinct from index maintenance timestamps.
    var sourceCreatedAt: Double? = nil
    var sourceModifiedAt: Double? = nil
    var generation: Int
    var speakers: [SessionSpeaker]
    var segments: [TranscriptionSegment]
    var words: [TranscriptionWord]
    var cues: [SubtitleCue]
    var shotBounds: [Double]
    var sourceOrigin: KnowledgeSourceOrigin = .local
    var remoteSessionID: UUID? = nil
    var ownerUserID: String? = nil
    var sessionType: WorkbenchSessionType = .upload

    static func generation(modifiedAt: Date) -> Int {
        ingestFormat &* 1_000_000_000_000 + Int(modifiedAt.timeIntervalSince1970)
    }
}
