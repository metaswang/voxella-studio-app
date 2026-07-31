import Foundation

struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var sourceIDs: [Int]
    var text: String
    var start: Double
    var end: Double
    var speaker: String?
    var characterBudget: Int?
    var overBudget: Bool

    init(
        id: Int,
        sourceIDs: [Int],
        text: String,
        start: Double,
        end: Double,
        speaker: String?,
        characterBudget: Int? = nil,
        overBudget: Bool = false
    ) {
        self.id = id
        self.sourceIDs = sourceIDs
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.characterBudget = characterBudget
        self.overBudget = overBudget
    }
}

struct SubtitleTrack: Codable, Equatable, Sendable {
    var sourceLanguage: String?
    var language: String?
    var cues: [SubtitleCue]
    /// True when cue boundaries were produced from word-level timestamp anchors.
    /// Older persisted tracks do not have this field and are treated as unverified.
    var usesWordTimestamps: Bool

    init(
        sourceLanguage: String?,
        language: String?,
        cues: [SubtitleCue],
        usesWordTimestamps: Bool = false
    ) {
        self.sourceLanguage = sourceLanguage
        self.language = language
        // Normalize at the model boundary so every consumer (transcript,
        // subtitles, translation, and dub script) sees the same text.  This
        // mirrors the postprocess worker's CJK join rules and prevents spaces
        // introduced by an LLM from appearing between Han/Kana characters.
        self.cues = cues.map { cue in
            var normalized = cue
            normalized.text = TranscriptSegmenter.normalizeDisplayText(
                cue.text,
                language: language ?? sourceLanguage
            )
            return normalized
        }
        self.usesWordTimestamps = usesWordTimestamps
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLanguage
        case language
        case cues
        case usesWordTimestamps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        let decodedCues = try container.decode([SubtitleCue].self, forKey: .cues)
        let resolvedLanguage = language ?? sourceLanguage
        // Codable decoding bypasses the designated initializer. Normalize here
        // as well so tracks persisted by older builds receive the same CJK
        // joining and punctuation spacing rules as newly-created tracks.
        cues = decodedCues.map { cue in
            var normalized = cue
            normalized.text = TranscriptSegmenter.normalizeDisplayText(
                cue.text,
                language: resolvedLanguage
            )
            return normalized
        }
        usesWordTimestamps = try container.decodeIfPresent(Bool.self, forKey: .usesWordTimestamps) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(cues, forKey: .cues)
        try container.encode(usesWordTimestamps, forKey: .usesWordTimestamps)
    }

    var text: String {
        TranscriptSegmenter.joinedText(
            cues.map(\.text),
            language: language ?? sourceLanguage
        )
    }

    /// Detect a persisted timed-segment fallback that must be rebuilt from word timestamps.
    /// The check is intentionally based on the transcript shape rather than a fixed cue
    /// count, so it remains valid for different languages and diarization granularities.
    func needsWordTimestampPreparation(for transcript: TranscriptionResult) -> Bool {
        if usesWordTimestamps { return false }
        guard !cues.isEmpty else { return true }
        let timedWordCount = transcript.words.reduce(into: 0) { count, word in
            guard let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, end > start else { return }
            count += 1
        }
        guard timedWordCount > 0 else { return false }
        let anchoredIDs = Set(cues.flatMap(\.sourceIDs))
        return anchoredIDs.count < timedWordCount
    }

    static func fromTranscript(_ transcript: TranscriptionResult) -> SubtitleTrack {
        let sourceSegments: [TranscriptionSegment]
        if transcript.segments.isEmpty {
            let timedWords = transcript.words.filter {
                guard let start = $0.start, let end = $0.end else { return false }
                return start.isFinite && end.isFinite && end > start
            }
            if let first = timedWords.first,
               let last = timedWords.last,
               let start = first.start,
               let end = last.end {
                sourceSegments = [
                    TranscriptionSegment(
                        text: transcript.text,
                        start: start,
                        end: end,
                        speaker: nil
                    )
                ]
            } else {
                sourceSegments = []
            }
        } else {
            sourceSegments = transcript.segments
        }
        return SubtitleTrack(
            sourceLanguage: transcript.language,
            language: transcript.language,
            cues: sourceSegments.enumerated().map { index, segment in
                SubtitleCue(
                    id: index,
                    sourceIDs: [index],
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker
                )
            },
            usesWordTimestamps: false
        )
    }

    static func fromDubSegments(
        _ segments: [DubRenderedSegment],
        language: String?
    ) -> SubtitleTrack? {
        guard !segments.isEmpty else { return nil }
        let orderedSegments = segments.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.index < rhs.index : lhs.start < rhs.start
        }
        let normalizedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLanguage = normalizedLanguage == nil
            || normalizedLanguage?.isEmpty == true
            || normalizedLanguage == "auto"
            ? nil
            : normalizedLanguage
        return SubtitleTrack(
            sourceLanguage: resolvedLanguage,
            language: resolvedLanguage,
            cues: orderedSegments.map { segment in
                SubtitleCue(
                    id: segment.index,
                    sourceIDs: [segment.sourceSubtitleID ?? segment.index],
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker
                )
            }
        )
    }

    func asTranscriptionResult(preservingWords words: [TranscriptionWord] = []) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            language: language,
            words: words,
            segments: cues.map {
                TranscriptionSegment(
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speaker: $0.speaker
                )
            }
        )
    }

    func assigningSpeaker(_ speaker: String, from start: Double, to end: Double) -> SubtitleTrack {
        let normalized = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, start.isFinite, end.isFinite, end > start else { return self }
        var updated = self
        for index in updated.cues.indices
        where updated.cues[index].end > start && updated.cues[index].start < end {
            updated.cues[index].speaker = normalized
        }
        return updated
    }

    func renamingSpeaker(_ current: String, to replacement: String) -> SubtitleTrack {
        let source = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return self }
        var updated = self
        for index in updated.cues.indices
        where updated.cues[index].speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == source {
            updated.cues[index].speaker = destination
        }
        return updated
    }
}

struct TranscriptionFlowPayload: Sendable {
    var languageCode: String?
    var speakerCount: Int?
    /// Optional media window in seconds, matching web clip_start_ms / clip_end_ms.
    var clipRangeSeconds: ClosedRange<Double>?
}

enum ScriptAlignmentSpeakerMode: Sendable {
    case providedSegments
    case diarize(requestedSpeakerCount: Int?)
    case none
}

struct ScriptAlignmentPayload: Sendable {
    var text: String?
    var languageCode: String?
    var speakerMode: ScriptAlignmentSpeakerMode = .providedSegments
}

struct SubtitleProcessingPayload: Sendable {
    var maximumTokensPerBatch = 180
    var maximumCharactersPerCue: Int?
    var maximumAttempts = 2
    var userInstruction: String?
    var invalidOutputFallback: SubtitleInvalidOutputFallback = .failFlow
}

enum SubtitleInvalidOutputFallback: Sendable {
    case failFlow
    case preserveTimedTranscript
}

struct TranslationFlowPayload: Sendable {
    var targetLanguage: String
    var maximumCuesPerBatch = 24
    var maximumAttempts = 2
    var userInstruction: String?
}

struct DubVoiceReference: Codable, Equatable, Sendable {
    var audioURL: URL
    var transcript: String
    var overrideSourceVoice = true
}

struct DubSegmentPayload: Codable, Equatable, Sendable {
    var index: Int
    var text: String
    var start: Double?
    var end: Double?
    var speaker: String?
    var sourceSubtitleID: Int?
    var options: [String: String]

    init(
        index: Int,
        text: String,
        start: Double? = nil,
        end: Double? = nil,
        speaker: String? = nil,
        sourceSubtitleID: Int? = nil,
        options: [String: String] = [:]
    ) {
        self.index = index
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.sourceSubtitleID = sourceSubtitleID
        self.options = options
    }
}

struct DubFlowPayload: Sendable {
    var segments: [DubSegmentPayload]
    var language: String
    var model: DubModelChoice
    var reference: DubVoiceReference?
    var speakerReferences: [String: DubVoiceReference]
    var segmentReferences: [Int: DubVoiceReference] = [:]
    var maximumChunkCharacters = 160
    var segmentGapSeconds = 0.2
}

struct DubRenderedSegment: Codable, Equatable, Sendable {
    var index: Int
    var text: String
    var start: Double
    var end: Double
    var speaker: String?
    var sourceSubtitleID: Int?
}

struct DubFlowResult: Sendable {
    var outputURL: URL
    var segments: [DubRenderedSegment]
}

enum MediaFlowInput: Sendable {
    case media(URL)
    case knownTextAudio(
        media: URL,
        script: String,
        spans: [KnownTextAlignmentSpan]
    )
    case transcript(
        transcript: TranscriptionResult,
        subtitles: SubtitleTrack?,
        translation: SubtitleTrack?
    )
    case script(String)
}

enum MediaFlowStep: Sendable {
    case transcribe(TranscriptionFlowPayload)
    case alignScript(ScriptAlignmentPayload)
    case prepareSubtitles(SubtitleProcessingPayload)
    case translate(TranslationFlowPayload)
    case dub(DubFlowPayload)

    var stage: MediaFlowStage {
        switch self {
        case .transcribe: .transcription
        case .alignScript: .alignment
        case .prepareSubtitles: .subtitlePreparation
        case .translate: .translation
        case .dub: .dubSynthesis
        }
    }

    var defaultWeight: Double {
        switch self {
        case .transcribe: 0.55
        case .alignScript: 0.25
        case .prepareSubtitles: 0.20
        case .translate: 0.25
        case .dub: 0.45
        }
    }
}

struct MediaFlowRequest: Sendable {
    var id = UUID()
    var input: MediaFlowInput
    var steps: [MediaFlowStep]
}

enum MediaFlowStage: String, Codable, Sendable {
    case flow
    case transcription
    case alignment
    case subtitlePreparation
    case translation
    case dubPreprocessing
    case dubReference
    case dubSynthesis
    case dubAssembly

    var title: String {
        switch self {
        case .flow: "Media flow"
        case .transcription: "Transcription"
        case .alignment: "Script alignment"
        case .subtitlePreparation: "Subtitle cleanup"
        case .translation: "Translation"
        case .dubPreprocessing: "Dub preprocessing"
        case .dubReference: "Voice reference"
        case .dubSynthesis: "Speech synthesis"
        case .dubAssembly: "Dub assembly"
        }
    }
}

enum MediaJobStatus: String, Codable, Sendable {
    case started
    case processing
    case completed
    case failed
    case cancelled
}

struct MediaJobProgressEvent: Codable, Equatable, Sendable {
    var jobID: UUID
    var stage: MediaFlowStage
    var status: MediaJobStatus
    var step: String
    var progress: Double
    var stageProgress: Double
    var current: Int?
    var total: Int?
    var message: String
    var timestamp: Date

    init(
        jobID: UUID,
        stage: MediaFlowStage,
        status: MediaJobStatus,
        step: String,
        progress: Double,
        stageProgress: Double,
        current: Int? = nil,
        total: Int? = nil,
        message: String,
        timestamp: Date = Date()
    ) {
        self.jobID = jobID
        self.stage = stage
        self.status = status
        self.step = step
        self.progress = min(1, max(0, progress))
        self.stageProgress = min(1, max(0, stageProgress))
        self.current = current
        self.total = total
        self.message = message
        self.timestamp = timestamp
    }
}

enum MediaFlowArtifact: Sendable {
    case transcription(TranscriptionResult, DiarizationDiagnostics)
    case alignment(KnownTextAlignmentOutput)
    case subtitles(SubtitleTrack)
    case translation(SubtitleTrack)
    case dub(DubFlowResult)
}

enum MediaJobEvent: Sendable {
    case progress(MediaJobProgressEvent)
    case artifact(MediaFlowArtifact)
}

enum MediaFlowError: LocalizedError {
    case emptyFlow
    case missingMedia
    case missingTranscript
    case missingSubtitleTrack
    case missingTargetLanguage
    case emptyDubScript
    case invalidLLMOutput(String)

    var errorDescription: String? {
        switch self {
        case .emptyFlow:
            "The media flow has no steps."
        case .missingMedia:
            "This flow step requires a media file."
        case .missingTranscript:
            "This flow step requires a transcript."
        case .missingSubtitleTrack:
            "This flow step requires prepared subtitles."
        case .missingTargetLanguage:
            "Choose a target language for translation."
        case .emptyDubScript:
            "The dub flow has no non-empty script segments."
        case .invalidLLMOutput(let reason):
            "The LLM returned invalid structured output: \(reason)"
        }
    }
}
