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

struct SessionSearchFilter: Equatable, Sendable {
    var sessionID: UUID?
    var speakerLabel: String?
    var start: Double?
    var end: Double?
    var hasVideo: Bool?
    var language: String?
    var modality: SessionIndexModality?
    var limit: Int

    init(
        sessionID: UUID? = nil,
        speakerLabel: String? = nil,
        start: Double? = nil,
        end: Double? = nil,
        hasVideo: Bool? = nil,
        language: String? = nil,
        modality: SessionIndexModality? = nil,
        limit: Int = 20
    ) {
        self.sessionID = sessionID
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.hasVideo = hasVideo
        self.language = language
        self.modality = modality
        self.limit = max(1, min(limit, 50))
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
    static let ingestFormat = 2

    var sessionID: UUID
    var title: String
    var tag: String?
    var summaryMarkdown: String?
    var language: String?
    var duration: Double
    var hasVideo: Bool
    var mediaPath: String
    var sourceMTime: Double?
    var generation: Int
    var speakers: [SessionSpeaker]
    var segments: [TranscriptionSegment]
    var words: [TranscriptionWord]
    var cues: [SubtitleCue]
    var shotBounds: [Double]

    static func generation(modifiedAt: Date) -> Int {
        ingestFormat &* 1_000_000_000_000 + Int(modifiedAt.timeIntervalSince1970)
    }
}
