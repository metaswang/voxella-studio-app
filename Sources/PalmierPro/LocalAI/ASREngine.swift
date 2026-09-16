import Foundation

enum ASREngine: String, Codable, CaseIterable, Sendable {
    case qwen
    case parakeet
    case whisper

    var title: String {
        switch self {
        case .qwen: "Qwen3-ASR"
        case .parakeet: "Parakeet v3"
        case .whisper: "Whisper"
        }
    }

    var chunkConfiguration: ASRChunkPlannerConfiguration {
        switch self {
        case .qwen:
            ASRChunkPlannerConfiguration(
                maximumWindowDuration: 90,
                boundaryContextDuration: 0.75,
                maximumMergeGap: 0.75
            )
        case .parakeet:
            ASRChunkPlannerConfiguration(
                maximumWindowDuration: 180,
                boundaryContextDuration: 1,
                maximumMergeGap: 1
            )
        case .whisper:
            ASRChunkPlannerConfiguration(
                maximumWindowDuration: 28,
                boundaryContextDuration: 0.75,
                maximumMergeGap: 0.75
            )
        }
    }
}

enum ASREngineRouteReason: String, Sendable {
    case userLocked
    case weightedEvidence
    case insufficientSpeech
    case mixedLanguages
    case noReliableLanguageAnchor
    case insufficientWeightedEvidence
    case invalidLanguageEvidence
    case engineCoverage
    case chineseEnglishConflict
    case whisperLanguage
    case insufficientEngineCoverage
}

struct ASREngineScores: Equatable, Sendable {
    var qwen: Float
    var parakeet: Float
    var whisper: Float

    static let zero = ASREngineScores(qwen: 0, parakeet: 0, whisper: 0)

    subscript(_ engine: ASREngine) -> Float {
        switch engine {
        case .qwen: qwen
        case .parakeet: parakeet
        case .whisper: whisper
        }
    }

    var ranked: [(engine: ASREngine, score: Float)] {
        [
            (ASREngine.qwen, qwen),
            (.parakeet, parakeet),
            (.whisper, whisper),
        ].sorted { $0.score > $1.score }
    }

    var leading: (engine: ASREngine, score: Float) { ranked[0] }

    var runnerUp: (engine: ASREngine, score: Float) { ranked[1] }

    var margin: Float { leading.score - runnerUp.score }
}

struct ASREngineRouteDecision: Equatable, Sendable {
    var engine: ASREngine
    var scores: ASREngineScores
    /// Per-window language evidence projected onto the preferred engine for each language.
    /// `scores` remains the raw model-capability coverage for diagnostics and compatibility.
    var engineVoteScores: ASREngineScores = .zero
    var reason: ASREngineRouteReason
    var topLanguage: String?
    var parakeetDomainLanguage: String?
    var whisperHint: String?
    var routeConfidence: Float
    var speechDuration: Double
    var languageVote: ASRLanguageVoteResult? = nil
}
