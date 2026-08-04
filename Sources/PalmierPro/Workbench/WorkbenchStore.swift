import AppKit
import Foundation
import Observation

enum WorkbenchRoute: String, Codable, CaseIterable, Identifiable {
    case recent
    case dashboard
    case transcribe
    case dub
    case voiceLibrary
    case videoEditor
    case session

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .dashboard: "Dashboard"
        case .transcribe: "Transcribe"
        case .dub: "Dub"
        case .voiceLibrary: "Voice Library"
        case .videoEditor: "Video Editor"
        case .session: "Session"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .dashboard: "square.grid.2x2"
        case .transcribe: "text.bubble"
        case .dub: "waveform.and.mic"
        case .voiceLibrary: "waveform.badge.magnifyingglass"
        case .videoEditor: "timeline.selection"
        case .session: "doc.text.magnifyingglass"
        }
    }

    /// Sidebar glyph aligned with `voxella-web` workbench nav icons.
    var navGlyph: WorkbenchNavGlyph {
        switch self {
        case .transcribe: .transcription
        case .dub: .voiceover
        default: .system(systemImage)
        }
    }

    static let sidebarRoutes: [WorkbenchRoute] = [
        .recent, .dashboard, .transcribe, .dub, .voiceLibrary, .videoEditor,
    ]
}

enum WorkbenchJobState: String, Codable, Hashable, Sendable {
    case ready
    case running
    case cancelling
    case completed
    case cancelled
    case failed

    var label: String {
        switch self {
        case .ready: "Ready"
        case .running: "Processing"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Needs attention"
        }
    }
}

enum SpeakerCountOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case one
    case two
    case three
    case four

    var id: String { rawValue }

    var count: Int? {
        switch self {
        case .auto: nil
        case .one: 1
        case .two: 2
        case .three: 3
        case .four: 4
        }
    }

    var label: String {
        switch self {
        case .auto: "Auto-detect"
        case .one: "1 speaker"
        case .two: "2 speakers"
        case .three: "3 speakers"
        case .four: "4 speakers"
        }
    }
}

enum WorkbenchTranscriptTrack: String, Codable, CaseIterable, Identifiable, Sendable {
    case source
    case translation

    var id: String { rawValue }
    var label: String { self == .source ? "Source" : "Translation" }
}

struct WorkbenchTranslationTrack: Codable, Identifiable, Equatable, Sendable {
    var languageCode: String
    var track: SubtitleTrack
    var createdAt = Date()

    var id: String { languageCode }

    var compactLanguageLabel: String {
        WorkbenchLanguageLabel.compact(languageCode)
    }

    var displayLanguageLabel: String {
        WorkbenchLanguageLabel.display(languageCode)
    }
}

enum WorkbenchLanguageLabel {
    static func compact(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "—" }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return primary.lowercased()
    }

    static func display(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Unknown" }
        if let name = Locale.current.localizedString(forIdentifier: normalized) {
            return name
        }
        if let primary = normalized.split(separator: "-").first,
           let name = Locale.current.localizedString(forLanguageCode: String(primary)) {
            return name
        }
        return normalized
    }
}

struct WorkbenchTranscriptionJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var sourcePath: String
    var customTitle: String?
    var createdAt = Date()
    var modifiedAt = Date()
    var state: WorkbenchJobState = .ready
    var languageCode: String?
    var speakerCount: SpeakerCountOption = .auto
    var clipStartMs: Int?
    var clipEndMs: Int?
    var batchID: UUID?
    var result: TranscriptionResult?
    var editedText = ""
    var useLLMSubtitleProcessing: Bool?
    var targetLanguageCode: String?
    var subtitleTrack: SubtitleTrack?
    /// Multi-target translation tracks for one source (aligned with postprocess translation tracks).
    var translationTracks: [WorkbenchTranslationTrack] = []
    var selectedTranslationLanguageCode: String?
    var selectedTrack: WorkbenchTranscriptTrack?
    var summaryMarkdown: String?
    var summaryTemplateID: String?
    var summaryTemplateName: String?
    var sessionTag: String?
    var internalSummary: String?
    var summaryState: WorkbenchJobState?
    var summaryErrorMessage: String?
    var progress: Double = 0
    var progressMessage = "Ready to transcribe"
    var progressStage: LocalSpeechStage?
    var flowProgressStage: MediaFlowStage?
    var progressStep: String?
    var progressCompleted: Int?
    var progressTotal: Int?
    var diarizationDiagnostics: DiarizationDiagnostics?
    var errorMessage: String?

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var originalFilename: String { sourceURL.lastPathComponent }
    var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }
    var sessionTitle: String {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayName : trimmed
    }

    var clipRangeSeconds: ClosedRange<Double>? {
        guard let startMs = clipStartMs, let endMs = clipEndMs, endMs > startMs else { return nil }
        return Double(startMs) / 1000 ... Double(endMs) / 1000
    }

    func shouldProcessSubtitles(hasAPIKey: Bool) -> Bool {
        useLLMSubtitleProcessing ?? hasAPIKey
    }

    var normalizedTargetLanguageCode: String? {
        let trimmed = targetLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var translationTrack: SubtitleTrack? {
        get {
            if let selectedTranslationLanguageCode,
               let match = translationTracks.first(where: {
                   $0.languageCode.caseInsensitiveCompare(selectedTranslationLanguageCode) == .orderedSame
               }) {
                return match.track
            }
            return translationTracks.first?.track
        }
        set {
            guard let newValue else { return }
            let code = (newValue.language ?? targetLanguageCode ?? "und")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            upsertTranslation(newValue, languageCode: code.isEmpty ? "und" : code)
        }
    }

    mutating func upsertTranslation(_ track: SubtitleTrack, languageCode: String) {
        let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        var next = track
        next.language = code
        if let index = translationTracks.firstIndex(where: {
            $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
        }) {
            translationTracks[index].track = next
            translationTracks[index].createdAt = Date()
        } else {
            translationTracks.append(WorkbenchTranslationTrack(languageCode: code, track: next))
        }
        selectedTranslationLanguageCode = code
        targetLanguageCode = code
    }

    var currentTrack: WorkbenchTranscriptTrack {
        if selectedTrack == .translation, translationTrack != nil { return .translation }
        return .source
    }
    var sourceTimedResult: TranscriptionResult? {
        subtitleTrack?.asTranscriptionResult(preservingWords: result?.words ?? []) ?? result
    }
    var displayedResult: TranscriptionResult? {
        let timed = currentTrack == .translation
            ? translationTrack?.asTranscriptionResult()
            : sourceTimedResult
        return timed?.aggregatingSegments()
    }
    var displayedSegments: [TranscriptionSegment] {
        displayedResult?.segments ?? []
    }
    var speakerLabels: [String] {
        let values = (result?.words.compactMap(\.speaker) ?? [])
            + (result?.segments.compactMap(\.speaker) ?? [])
            + (subtitleTrack?.cues.compactMap(\.speaker) ?? [])
            + (translationTracks.flatMap { $0.track.cues.compactMap(\.speaker) })
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
    var displayedText: String {
        currentTrack == .translation ? (translationTrack?.text ?? "") : editedText
    }

    var isActivelyProcessing: Bool {
        state == .running || state == .cancelling
    }

    enum CodingKeys: String, CodingKey {
        case id, sourcePath, customTitle, createdAt, modifiedAt, state
        case languageCode, speakerCount, clipStartMs, clipEndMs, batchID
        case result, editedText, useLLMSubtitleProcessing, targetLanguageCode
        case subtitleTrack, translationTrack, translationTracks
        case selectedTranslationLanguageCode, selectedTrack
        case summaryMarkdown, summaryTemplateID, summaryTemplateName
        case sessionTag, internalSummary, summaryState, summaryErrorMessage
        case progress, progressMessage, progressStage, flowProgressStage
        case progressStep, progressCompleted, progressTotal
        case diarizationDiagnostics, errorMessage
    }

    init(
        id: UUID = UUID(),
        sourcePath: String,
        customTitle: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        state: WorkbenchJobState = .ready,
        languageCode: String? = nil,
        speakerCount: SpeakerCountOption = .auto,
        clipStartMs: Int? = nil,
        clipEndMs: Int? = nil,
        batchID: UUID? = nil,
        result: TranscriptionResult? = nil,
        editedText: String = "",
        useLLMSubtitleProcessing: Bool? = nil,
        targetLanguageCode: String? = nil,
        subtitleTrack: SubtitleTrack? = nil,
        translationTracks: [WorkbenchTranslationTrack] = [],
        selectedTranslationLanguageCode: String? = nil,
        selectedTrack: WorkbenchTranscriptTrack? = nil,
        summaryMarkdown: String? = nil,
        summaryTemplateID: String? = nil,
        summaryTemplateName: String? = nil,
        sessionTag: String? = nil,
        internalSummary: String? = nil,
        summaryState: WorkbenchJobState? = nil,
        summaryErrorMessage: String? = nil,
        progress: Double = 0,
        progressMessage: String = "Ready to transcribe",
        progressStage: LocalSpeechStage? = nil,
        flowProgressStage: MediaFlowStage? = nil,
        progressStep: String? = nil,
        progressCompleted: Int? = nil,
        progressTotal: Int? = nil,
        diarizationDiagnostics: DiarizationDiagnostics? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.state = state
        self.languageCode = languageCode
        self.speakerCount = speakerCount
        self.clipStartMs = clipStartMs
        self.clipEndMs = clipEndMs
        self.batchID = batchID
        self.result = result
        self.editedText = editedText
        self.useLLMSubtitleProcessing = useLLMSubtitleProcessing
        self.targetLanguageCode = targetLanguageCode
        self.subtitleTrack = subtitleTrack
        self.translationTracks = translationTracks
        self.selectedTranslationLanguageCode = selectedTranslationLanguageCode
        self.selectedTrack = selectedTrack
        self.summaryMarkdown = summaryMarkdown
        self.summaryTemplateID = summaryTemplateID
        self.summaryTemplateName = summaryTemplateName
        self.sessionTag = sessionTag
        self.internalSummary = internalSummary
        self.summaryState = summaryState
        self.summaryErrorMessage = summaryErrorMessage
        self.progress = progress
        self.progressMessage = progressMessage
        self.progressStage = progressStage
        self.flowProgressStage = flowProgressStage
        self.progressStep = progressStep
        self.progressCompleted = progressCompleted
        self.progressTotal = progressTotal
        self.diarizationDiagnostics = diarizationDiagnostics
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        state = try container.decodeIfPresent(WorkbenchJobState.self, forKey: .state) ?? .ready
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        speakerCount = try container.decodeIfPresent(SpeakerCountOption.self, forKey: .speakerCount) ?? .auto
        clipStartMs = try container.decodeIfPresent(Int.self, forKey: .clipStartMs)
        clipEndMs = try container.decodeIfPresent(Int.self, forKey: .clipEndMs)
        batchID = try container.decodeIfPresent(UUID.self, forKey: .batchID)
        result = try container.decodeIfPresent(TranscriptionResult.self, forKey: .result)
        editedText = try container.decodeIfPresent(String.self, forKey: .editedText) ?? ""
        useLLMSubtitleProcessing = try container.decodeIfPresent(Bool.self, forKey: .useLLMSubtitleProcessing)
        targetLanguageCode = try container.decodeIfPresent(String.self, forKey: .targetLanguageCode)
        subtitleTrack = try container.decodeIfPresent(SubtitleTrack.self, forKey: .subtitleTrack)
        translationTracks = try container.decodeIfPresent(
            [WorkbenchTranslationTrack].self,
            forKey: .translationTracks
        ) ?? []
        if translationTracks.isEmpty,
           let legacy = try container.decodeIfPresent(SubtitleTrack.self, forKey: .translationTrack) {
            let code = (legacy.language ?? targetLanguageCode ?? "und")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            translationTracks = [
                WorkbenchTranslationTrack(
                    languageCode: code.isEmpty ? "und" : code,
                    track: legacy
                ),
            ]
        }
        selectedTranslationLanguageCode = try container.decodeIfPresent(
            String.self,
            forKey: .selectedTranslationLanguageCode
        ) ?? translationTracks.first?.languageCode
        selectedTrack = try container.decodeIfPresent(WorkbenchTranscriptTrack.self, forKey: .selectedTrack)
        summaryMarkdown = try container.decodeIfPresent(String.self, forKey: .summaryMarkdown)
        summaryTemplateID = try container.decodeIfPresent(String.self, forKey: .summaryTemplateID)
        summaryTemplateName = try container.decodeIfPresent(String.self, forKey: .summaryTemplateName)
        sessionTag = try container.decodeIfPresent(String.self, forKey: .sessionTag)
        internalSummary = try container.decodeIfPresent(String.self, forKey: .internalSummary)
        summaryState = try container.decodeIfPresent(WorkbenchJobState.self, forKey: .summaryState)
        summaryErrorMessage = try container.decodeIfPresent(String.self, forKey: .summaryErrorMessage)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        progressMessage = try container.decodeIfPresent(String.self, forKey: .progressMessage)
            ?? "Ready to transcribe"
        progressStage = try container.decodeIfPresent(LocalSpeechStage.self, forKey: .progressStage)
        flowProgressStage = try container.decodeIfPresent(MediaFlowStage.self, forKey: .flowProgressStage)
        progressStep = try container.decodeIfPresent(String.self, forKey: .progressStep)
        progressCompleted = try container.decodeIfPresent(Int.self, forKey: .progressCompleted)
        progressTotal = try container.decodeIfPresent(Int.self, forKey: .progressTotal)
        diarizationDiagnostics = try container.decodeIfPresent(
            DiarizationDiagnostics.self,
            forKey: .diarizationDiagnostics
        )
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encode(speakerCount, forKey: .speakerCount)
        try container.encodeIfPresent(clipStartMs, forKey: .clipStartMs)
        try container.encodeIfPresent(clipEndMs, forKey: .clipEndMs)
        try container.encodeIfPresent(batchID, forKey: .batchID)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encode(editedText, forKey: .editedText)
        try container.encodeIfPresent(useLLMSubtitleProcessing, forKey: .useLLMSubtitleProcessing)
        try container.encodeIfPresent(targetLanguageCode, forKey: .targetLanguageCode)
        try container.encodeIfPresent(subtitleTrack, forKey: .subtitleTrack)
        try container.encode(translationTracks, forKey: .translationTracks)
        try container.encodeIfPresent(translationTrack, forKey: .translationTrack)
        try container.encodeIfPresent(selectedTranslationLanguageCode, forKey: .selectedTranslationLanguageCode)
        try container.encodeIfPresent(selectedTrack, forKey: .selectedTrack)
        try container.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
        try container.encodeIfPresent(summaryTemplateID, forKey: .summaryTemplateID)
        try container.encodeIfPresent(summaryTemplateName, forKey: .summaryTemplateName)
        try container.encodeIfPresent(sessionTag, forKey: .sessionTag)
        try container.encodeIfPresent(internalSummary, forKey: .internalSummary)
        try container.encodeIfPresent(summaryState, forKey: .summaryState)
        try container.encodeIfPresent(summaryErrorMessage, forKey: .summaryErrorMessage)
        try container.encode(progress, forKey: .progress)
        try container.encode(progressMessage, forKey: .progressMessage)
        try container.encodeIfPresent(progressStage, forKey: .progressStage)
        try container.encodeIfPresent(flowProgressStage, forKey: .flowProgressStage)
        try container.encodeIfPresent(progressStep, forKey: .progressStep)
        try container.encodeIfPresent(progressCompleted, forKey: .progressCompleted)
        try container.encodeIfPresent(progressTotal, forKey: .progressTotal)
        try container.encodeIfPresent(diarizationDiagnostics, forKey: .diarizationDiagnostics)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}

enum DubModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium

    /// UI only exposes the current 1.7B 8-bit model; `small` remains for decoding older jobs.
    static var allCases: [DubModelChoice] { [.medium] }

    var id: String { rawValue }
    var label: String { "1.7B · 8-bit" }
    var modelID: LocalModelID { .qwenTTS17B }
}

struct WorkbenchDubJob: Codable, Identifiable, Sendable {
    var id = UUID()
    /// User-authored title. Empty / placeholder means auto-generate after dub completes.
    var title = ""
    var createdAt = Date()
    var modifiedAt = Date()
    var state: WorkbenchJobState = .ready
    var script = ""
    var language = "auto"
    var model: DubModelChoice = .medium
    var referenceAudioPath: String?
    var referenceText = ""
    var referenceVoiceID: UUID?
    var speakerVoiceIDs: [String: UUID]?
    var segmentVoiceIDs: [Int: UUID]?
    var sourceTranscriptionID: UUID?
    var outputPath: String?
    var segments: [DubSegmentPayload]?
    var renderedSegments: [DubRenderedSegment]?
    var alignedTranscript: TranscriptionResult?
    var subtitleTrack: SubtitleTrack?
    var alignmentDiagnostics: KnownTextAlignmentDiagnostics?
    var revisions: [WorkbenchDubRevision]?
    var activeRevisionID: UUID?
    var summaryMarkdown: String?
    var summaryTemplateID: String?
    var summaryTemplateName: String?
    var sessionTag: String?
    var internalSummary: String?
    var summaryState: WorkbenchJobState?
    var summaryErrorMessage: String?
    var progress: Double = 0
    var progressMessage = "Ready to synthesize"
    var flowProgressStage: MediaFlowStage?
    var progressStep: String?
    var progressCompleted: Int?
    var progressTotal: Int?
    var errorMessage: String?

    var displayTitle: String {
        SessionTitlePolicy.normalizedUserTitle(title) ?? SessionTitlePolicy.untitledPlaceholder
    }

    var outputURL: URL? {
        if let activeRevisionID,
           let revision = revisions?.first(where: { $0.id == activeRevisionID }) {
            return revision.outputURL
        }
        return outputPath.map(URL.init(fileURLWithPath:))
    }

    var resolvedSpeakerVoiceIDs: [String: UUID] { speakerVoiceIDs ?? [:] }
    var resolvedSegmentVoiceIDs: [Int: UUID] { segmentVoiceIDs ?? [:] }
    var renderedSubtitleTrack: SubtitleTrack? {
        subtitleTrack ?? SubtitleTrack.fromDubSegments(renderedSegments ?? [], language: language)
    }

    var isActivelyProcessing: Bool {
        state == .running || state == .cancelling
    }
}

struct WorkbenchDubRevision: Codable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var outputPath: String
    var renderedSegments: [DubRenderedSegment]
    var referenceVoiceID: UUID?
    var speakerVoiceIDs: [String: UUID]
    var segmentVoiceIDs: [Int: UUID]
    var model: DubModelChoice
    var language: String
    var alignedTranscript: TranscriptionResult?
    var subtitleTrack: SubtitleTrack?
    var alignmentDiagnostics: KnownTextAlignmentDiagnostics?

    var outputURL: URL { URL(fileURLWithPath: outputPath) }
}

enum WorkbenchSessionSource: String, Sendable {
    case media
    case standaloneDub
}

struct WorkbenchSession: Identifiable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var state: WorkbenchJobState
    var source: WorkbenchSessionSource
    var transcriptionID: UUID?
    var dubID: UUID?
    var sourceURL: URL?
    var outputURL: URL?
    var transcript: TranscriptionResult?
    var subtitleTrack: SubtitleTrack?
    var translationTracks: [WorkbenchTranslationTrack]
    var selectedTranslationLanguageCode: String?
    var summaryMarkdown: String?
    var summaryTemplateName: String?
    var summaryState: WorkbenchJobState?
    var summaryErrorMessage: String?
    var sessionTag: String?
    var dubTranscript: TranscriptionResult?
    var dubSubtitleTrack: SubtitleTrack?
    var dubSegments: [DubRenderedSegment]

    var originalFilename: String? {
        sourceURL?.lastPathComponent
    }

    var translationTrack: SubtitleTrack? {
        if let selectedTranslationLanguageCode,
           let match = translationTracks.first(where: {
               $0.languageCode.caseInsensitiveCompare(selectedTranslationLanguageCode) == .orderedSame
           }) {
            return match.track
        }
        return translationTracks.first?.track
    }

    var duration: Double? {
        let transcriptEnd = transcript?.segments.map(\.end).max()
        let dubEnd = dubSegments.map(\.end).max()
        return [transcriptEnd, dubEnd].compactMap { $0 }.max()
    }

    var hasDub: Bool { outputURL != nil }
}

private struct WorkbenchSnapshot: Codable, Sendable {
    var schemaVersion: Int? = 5
    var transcriptions: [WorkbenchTranscriptionJob]
    var dubs: [WorkbenchDubJob]
}

enum WorkbenchMediaFlowPlanner {
    static func transcriptionSteps(
        for job: WorkbenchTranscriptionJob,
        hasAPIKey: Bool
    ) -> [MediaFlowStep] {
        var steps: [MediaFlowStep] = [
            .transcribe(TranscriptionFlowPayload(
                languageCode: job.languageCode,
                speakerCount: job.speakerCount.count,
                clipRangeSeconds: job.clipRangeSeconds
            )),
        ]
        let targetLanguage = job.normalizedTargetLanguageCode
        if job.shouldProcessSubtitles(hasAPIKey: hasAPIKey) || targetLanguage != nil {
            steps.append(.prepareSubtitles(SubtitleProcessingPayload(
                invalidOutputFallback: targetLanguage == nil
                    ? .preserveTimedTranscript
                    : .failFlow
            )))
        }
        if let targetLanguage {
            steps.append(.translate(TranslationFlowPayload(targetLanguage: targetLanguage)))
        }
        return steps
    }

    static func translationSteps(for job: WorkbenchTranscriptionJob) -> [MediaFlowStep] {
        guard let targetLanguage = job.normalizedTargetLanguageCode else { return [] }
        var steps: [MediaFlowStep] = []
        let needsPreparation = job.subtitleTrack?.needsWordTimestampPreparation(
            for: job.result ?? TranscriptionResult(text: "", language: job.languageCode, words: [], segments: [])
        ) ?? true
        if needsPreparation {
            steps.append(.prepareSubtitles(SubtitleProcessingPayload(
                invalidOutputFallback: .failFlow
            )))
        }
        steps.append(.translate(TranslationFlowPayload(targetLanguage: targetLanguage)))
        return steps
    }

    static func dubSteps(payload: DubFlowPayload, hasAPIKey: Bool) -> [MediaFlowStep] {
        var steps: [MediaFlowStep] = [
            .dub(payload),
            .alignScript(ScriptAlignmentPayload(
                text: nil,
                languageCode: payload.language,
                speakerMode: .providedSegments
            )),
        ]
        if hasAPIKey {
            steps.append(.prepareSubtitles(SubtitleProcessingPayload(
                invalidOutputFallback: .preserveTimedTranscript
            )))
        }
        return steps
    }
}

private actor WorkbenchPersistence {
    private let URL: URL
    private var latestRevision = 0

    init(URL: URL) {
        self.URL = URL
    }

    func load() -> WorkbenchSnapshot? {
        guard let data = try? Data(contentsOf: URL) else { return nil }
        return try? JSONDecoder().decode(WorkbenchSnapshot.self, from: data)
    }

    func save(_ snapshot: WorkbenchSnapshot, revision: Int) {
        guard revision >= latestRevision,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: URL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL, options: .atomic)
            latestRevision = revision
        } catch {
            Log.project.error("workbench save failed: \(error.localizedDescription)")
        }
    }
}

@Observable
@MainActor
final class WorkbenchStore {
    static let shared = WorkbenchStore()

    private static let routeDefaultsKey = "voxella.workbench.route"

    var route: WorkbenchRoute {
        didSet {
            UserDefaults.standard.set(route.rawValue, forKey: Self.routeDefaultsKey)
        }
    }
    var transcriptions: [WorkbenchTranscriptionJob] = []
    var dubs: [WorkbenchDubJob] = []
    var selectedTranscriptionID: UUID?
    var selectedDubID: UUID?
    var selectedSessionID: UUID?
    /// Active multi-file / upload-style batch. While set, the Transcribe route shows the waiting UI.
    var activeTranscriptionBatch: TranscriptionBatchState?
    var transcriptionAdmissionError: String?
    private var flowTasks: [UUID: Task<Void, Never>] = [:]
    private var summaryTaskIDs: Set<UUID> = []
    /// FIFO of transcription job IDs waiting for the single local ASR slot.
    private var pendingTranscriptionQueue: [UUID] = []
    private var activeQueuedTranscriptionID: UUID?
    private let persistence: WorkbenchPersistence
    private var hasHydrated = false
    private var pendingNewDubDraft = false
    private var saveRequestedBeforeHydration = false
    private var saveRevision = 0

    private init() {
        let storedRoute = UserDefaults.standard.string(forKey: Self.routeDefaultsKey)
            .flatMap(WorkbenchRoute.init(rawValue:))
        // Session detail requires an in-memory selection. Restore Recent when none exists.
        route = (storedRoute == .session ? .recent : storedRoute) ?? .recent
        persistence = WorkbenchPersistence(URL: Self.snapshotURL)
        Task { await hydrate() }
    }

    var selectedTranscriptionIndex: Int? {
        selectedTranscriptionID.flatMap { id in transcriptions.firstIndex { $0.id == id } }
    }

    var selectedDubIndex: Int? {
        selectedDubID.flatMap { id in dubs.firstIndex { $0.id == id } }
    }

    var sessions: [WorkbenchSession] {
        let linkedDubs = Dictionary(
            dubs.compactMap { job in job.sourceTranscriptionID.map { ($0, job) } },
            uniquingKeysWith: { current, candidate in
                current.modifiedAt >= candidate.modifiedAt ? current : candidate
            }
        )
        let transcriptSessions = transcriptions.map { job in
            let dub = linkedDubs[job.id]
            return WorkbenchSession(
                id: job.id,
                title: job.sessionTitle,
                createdAt: job.createdAt,
                modifiedAt: max(job.modifiedAt, dub?.modifiedAt ?? job.modifiedAt),
                state: Self.combinedState(primary: job.state, secondary: dub?.state),
                source: .media,
                transcriptionID: job.id,
                dubID: dub?.id,
                sourceURL: job.sourceURL,
                outputURL: dub?.outputURL,
                transcript: job.result,
                subtitleTrack: job.subtitleTrack,
                translationTracks: job.translationTracks,
                selectedTranslationLanguageCode: job.selectedTranslationLanguageCode,
                summaryMarkdown: job.summaryMarkdown,
                summaryTemplateName: job.summaryTemplateName,
                summaryState: job.summaryState,
                summaryErrorMessage: job.summaryErrorMessage,
                sessionTag: job.sessionTag,
                dubTranscript: dub?.alignedTranscript,
                dubSubtitleTrack: dub?.renderedSubtitleTrack,
                dubSegments: dub?.renderedSegments ?? []
            )
        }
        let standaloneDubs = dubs.filter { job in
            guard let sourceID = job.sourceTranscriptionID else { return true }
            return !transcriptions.contains { $0.id == sourceID }
        }.map { job in
            WorkbenchSession(
                id: job.id,
                title: job.displayTitle,
                createdAt: job.createdAt,
                modifiedAt: job.modifiedAt,
                state: job.state,
                source: .standaloneDub,
                transcriptionID: nil,
                dubID: job.id,
                sourceURL: nil,
                outputURL: job.outputURL,
                transcript: nil,
                subtitleTrack: nil,
                translationTracks: [],
                selectedTranslationLanguageCode: nil,
                summaryMarkdown: job.summaryMarkdown,
                summaryTemplateName: job.summaryTemplateName,
                summaryState: job.summaryState,
                summaryErrorMessage: job.summaryErrorMessage,
                sessionTag: job.sessionTag,
                dubTranscript: job.alignedTranscript,
                dubSubtitleTrack: job.renderedSubtitleTrack,
                dubSegments: job.renderedSegments ?? Self.fallbackDubSegments(for: job)
            )
        }
        return (transcriptSessions + standaloneDubs).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var selectedSession: WorkbenchSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func openSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectedSessionID = id

        if let transcriptionID = session.transcriptionID,
           shouldPresentTranscriptionProcessing(for: transcriptionID) {
            selectedTranscriptionID = transcriptionID
            selectedDubID = nil
            route = .transcribe
            return
        }

        if let dubID = session.dubID,
           dubs.first(where: { $0.id == dubID })?.isActivelyProcessing == true {
            selectedDubID = dubID
            selectedTranscriptionID = nil
            route = .dub
            return
        }

        route = .session
        let missingLLMMessage = LLMConfigurationError.noConfiguredModel(.subtitleProcessing)
            .localizedDescription
        if let job = transcriptions.first(where: { $0.id == id }),
           job.summaryState == .failed,
           job.summaryErrorMessage == missingLLMMessage {
            updateTranscription(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
        }
        if let job = dubs.first(where: { $0.id == id }),
           job.summaryState == .failed,
           job.summaryErrorMessage == missingLLMMessage {
            updateDub(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
        }
        Task { await ensureSessionSummary(for: id) }
    }

    private func needsSummary(
        markdown: String?,
        state: WorkbenchJobState?
    ) -> Bool {
        guard state != .running, state != .completed else { return false }
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
    }

    /// Fills a missing session summary after open / dub completion.
    private func ensureSessionSummary(for sessionID: UUID) async {
        if let transcription = transcriptions.first(where: { $0.id == sessionID }),
           transcription.state == .completed,
           needsSummary(markdown: transcription.summaryMarkdown, state: transcription.summaryState) {
            await enrichCompletedTranscription(sessionID)
        }
        let dub = dubs.first(where: { $0.id == sessionID })
            ?? dubs.first(where: { $0.sourceTranscriptionID == sessionID })
        if let dub,
           dub.state == .completed,
           needsSummary(markdown: dub.summaryMarkdown, state: dub.summaryState) {
            await enrichCompletedDub(dub.id)
        }
    }

    func showRecentSessions() {
        selectedSessionID = nil
        route = .recent
    }

    func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[index].customTitle = trimmed == transcriptions[index].displayName
                ? nil
                : trimmed
            transcriptions[index].modifiedAt = Date()
            save()
            return
        }
        if let index = dubs.firstIndex(where: { $0.id == id }) {
            dubs[index].title = SessionTitlePolicy.normalizedUserTitle(trimmed) ?? ""
            dubs[index].modifiedAt = Date()
            save()
        }
    }

    @discardableResult
    func createDub(for sessionID: UUID, track: WorkbenchTranscriptTrack = .source) -> UUID? {
        guard transcriptions.contains(where: { $0.id == sessionID }) else { return nil }
        if let existing = dubs.first(where: { $0.sourceTranscriptionID == sessionID }) {
            selectedDubID = existing.id
            route = .dub
            return existing.id
        }
        let id = addDub()
        updateDub(id) { $0.sourceTranscriptionID = sessionID }
        useTranscript(sessionID, forDub: id, track: track)
        return id
    }

    /// Media URLs waiting for the Processing options sheet (web upload flow).
    var pendingMediaImportURLs: [URL] = []

    func stageMediaImport(_ urls: [URL]) {
        transcriptionAdmissionError = nil
        do {
            try LocalTranscriptionResourcePolicy.admit(urls)
        } catch {
            transcriptionAdmissionError = error.localizedDescription
            pendingMediaImportURLs = []
            return
        }
        pendingMediaImportURLs = urls
        selectedTranscriptionID = nil
        route = .transcribe
    }

    func clearPendingMediaImport() {
        pendingMediaImportURLs = []
    }

    @discardableResult
    func addTranscription(sourceURL: URL) -> UUID {
        stageMediaImport([sourceURL])
        return UUID()
    }

    /// Creates jobs from local media, applies web-aligned options, and processes them serially.
    @discardableResult
    func beginTranscriptions(
        sourceURLs: [URL],
        options: LocalProcessingOptions,
        openSessionWhenDone: Bool = true
    ) -> UUID? {
        transcriptionAdmissionError = nil
        do {
            try LocalTranscriptionResourcePolicy.admit(sourceURLs)
        } catch {
            transcriptionAdmissionError = error.localizedDescription
            return nil
        }

        let batchID = UUID()
        var created: [WorkbenchTranscriptionJob] = []
        created.reserveCapacity(sourceURLs.count)
        for url in sourceURLs {
            var job = WorkbenchTranscriptionJob(sourcePath: url.path)
            job.languageCode = options.languageCode
            job.speakerCount = options.speakerCount
            job.clipStartMs = sourceURLs.count == 1 ? options.clipStartMs : nil
            job.clipEndMs = sourceURLs.count == 1 ? options.clipEndMs : nil
            job.useLLMSubtitleProcessing = options.useLLMSubtitleProcessing
            job.targetLanguageCode = options.normalizedTargetLanguageCode
            if sourceURLs.count == 1 {
                job.customTitle = SessionTitlePolicy.normalizedUserTitle(options.customTitle)
            }
            job.batchID = batchID
            job.progressMessage = "Queued for local processing"
            job.state = .ready
            created.append(job)
        }
        let jobIDs = created.map(\.id)
        transcriptions.insert(contentsOf: created.reversed(), at: 0)

        activeTranscriptionBatch = TranscriptionBatchState(id: batchID, jobIDs: jobIDs)
        selectedTranscriptionID = jobIDs.first
        if openSessionWhenDone {
            route = .transcribe
        }
        save()

        for id in jobIDs {
            enqueueTranscription(id, openSessionWhenBatchCompletes: openSessionWhenDone)
        }
        return batchID
    }

    func clearTranscriptionAdmissionError() {
        transcriptionAdmissionError = nil
    }

    func isTranscriptionQueued(_ id: UUID) -> Bool {
        pendingTranscriptionQueue.contains(id) || activeQueuedTranscriptionID == id
    }

    func shouldPresentTranscriptionProcessing(for id: UUID) -> Bool {
        guard let job = transcriptions.first(where: { $0.id == id }) else { return false }
        if job.isActivelyProcessing { return true }
        if isTranscriptionQueued(id) { return true }
        if let batch = activeTranscriptionBatch, batch.jobIDs.contains(id) {
            return job.state != .completed
        }
        return false
    }

    private var openSessionWhenBatchCompletes = true

    private func enqueueTranscription(_ id: UUID, openSessionWhenBatchCompletes: Bool) {
        self.openSessionWhenBatchCompletes = openSessionWhenBatchCompletes
        guard !pendingTranscriptionQueue.contains(id),
              activeQueuedTranscriptionID != id,
              flowTasks[id] == nil else { return }
        pendingTranscriptionQueue.append(id)
        updateTranscription(id) {
            if $0.state == .ready {
                $0.progressMessage = "Queued — waiting for the local ASR slot"
            }
        }
        drainTranscriptionQueue()
    }

    private func drainTranscriptionQueue() {
        guard activeQueuedTranscriptionID == nil else { return }

        while let next = pendingTranscriptionQueue.first {
            pendingTranscriptionQueue.removeFirst()
            guard transcriptions.contains(where: { $0.id == next }) else { continue }
            guard flowTasks[next] == nil else { continue }
            let job = transcriptions.first { $0.id == next }
            if job?.state == .cancelled || job?.state == .completed { continue }

            activeQueuedTranscriptionID = next
            selectedTranscriptionID = next
            Task { @MainActor [weak self] in
                guard let self else { return }
                if LocalTranscriptionResourcePolicy.shouldDelayBeforeNextJob
                    || self.activeTranscriptionBatch?.jobIDs.count ?? 0 > 1 {
                    try? await Task.sleep(for: LocalTranscriptionResourcePolicy.interJobDelay)
                }
                guard self.activeQueuedTranscriptionID == next else { return }
                if ProcessInfo.processInfo.thermalState == .critical {
                    self.updateTranscription(next) {
                        $0.state = .failed
                        $0.errorMessage = LocalTranscriptionResourcePolicy.AdmissionError.thermalPressure.localizedDescription
                        $0.progressMessage = "Paused for thermal safety"
                    }
                    self.finishTranscriptionSlot(next)
                    return
                }
                self.startTranscriptionPipeline(next)
            }
            return
        }
    }

    private func finishTranscriptionSlot(_ id: UUID) {
        if activeQueuedTranscriptionID == id {
            activeQueuedTranscriptionID = nil
        }
        reconcileTranscriptionBatch(finishedID: id)
        drainTranscriptionQueue()
    }

    private func reconcileTranscriptionBatch(finishedID: UUID) {
        guard let batch = activeTranscriptionBatch else {
            if openSessionWhenBatchCompletes,
               let job = transcriptions.first(where: { $0.id == finishedID }),
               job.state == .completed {
                openSession(finishedID)
            }
            return
        }
        let jobs = batch.jobIDs.compactMap { id in transcriptions.first { $0.id == id } }
        let pending = jobs.contains {
            $0.isActivelyProcessing
                || pendingTranscriptionQueue.contains($0.id)
                || activeQueuedTranscriptionID == $0.id
        }
        guard !pending else {
            if let nextRunning = jobs.first(where: {
                $0.isActivelyProcessing || isTranscriptionQueued($0.id)
            }) {
                selectedTranscriptionID = nextRunning.id
            }
            return
        }

        activeTranscriptionBatch = nil
        let firstCompleted = jobs.first(where: { $0.state == .completed })?.id
        if openSessionWhenBatchCompletes, let firstCompleted {
            openSession(firstCompleted)
        } else if let failed = jobs.first(where: { $0.state == .failed }) {
            selectedTranscriptionID = failed.id
            if openSessionWhenBatchCompletes {
                route = .transcribe
            }
        } else {
            selectedTranscriptionID = nil
        }
    }

    @discardableResult
    func addDub(
        script: String = "",
        title: String = "",
        openRoute: Bool = true
    ) -> UUID {
        var job = Self.newDubJob(
            from: dubs,
            preferredLanguage: Self.preferredDubLanguage
        )
        job.title = SessionTitlePolicy.normalizedUserTitle(title) ?? ""
        job.script = script
        job.segments = [DubSegmentPayload(index: 0, text: script)]
        dubs.insert(job, at: 0)
        selectedDubID = job.id
        if openRoute {
            route = .dub
        }
        save()
        return job.id
    }

    /// Starts a blank Dub workspace while preserving the most recently used settings.
    func startNewDubDraft() {
        guard hasHydrated else {
            pendingNewDubDraft = true
            selectedDubID = nil
            selectedSessionID = nil
            route = .dub
            return
        }
        let job = Self.newDubJob(
            from: dubs,
            preferredLanguage: Self.preferredDubLanguage
        )
        if let selectedDubID,
           let selectedIndex = dubs.firstIndex(where: { $0.id == selectedDubID }),
           Self.isEmptyDubDraft(dubs[selectedIndex]) {
            dubs.remove(at: selectedIndex)
        }
        dubs.insert(job, at: 0)
        selectedDubID = job.id
        selectedSessionID = nil
        route = .dub
        save()
    }

    /// Ensures direct routes and deep links have a blank Dub draft when no draft is selected.
    func ensureActiveDubDraft() {
        if selectedDubIndex == nil {
            startNewDubDraft()
            return
        }
        guard let id = selectedDubID else { return }
        normalizeDubSegments(id)
    }

    func openDub(_ id: UUID) {
        guard dubs.contains(where: { $0.id == id }) else { return }
        selectedDubID = id
        selectedSessionID = nil
        route = .dub
        normalizeDubSegments(id)
    }

    var recentDubSessions: [WorkbenchSession] {
        sessions.filter { session in
            guard let dubID = session.dubID,
                  let job = dubs.first(where: { $0.id == dubID }) else {
                return false
            }
            return !Self.isEmptyDubDraft(job)
        }
    }

    nonisolated static func newDubJob(
        from jobs: [WorkbenchDubJob],
        preferredLanguage: String
    ) -> WorkbenchDubJob {
        let latest = jobs.max { lhs, rhs in
            lhs.modifiedAt < rhs.modifiedAt
        }
        var job = WorkbenchDubJob()
        job.language = latest?.language == "auto"
            ? preferredLanguage
            : latest?.language ?? preferredLanguage
        job.model = latest?.model ?? job.model
        job.referenceAudioPath = latest?.referenceAudioPath
        job.referenceText = latest?.referenceText ?? ""
        job.referenceVoiceID = latest?.referenceVoiceID
        if let latest {
            let firstSegmentIndex = latest.segments?.map(\.index).min() ?? 0
            if let voiceID = latest.resolvedSegmentVoiceIDs[firstSegmentIndex] {
                job.segmentVoiceIDs = [0: voiceID]
            }
        }
        job.segments = [DubSegmentPayload(index: 0, text: "")]
        return job
    }

    private static var preferredDubLanguage: String {
        Locale.current.language.languageCode?.identifier == "zh" ? "zh" : "en"
    }

    private nonisolated static func isEmptyDubDraft(_ job: WorkbenchDubJob) -> Bool {
        job.state == .ready
            && job.sourceTranscriptionID == nil
            && job.outputPath == nil
            && job.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (job.segments ?? []).allSatisfy {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    func normalizeDubSegments(_ id: UUID) {
        updateDub(id) { job in
            if let segments = job.segments, !segments.isEmpty { return }
            let text = job.script
            job.segments = [DubSegmentPayload(index: 0, text: text)]
        }
    }

    func addDubSegment(_ id: UUID) {
        updateDub(id) { job in
            var segments = job.segments ?? []
            let nextIndex = (segments.map(\.index).max() ?? -1) + 1
            segments.append(DubSegmentPayload(index: nextIndex, text: ""))
            job.segments = segments
            job.script = segments.map(\.text).joined(separator: "\n")
        }
    }

    func deleteDubSegment(_ id: UUID, segmentIndex: Int) {
        updateDub(id) { job in
            guard let segments = job.segments, segments.count > 1 else { return }
            let oldVoices = job.resolvedSegmentVoiceIDs
            let kept = segments.filter { $0.index != segmentIndex }
            let remappedVoices: [Int: UUID] = Dictionary(
                uniqueKeysWithValues: kept.enumerated().compactMap { offset, segment in
                    oldVoices[segment.index].map { (offset, $0) }
                }
            )
            job.segments = kept.enumerated().map { offset, segment in
                var next = segment
                next.index = offset
                return next
            }
            job.segmentVoiceIDs = remappedVoices.isEmpty ? nil : remappedVoices
            job.script = job.segments?.map(\.text).joined(separator: "\n") ?? ""
        }
    }

    func updateDubSegmentText(_ id: UUID, segmentIndex: Int, text: String) {
        updateDub(id) { job in
            guard let idx = job.segments?.firstIndex(where: { $0.index == segmentIndex }) else { return }
            job.segments?[idx].text = text
            job.script = job.segments?.map(\.text).joined(separator: "\n") ?? text
        }
    }

    func deleteTranscription(_ id: UUID) {
        pendingTranscriptionQueue.removeAll { $0 == id }
        if activeQueuedTranscriptionID == id { activeQueuedTranscriptionID = nil }
        flowTasks[id]?.cancel()
        flowTasks[id] = nil
        if let job = transcriptions.first(where: { $0.id == id }) {
            removeManagedClipMediaIfNeeded(job.sourceURL)
        }
        transcriptions.removeAll { $0.id == id }
        if selectedTranscriptionID == id { selectedTranscriptionID = transcriptions.first?.id }
        if var batch = activeTranscriptionBatch {
            batch.jobIDs.removeAll { $0 == id }
            activeTranscriptionBatch = batch.jobIDs.isEmpty ? nil : batch
        }
        save()
        drainTranscriptionQueue()
    }

    func deleteDub(_ id: UUID) {
        flowTasks[id]?.cancel()
        flowTasks[id] = nil
        dubs.removeAll { $0.id == id }
        if selectedDubID == id { selectedDubID = dubs.first?.id }
        save()
    }

    func deleteSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let relatedDubIDs: [UUID]
        if let transcriptionID = session.transcriptionID {
            relatedDubIDs = dubs.filter { dub in
                dub.id == session.dubID || dub.sourceTranscriptionID == transcriptionID
            }.map(\.id)
        } else if let dubID = session.dubID {
            relatedDubIDs = [dubID]
        } else {
            relatedDubIDs = []
        }

        if selectedSessionID == id {
            selectedSessionID = nil
            if route == .session { route = .recent }
        }

        if let transcriptionID = session.transcriptionID {
            deleteTranscription(transcriptionID)
        }
        for dubID in relatedDubIDs {
            deleteDub(dubID)
        }
    }

    func updateTranscription(_ id: UUID, _ mutate: (inout WorkbenchTranscriptionJob) -> Void) {
        guard let index = transcriptions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transcriptions[index])
        transcriptions[index].modifiedAt = Date()
        save()
    }

    func assignSpeaker(
        _ speaker: String,
        from start: Double,
        to end: Double,
        inTranscription id: UUID
    ) {
        updateTranscription(id) { job in
            job.result = job.result?.assigningSpeaker(speaker, from: start, to: end)
            job.subtitleTrack = job.subtitleTrack?.assigningSpeaker(speaker, from: start, to: end)
            for index in job.translationTracks.indices {
                job.translationTracks[index].track = job.translationTracks[index].track
                    .assigningSpeaker(speaker, from: start, to: end)
            }
        }
    }

    func renameSpeaker(_ current: String, to replacement: String, inTranscription id: UUID) {
        updateTranscription(id) { job in
            job.result = job.result?.renamingSpeaker(current, to: replacement)
            job.subtitleTrack = job.subtitleTrack?.renamingSpeaker(current, to: replacement)
            for index in job.translationTracks.indices {
                job.translationTracks[index].track = job.translationTracks[index].track
                    .renamingSpeaker(current, to: replacement)
            }
        }
    }

    enum SessionCueScope: Equatable, Sendable {
        case transcript
        case source
        case translation(String)
        case dub
    }

    func updateSessionCueText(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        text: String
    ) {
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            track.updatingCueText(id: cueID, text: text)
        }
    }

    func mergeSessionCueDown(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int
    ) {
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            track.mergingDown(fromCueID: cueID)
        }
    }

    @discardableResult
    func splitSessionCue(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        leftText: String,
        rightText: String
    ) -> Bool {
        var didSplit = false
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            guard let updated = track.splittingCue(
                id: cueID,
                leftText: leftText,
                rightText: rightText
            ) else {
                return nil
            }
            didSplit = true
            return updated
        }
        return didSplit
    }

    func assignSessionCueSpeaker(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        speaker: String
    ) {
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            track.assigningSpeaker(toCue: cueID, speaker: speaker)
        }
    }

    func renameSessionSpeaker(
        sessionID: UUID,
        scope: SessionCueScope,
        current: String,
        to replacement: String
    ) {
        let source = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return }

        switch scope {
        case .transcript, .source, .translation:
            guard let transcriptionID = sessions.first(where: { $0.id == sessionID })?.transcriptionID
                    ?? (transcriptions.contains(where: { $0.id == sessionID }) ? sessionID : nil)
            else { return }
            renameSpeaker(source, to: destination, inTranscription: transcriptionID)
        case .dub:
            guard let dubID = resolveDubID(forSession: sessionID) else { return }
            updateDub(dubID) { job in
                job.subtitleTrack = job.subtitleTrack?.renamingSpeaker(source, to: destination)
                job.alignedTranscript = job.alignedTranscript?.renamingSpeaker(source, to: destination)
                if var segments = job.renderedSegments {
                    for index in segments.indices
                    where segments[index].speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == source {
                        segments[index].speaker = destination
                    }
                    job.renderedSegments = segments
                }
            }
        }
    }

    func addSessionCueSpeaker(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        speaker: String
    ) {
        assignSessionCueSpeaker(sessionID: sessionID, scope: scope, cueID: cueID, speaker: speaker)
    }

    private func mutateSessionCueTrack(
        sessionID: UUID,
        scope: SessionCueScope,
        _ transform: (SubtitleTrack) -> SubtitleTrack?
    ) {
        switch scope {
        case .transcript:
            guard let transcriptionID = resolveTranscriptionID(forSession: sessionID) else { return }
            updateTranscription(transcriptionID) { job in
                let base = job.result.map(SubtitleTrack.fromTranscript)
                guard let base, let updated = transform(base) else { return }
                let next = updated.asTranscriptionResult(preservingWords: job.result?.words ?? [])
                job.result = next
                job.editedText = next.text
            }
        case .source:
            guard let transcriptionID = resolveTranscriptionID(forSession: sessionID) else { return }
            updateTranscription(transcriptionID) { job in
                let base = job.subtitleTrack
                    ?? job.result.map(SubtitleTrack.fromTranscript)
                guard let base, let updated = transform(base) else { return }
                job.subtitleTrack = updated
                job.editedText = updated.text
            }
        case .translation(let languageCode):
            guard let transcriptionID = resolveTranscriptionID(forSession: sessionID) else { return }
            updateTranscription(transcriptionID) { job in
                guard let index = job.translationTracks.firstIndex(where: {
                    $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
                }) else { return }
                guard let updated = transform(job.translationTracks[index].track) else { return }
                job.translationTracks[index].track = updated
                job.translationTracks[index].createdAt = Date()
            }
        case .dub:
            guard let dubID = resolveDubID(forSession: sessionID) else { return }
            updateDub(dubID) { job in
                let base = job.subtitleTrack
                    ?? SubtitleTrack.fromDubSegments(
                        job.renderedSegments ?? Self.fallbackDubSegments(for: job),
                        language: job.alignedTranscript?.language
                    )
                guard let base, let updated = transform(base) else { return }
                let segments = updated.cues.enumerated().map { index, cue in
                    DubRenderedSegment(
                        index: index,
                        text: cue.text,
                        start: cue.start,
                        end: cue.end,
                        speaker: cue.speaker,
                        sourceSubtitleID: cue.sourceIDs.first
                    )
                }
                let transcript = updated.asTranscriptionResult(
                    preservingWords: job.alignedTranscript?.words ?? []
                ).aggregatingSegments()
                job.subtitleTrack = updated
                job.alignedTranscript = transcript
                job.renderedSegments = segments
                if let activeID = job.activeRevisionID,
                   let revisionIndex = job.revisions?.firstIndex(where: { $0.id == activeID }) {
                    job.revisions?[revisionIndex].subtitleTrack = updated
                    job.revisions?[revisionIndex].renderedSegments = segments
                    job.revisions?[revisionIndex].alignedTranscript = transcript
                }
            }
        }
    }

    private func resolveTranscriptionID(forSession sessionID: UUID) -> UUID? {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            return session.transcriptionID
        }
        return transcriptions.contains(where: { $0.id == sessionID }) ? sessionID : nil
    }

    private func resolveDubID(forSession sessionID: UUID) -> UUID? {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            return session.dubID
        }
        return dubs.contains(where: { $0.id == sessionID }) ? sessionID : nil
    }

    func updateDub(_ id: UUID, _ mutate: (inout WorkbenchDubJob) -> Void) {
        guard let index = dubs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&dubs[index])
        dubs[index].modifiedAt = Date()
        save()
    }

    func runTranscription(_ id: UUID) {
        enqueueTranscription(id, openSessionWhenBatchCompletes: true)
    }

    private func startTranscriptionPipeline(_ id: UUID) {
        guard flowTasks[id] == nil,
              let index = transcriptions.firstIndex(where: { $0.id == id }) else {
            finishTranscriptionSlot(id)
            return
        }
        transcriptions[index].state = .running
        transcriptions[index].progress = 0.02
        transcriptions[index].progressMessage = "Preparing audio…"
        transcriptions[index].progressStage = nil
        transcriptions[index].flowProgressStage = .transcription
        transcriptions[index].progressStep = "flow_started"
        transcriptions[index].progressCompleted = nil
        transcriptions[index].progressTotal = nil
        transcriptions[index].subtitleTrack = nil
        transcriptions[index].translationTracks = []
        transcriptions[index].selectedTranslationLanguageCode = nil
        transcriptions[index].selectedTrack = .source
        transcriptions[index].summaryMarkdown = nil
        transcriptions[index].summaryTemplateID = nil
        transcriptions[index].summaryTemplateName = nil
        transcriptions[index].sessionTag = nil
        transcriptions[index].internalSummary = nil
        transcriptions[index].summaryState = nil
        transcriptions[index].summaryErrorMessage = nil
        transcriptions[index].errorMessage = nil
        save()

        let task = Task { [weak self] in
            guard let self else { return }
            var releasedSlot = false
            defer {
                flowTasks[id] = nil
                if !releasedSlot {
                    finishTranscriptionSlot(id)
                }
            }
            _ = await LLMSettingsStore.shared.credentialAvailable()
            let hasSubtitleModel = LLMSettingsStore.shared.hasConfiguredModel(
                for: .subtitleProcessing
            )
            if Task.isCancelled {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                return
            }
            do {
                try await materializeClipMediaIfNeeded(for: id)
            } catch is CancellationError {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                return
            } catch {
                updateTranscription(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.progressMessage = "Clip extraction failed"
                    $0.flowProgressStage = nil
                    $0.progressStep = nil
                }
                return
            }
            guard let job = transcriptions.first(where: { $0.id == id }) else { return }
            let request = MediaFlowRequest(
                id: id,
                input: .media(job.sourceURL),
                steps: WorkbenchMediaFlowPlanner.transcriptionSteps(
                    for: job,
                    hasAPIKey: hasSubtitleModel
                )
            )
            for await event in MediaFlowExecutor.shared.events(for: request) {
                if Task.isCancelled {
                    break
                }
                await consumeTranscriptionEvent(
                    event,
                    jobID: id,
                    sourceURL: job.sourceURL,
                    languageCode: job.languageCode,
                    speakerCount: job.speakerCount.count
                )
            }
            if Task.isCancelled {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                return
            }
            guard let completed = transcriptions.first(where: { $0.id == id }),
                  completed.state == .completed else { return }

            // Free the local ASR slot before title/summary LLM enrichment.
            flowTasks[id] = nil
            finishTranscriptionSlot(id)
            releasedSlot = true
            await enrichCompletedTranscription(id)
        }
        flowTasks[id] = task
    }

    /// Writes the selected clip window to managed storage and retargets the job source.
    private func materializeClipMediaIfNeeded(for id: UUID) async throws {
        guard let index = transcriptions.firstIndex(where: { $0.id == id }),
              let range = transcriptions[index].clipRangeSeconds else { return }

        let sourceURL = transcriptions[index].sourceURL
        updateTranscription(id) {
            $0.progress = 0.04
            $0.progressMessage = "Extracting clip…"
            $0.flowProgressStage = .transcription
            $0.progressStep = "extract_clip"
        }

        let isVideo = ClipType(fileExtension: sourceURL.pathExtension.lowercased()) == .video
        let destinationURL = Self.clipsDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(isVideo ? "mp4" : "m4a")

        try await Task.detached(priority: .userInitiated) {
            try await MediaRangeExtractor.extract(
                sourceURL: sourceURL,
                range: range,
                destinationURL: destinationURL
            )
        }.value
        try Task.checkCancellation()

        updateTranscription(id) {
            $0.sourcePath = destinationURL.path
            // Source is already clipped; ASR must not re-window or offset timestamps.
            $0.clipStartMs = nil
            $0.clipEndMs = nil
            $0.progressMessage = "Preparing audio…"
            $0.progressStep = "flow_started"
        }
    }

    func cancelTranscription(_ id: UUID) {
        pendingTranscriptionQueue.removeAll { $0 == id }
        if let batch = activeTranscriptionBatch, batch.jobIDs.contains(id) {
            for queued in batch.jobIDs where queued != id && pendingTranscriptionQueue.contains(queued) {
                pendingTranscriptionQueue.removeAll { $0 == queued }
                updateTranscription(queued) {
                    $0.state = .cancelled
                    $0.progressMessage = "Cancelled — ready to retry"
                    $0.errorMessage = nil
                }
            }
        }
        guard flowTasks[id] != nil else {
            updateTranscription(id) {
                if $0.state == .ready {
                    $0.state = .cancelled
                    $0.progressMessage = "Cancelled — ready to retry"
                }
            }
            finishTranscriptionSlot(id)
            return
        }
        flowTasks[id]?.cancel()
        updateTranscription(id) {
            $0.state = .cancelling
            $0.errorMessage = nil
            $0.progressMessage = "Cancelling media flow…"
        }
    }

    func cancelActiveTranscriptionBatch() {
        guard let batch = activeTranscriptionBatch else {
            if let id = selectedTranscriptionID {
                cancelTranscription(id)
            }
            return
        }
        for id in batch.jobIDs {
            cancelTranscription(id)
        }
    }

    func dismissTranscriptionProcessing() {
        activeTranscriptionBatch = nil
        selectedTranscriptionID = nil
    }

    func runTranslation(_ id: UUID) {
        guard flowTasks[id] == nil,
              let index = transcriptions.firstIndex(where: { $0.id == id }),
              let transcript = transcriptions[index].result,
              transcriptions[index].normalizedTargetLanguageCode != nil else { return }
        let snapshot = transcriptions[index]
        transcriptions[index].state = .running
        transcriptions[index].progress = 0.01
        transcriptions[index].progressMessage = "Preparing translation…"
        transcriptions[index].flowProgressStage = .translation
        transcriptions[index].progressStep = "flow_started"
        transcriptions[index].errorMessage = nil
        save()

        let request = MediaFlowRequest(
            id: id,
            input: .transcript(
                transcript: transcript,
                subtitles: snapshot.subtitleTrack,
                translation: snapshot.translationTrack
            ),
            steps: WorkbenchMediaFlowPlanner.translationSteps(for: snapshot)
        )
        let task = Task { [weak self] in
            guard let self else { return }
            defer { flowTasks[id] = nil }
            for await event in MediaFlowExecutor.shared.events(for: request) {
                if Task.isCancelled { break }
                await consumeTranscriptionEvent(
                    event,
                    jobID: id,
                    sourceURL: snapshot.sourceURL,
                    languageCode: snapshot.languageCode,
                    speakerCount: snapshot.speakerCount.count
                )
            }
            if Task.isCancelled {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
            }
        }
        flowTasks[id] = task
    }

    func runDub(_ id: UUID) {
        guard flowTasks[id] == nil,
              let index = dubs.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = dubs[index]
        let voiceLibrary = VoiceLibraryStore.shared
        voiceLibrary.stopPlayback()
        let defaultVoiceID = snapshot.referenceVoiceID
            ?? voiceLibrary.defaultReference(languageCode: snapshot.language)?.id
        let missingVoiceIDs = Set(
            [snapshot.referenceVoiceID].compactMap { $0 }
                + Array(snapshot.resolvedSpeakerVoiceIDs.values)
                + Array(snapshot.resolvedSegmentVoiceIDs.values)
        ).filter { voiceLibrary.reference(id: $0) == nil }
        guard missingVoiceIDs.isEmpty else {
            updateDub(id) {
                $0.state = .failed
                $0.errorMessage = "A selected reference voice is no longer available. Choose a replacement before generating."
                $0.progressMessage = "Reference voice unavailable"
            }
            return
        }
        let reference = voiceLibrary.dubReference(for: defaultVoiceID)
            ?? snapshot.referenceAudioPath.map {
                DubVoiceReference(
                    audioURL: URL(fileURLWithPath: $0),
                    transcript: snapshot.referenceText
                )
            }
        let speakerReferences = snapshot.resolvedSpeakerVoiceIDs.compactMapValues {
            voiceLibrary.dubReference(for: $0)
        }
        let segmentReferences = snapshot.resolvedSegmentVoiceIDs.compactMapValues {
            voiceLibrary.dubReference(for: $0)
        }
        dubs[index].state = .running
        dubs[index].progress = 0.02
        dubs[index].progressMessage = "Loading local voice model…"
        dubs[index].flowProgressStage = .dubPreprocessing
        dubs[index].progressStep = "flow_started"
        dubs[index].progressCompleted = nil
        dubs[index].progressTotal = nil
        dubs[index].errorMessage = nil
        dubs[index].alignedTranscript = nil
        dubs[index].subtitleTrack = nil
        dubs[index].alignmentDiagnostics = nil
        dubs[index].summaryMarkdown = nil
        dubs[index].summaryTemplateID = nil
        dubs[index].summaryTemplateName = nil
        dubs[index].sessionTag = nil
        dubs[index].internalSummary = nil
        dubs[index].summaryState = nil
        dubs[index].summaryErrorMessage = nil
        save()

        let payload = DubFlowPayload(
            segments: snapshot.segments ?? [],
            language: snapshot.language,
            model: snapshot.model,
            reference: reference,
            speakerReferences: speakerReferences,
            segmentReferences: segmentReferences,
            timelineMode: .automatic,
            seed: DubSeed.deterministic(
                language: snapshot.language,
                text: "\(id.uuidString)\n\(snapshot.script)"
            ),
            xvecOnly: false
        )
        let task = Task { [weak self] in
            guard let self else { return }
            defer { flowTasks[id] = nil }
            _ = await LLMSettingsStore.shared.credentialAvailable()
            let hasSubtitleModel = LLMSettingsStore.shared.hasConfiguredModel(
                for: .subtitleProcessing
            )
            if Task.isCancelled {
                updateDub(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                return
            }
            let request = MediaFlowRequest(
                id: id,
                input: .script(snapshot.script),
                steps: WorkbenchMediaFlowPlanner.dubSteps(
                    payload: payload,
                    hasAPIKey: hasSubtitleModel
                )
            )
            for await event in MediaFlowExecutor.shared.events(for: request) {
                if Task.isCancelled { break }
                consumeDubEvent(
                    event,
                    jobID: id,
                    resolvedReferenceVoiceID: defaultVoiceID
                )
            }
            if Task.isCancelled {
                updateDub(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                return
            }
            guard let job = dubs.first(where: { $0.id == id }),
                  job.state == .completed else { return }
            await enrichAfterDubCompletion(job)
        }
        flowTasks[id] = task
    }

    private func enrichAfterDubCompletion(_ job: WorkbenchDubJob) async {
        if let transcriptionID = job.sourceTranscriptionID,
           let transcription = transcriptions.first(where: { $0.id == transcriptionID }),
           transcription.state == .completed,
           needsSummary(
                markdown: transcription.summaryMarkdown,
                state: transcription.summaryState
           ) {
            await enrichCompletedTranscription(transcriptionID)
        }
        guard let current = dubs.first(where: { $0.id == job.id }),
              current.state == .completed,
              needsSummary(markdown: current.summaryMarkdown, state: current.summaryState) else {
            return
        }
        await enrichCompletedDub(current.id)
    }

    func cancelDub(_ id: UUID) {
        guard flowTasks[id] != nil else { return }
        flowTasks[id]?.cancel()
        updateDub(id) {
            $0.state = .cancelling
            $0.errorMessage = nil
            $0.progressMessage = "Cancelling media flow…"
        }
    }

    func useTranscript(_ transcriptID: UUID, forDub dubID: UUID, track: WorkbenchTranscriptTrack) {
        guard let source = transcriptions.first(where: { $0.id == transcriptID }) else { return }
        let subtitleTrack: SubtitleTrack?
        switch track {
        case .source:
            subtitleTrack = source.subtitleTrack ?? source.result.map(SubtitleTrack.fromTranscript)
        case .translation:
            subtitleTrack = source.translationTrack
        }
        guard let subtitleTrack else { return }
        updateDub(dubID) {
            $0.sourceTranscriptionID = transcriptID
            $0.script = subtitleTrack.text
            $0.segments = subtitleTrack.cues.map { cue in
                DubSegmentPayload(
                    index: cue.id,
                    text: cue.text,
                    start: cue.start,
                    end: cue.end,
                    speaker: cue.speaker,
                    sourceSubtitleID: cue.sourceIDs.first
                )
            }
            $0.language = track == .translation
                ? (subtitleTrack.language ?? "auto")
                : (source.languageCode ?? subtitleTrack.language ?? "auto")
            // Keep a user-authored title; otherwise leave blank for post-dub auto-generation.
            if !SessionTitlePolicy.isUserProvided($0.title) {
                $0.title = ""
            }
            $0.state = .ready
            $0.progress = 0
            $0.progressMessage = $0.outputURL == nil
                ? "Ready to synthesize"
                : "Configuration changed — ready to regenerate"
            $0.errorMessage = nil
        }
    }

    func isVoiceReferenceInUse(_ id: UUID) -> Bool {
        dubs.contains { job in
            job.referenceVoiceID == id
                || job.resolvedSpeakerVoiceIDs.values.contains(id)
                || job.resolvedSegmentVoiceIDs.values.contains(id)
        }
    }

    func activateDubRevision(_ revisionID: UUID, forDub dubID: UUID) {
        updateDub(dubID) { job in
            guard let revision = job.revisions?.first(where: { $0.id == revisionID }) else { return }
            job.activeRevisionID = revisionID
            job.outputPath = revision.outputPath
            job.renderedSegments = revision.renderedSegments
            job.alignedTranscript = revision.alignedTranscript
            job.subtitleTrack = revision.subtitleTrack
            job.alignmentDiagnostics = revision.alignmentDiagnostics
        }
    }

    private func consumeTranscriptionEvent(
        _ event: MediaJobEvent,
        jobID: UUID,
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?
    ) async {
        switch event {
        case .progress(let progress):
            updateTranscription(jobID) { job in
                job.flowProgressStage = progress.stage
                job.progressStep = progress.step
                job.progressCompleted = progress.current
                job.progressTotal = progress.total
                job.progressMessage = progress.message
                if progress.status == .started || progress.status == .processing {
                    job.state = .running
                    job.progress = max(job.progress, progress.progress)
                } else if progress.status == .completed {
                    job.state = .completed
                    job.progress = 1
                    if job.translationTrack != nil {
                        job.progressMessage = "Transcript and translation ready"
                    } else if job.subtitleTrack != nil {
                        job.progressMessage = "Transcript and subtitles ready"
                    } else {
                        job.progressMessage = "Transcript ready"
                    }
                    job.selectedTrack = job.translationTrack == nil ? .source : .translation
                    job.errorMessage = nil
                } else if progress.status == .cancelled {
                    job.state = .cancelled
                    job.progressMessage = "Cancelled — ready to retry"
                    job.errorMessage = nil
                } else if progress.status == .failed {
                    job.state = .failed
                    job.errorMessage = progress.message
                }
            }

        case .artifact(.transcription(let result, let diagnostics)):
            updateTranscription(jobID) {
                $0.result = result
                $0.editedText = result.text
                $0.diarizationDiagnostics = diagnostics
            }
            await TranscriptCache.shared.storeLocalTranscript(
                result,
                for: sourceURL,
                configuration: .init(languageCode: languageCode, speakerCount: speakerCount)
            )

        case .artifact(.subtitles(let track)):
            updateTranscription(jobID) {
                $0.subtitleTrack = track
                $0.editedText = track.text
                if let result = $0.result {
                    let timed = track.asTranscriptionResult(preservingWords: result.words)
                    $0.result = timed.aggregatingSegments()
                }
            }

        case .artifact(.translation(let track)):
            updateTranscription(jobID) { job in
                let code = (track.language ?? job.targetLanguageCode ?? "und")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                job.upsertTranslation(track, languageCode: code.isEmpty ? "und" : code)
                job.selectedTrack = .translation
            }

        case .artifact(.alignment), .artifact(.dub):
            break
        }
    }

    /// Auto title + template summary after transcription, aligned with postprocess finalize → digest → template summary.
    private func enrichCompletedTranscription(
        _ id: UUID,
        userInstruction: String? = nil
    ) async {
        guard summaryTaskIDs.insert(id).inserted else { return }
        defer { summaryTaskIDs.remove(id) }

        guard LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing) else {
            updateTranscription(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
            WorkbenchTipCenter.shared.show(
                LLMConfigurationError.noConfiguredModel(.subtitleProcessing).localizedDescription,
                kind: .error,
                id: "summary.missing-llm",
                actionLabel: "Open AI Settings",
                action: .openAISettings
            )
            return
        }
        guard let job = transcriptions.first(where: { $0.id == id }),
              let transcript = job.result ?? job.sourceTimedResult else { return }
        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptText.isEmpty else { return }
        let isRefinement = !(userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty

        updateTranscription(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = isRefinement
                ? "Regenerating summary…"
                : "Generating title and summary…"
        }

        do {
            let route = try await LLMSettingsStore.shared.runtimeRoute(for: .subtitleProcessing)
            let client = ResilientLLMTextClient(route: route)
            var title = job.sessionTitle
            var tagText = job.sessionTag ?? "general"
            var internalSummary = job.internalSummary ?? ""
            if !isRefinement {
                let metadata = try await SessionTitleLLMProcessor(client: client).generate(
                    transcriptText: transcriptText,
                    sourceLanguage: transcript.language ?? job.languageCode,
                    existingTitle: SessionTitlePolicy.normalizedUserTitle(job.customTitle)
                )
                let shouldApplyTitle = !SessionTitlePolicy.isUserProvided(job.customTitle)
                updateTranscription(id) {
                    if shouldApplyTitle {
                        $0.customTitle = metadata.title
                    }
                    $0.sessionTag = metadata.tagText
                    $0.internalSummary = metadata.internalSummary
                }
                title = shouldApplyTitle ? metadata.title : job.sessionTitle
                tagText = metadata.tagText
                internalSummary = metadata.internalSummary
            }

            let template = await SummaryTemplateCatalog.shared.template(forID: job.summaryTemplateID)
            let lines = TemplateSummaryLLMProcessor.transcriptLines(
                from: job.subtitleTrack?
                    .asTranscriptionResult(preservingWords: transcript.words)
                    .aggregatingSegments()
                    ?? transcript.aggregatingSegments()
            )
            let markdown = try await TemplateSummaryLLMProcessor(client: client).synthesize(
                template: template,
                transcriptLines: lines,
                title: title,
                tagText: tagText,
                sourceLanguage: transcript.language ?? job.languageCode,
                internalSummary: internalSummary,
                userInstruction: userInstruction
            )
            updateTranscription(id) {
                $0.summaryMarkdown = markdown
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.translationTracks.isEmpty
                    ? "Transcript and summary ready"
                    : "Transcript, translation, and summary ready"
            }
        } catch {
            updateTranscription(id) {
                $0.summaryState = .failed
                $0.summaryErrorMessage = error.localizedDescription
                $0.progressMessage = isRefinement
                    ? "Summary regeneration failed"
                    : "Transcript ready — summary unavailable"
            }
            WorkbenchTipCenter.shared.show(
                error.localizedDescription,
                kind: .error,
                id: "summary.failed.\(id.uuidString)"
            )
            Log.project.warning("session enrichment failed: \(error.localizedDescription)")
        }
    }

    func selectTranslationLanguage(_ languageCode: String, forTranscription id: UUID) {
        updateTranscription(id) { job in
            guard job.translationTracks.contains(where: {
                $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
            }) else { return }
            job.selectedTranslationLanguageCode = languageCode
            job.selectedTrack = .translation
        }
    }

    func regenerateSummary(forTranscription id: UUID, userPrompt: String? = nil) {
        let prompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard userPrompt == nil || !(prompt?.isEmpty ?? true),
              !summaryTaskIDs.contains(id) else {
            return
        }
        guard let job = transcriptions.first(where: { $0.id == id }),
              job.state == .completed,
              let transcript = job.result ?? job.sourceTimedResult,
              !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            WorkbenchTipCenter.shared.show(
                "Summary cannot be regenerated because no completed transcript is available.",
                kind: .error,
                id: "summary.unavailable.\(id.uuidString)"
            )
            return
        }
        WorkbenchTipCenter.shared.show(
            prompt == nil
                ? "Regenerating summary…"
                : "Processing: regenerating the summary with your instructions…",
            kind: .info,
            id: "summary.processing.\(id.uuidString)"
        )
        Task { await enrichCompletedTranscription(id, userInstruction: prompt) }
    }

    func regenerateSummary(forDub id: UUID, userPrompt: String? = nil) {
        let prompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard userPrompt == nil || !(prompt?.isEmpty ?? true),
              !summaryTaskIDs.contains(id) else {
            return
        }
        guard let job = dubs.first(where: { $0.id == id }),
              job.state == .completed,
              let transcript = dubTranscriptForEnrichment(job),
              !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            WorkbenchTipCenter.shared.show(
                "Summary cannot be regenerated because no completed dub transcript is available.",
                kind: .error,
                id: "summary.unavailable.\(id.uuidString)"
            )
            return
        }
        WorkbenchTipCenter.shared.show(
            prompt == nil
                ? "Regenerating summary…"
                : "Processing: regenerating the summary with your instructions…",
            kind: .info,
            id: "summary.processing.\(id.uuidString)"
        )
        Task { await enrichCompletedDub(id, userInstruction: prompt) }
    }

    /// Auto title + template summary after standalone dub, mirrored from transcription enrichment.
    private func enrichCompletedDub(
        _ id: UUID,
        userInstruction: String? = nil
    ) async {
        guard summaryTaskIDs.insert(id).inserted else { return }
        defer { summaryTaskIDs.remove(id) }

        guard LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing) else {
            updateDub(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
            WorkbenchTipCenter.shared.show(
                LLMConfigurationError.noConfiguredModel(.subtitleProcessing).localizedDescription,
                kind: .error,
                id: "summary.missing-llm",
                actionLabel: "Open AI Settings",
                action: .openAISettings
            )
            return
        }
        guard let job = dubs.first(where: { $0.id == id }),
              let transcript = dubTranscriptForEnrichment(job) else { return }
        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptText.isEmpty else { return }
        let isRefinement = !(userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty

        updateDub(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = isRefinement
                ? "Regenerating summary…"
                : "Generating title and summary…"
        }

        do {
            let route = try await LLMSettingsStore.shared.runtimeRoute(for: .subtitleProcessing)
            let client = ResilientLLMTextClient(route: route)
            var title = job.displayTitle
            var tagText = job.sessionTag ?? "general"
            var internalSummary = job.internalSummary ?? ""
            if !isRefinement {
                let shouldApplyTitle = !SessionTitlePolicy.isUserProvided(job.title)
                let metadata = try await SessionTitleLLMProcessor(client: client).generate(
                    transcriptText: transcriptText,
                    sourceLanguage: transcript.language ?? job.language,
                    existingTitle: SessionTitlePolicy.normalizedUserTitle(job.title)
                )
                updateDub(id) {
                    if shouldApplyTitle {
                        $0.title = metadata.title
                    }
                    $0.sessionTag = metadata.tagText
                    $0.internalSummary = metadata.internalSummary
                }
                if shouldApplyTitle,
                   let sourceID = job.sourceTranscriptionID,
                   let source = transcriptions.first(where: { $0.id == sourceID }),
                   !SessionTitlePolicy.isUserProvided(source.customTitle) {
                    updateTranscription(sourceID) {
                        $0.customTitle = metadata.title
                    }
                }
                title = shouldApplyTitle ? metadata.title : job.displayTitle
                tagText = metadata.tagText
                internalSummary = metadata.internalSummary
            }

            let template = await SummaryTemplateCatalog.shared.template(forID: job.summaryTemplateID)
            let lines = TemplateSummaryLLMProcessor.transcriptLines(from: transcript)
            let markdown = try await TemplateSummaryLLMProcessor(client: client).synthesize(
                template: template,
                transcriptLines: lines,
                title: title,
                tagText: tagText,
                sourceLanguage: transcript.language ?? job.language,
                internalSummary: internalSummary,
                userInstruction: userInstruction
            )
            updateDub(id) {
                $0.summaryMarkdown = markdown
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.subtitleTrack == nil
                    ? "Dub and summary ready"
                    : "Dub, subtitles, and summary ready"
            }
        } catch {
            updateDub(id) {
                $0.summaryState = .failed
                $0.summaryErrorMessage = error.localizedDescription
                $0.progressMessage = isRefinement
                    ? "Summary regeneration failed"
                    : "Dub ready — summary unavailable"
            }
            WorkbenchTipCenter.shared.show(
                error.localizedDescription,
                kind: .error,
                id: "summary.failed.\(id.uuidString)"
            )
            Log.project.warning("dub session enrichment failed: \(error.localizedDescription)")
        }
    }

    private func dubTranscriptForEnrichment(_ job: WorkbenchDubJob) -> TranscriptionResult? {
        if let track = job.subtitleTrack ?? job.renderedSubtitleTrack {
            return track.asTranscriptionResult(preservingWords: job.alignedTranscript?.words ?? [])
                .aggregatingSegments()
        }
        if let aligned = job.alignedTranscript {
            return aligned.aggregatingSegments()
        }
        return nil
    }

    private func consumeDubEvent(
        _ event: MediaJobEvent,
        jobID: UUID,
        resolvedReferenceVoiceID: UUID?
    ) {
        switch event {
        case .progress(let progress):
            updateDub(jobID) { job in
                job.flowProgressStage = progress.stage
                job.progressStep = progress.step
                job.progressCompleted = progress.current
                job.progressTotal = progress.total
                job.progressMessage = progress.message
                if progress.status == .started || progress.status == .processing {
                    job.state = .running
                    job.progress = max(job.progress, progress.progress)
                } else if progress.status == .completed {
                    job.state = .completed
                    job.progress = 1
                    if let estimated = job.alignmentDiagnostics?.estimatedUnitCount,
                       estimated > 0 {
                        job.progressMessage = "Dub ready · \(estimated) word timings estimated"
                    } else {
                        job.progressMessage = job.subtitleTrack == nil
                            ? "Dub ready"
                            : "Dub and subtitles ready"
                    }
                    job.errorMessage = nil
                } else if progress.status == .cancelled {
                    job.state = .cancelled
                    job.progressMessage = "Cancelled — ready to retry"
                    job.errorMessage = nil
                } else if progress.status == .failed {
                    job.state = .failed
                    job.errorMessage = progress.message
                }
            }

        case .artifact(.dub(let output)):
            updateDub(jobID) { job in
                let revision = WorkbenchDubRevision(
                    outputPath: output.outputURL.path,
                    renderedSegments: output.segments,
                    referenceVoiceID: resolvedReferenceVoiceID,
                    speakerVoiceIDs: job.resolvedSpeakerVoiceIDs,
                    segmentVoiceIDs: job.resolvedSegmentVoiceIDs,
                    model: job.model,
                    language: job.language,
                    alignedTranscript: nil,
                    subtitleTrack: nil,
                    alignmentDiagnostics: nil
                )
                job.outputPath = output.outputURL.path
                job.renderedSegments = output.segments
                job.revisions = (job.revisions ?? []) + [revision]
                job.activeRevisionID = revision.id
            }

        case .artifact(.alignment(let output)):
            updateDub(jobID) { job in
                let transcript = output.result.aggregatingSegments()
                job.alignedTranscript = transcript
                job.alignmentDiagnostics = output.diagnostics
                if let activeRevisionID = job.activeRevisionID,
                   let index = job.revisions?.firstIndex(where: { $0.id == activeRevisionID }) {
                    job.revisions?[index].alignedTranscript = transcript
                    job.revisions?[index].alignmentDiagnostics = output.diagnostics
                }
            }

        case .artifact(.subtitles(let track)):
            updateDub(jobID) { job in
                job.subtitleTrack = track
                let transcript = track.asTranscriptionResult(
                    preservingWords: job.alignedTranscript?.words ?? []
                ).aggregatingSegments()
                job.alignedTranscript = transcript
                if let activeRevisionID = job.activeRevisionID,
                   let index = job.revisions?.firstIndex(where: { $0.id == activeRevisionID }) {
                    job.revisions?[index].subtitleTrack = track
                    job.revisions?[index].alignedTranscript = transcript
                }
            }

        case .artifact:
            break
        }
    }

    func revealTranscriptionDiagnostics(_ id: UUID) async throws {
        guard let job = transcriptions.first(where: { $0.id == id }),
              let diagnostics = job.diarizationDiagnostics else { return }
        let directory = Self.dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        let url = directory.appendingPathComponent("transcription-\(id.uuidString).json")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(diagnostics).write(to: url, options: .atomic)
        }.value
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio", isDirectory: true)
    }

    private static var clipsDirectory: URL {
        dataDirectory.appendingPathComponent("Clips", isDirectory: true)
    }

    private static var snapshotURL: URL {
        dataDirectory.appendingPathComponent("workbench.json")
    }

    private func removeManagedClipMediaIfNeeded(_ url: URL) {
        let clipsRoot = Self.clipsDirectory.resolvingSymlinksInPath().path
        let candidate = url.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(clipsRoot + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func hydrate() async {
        let snapshot = await persistence.load()
        if let snapshot {
            let currentTranscriptionIDs = Set(transcriptions.map(\.id))
            let currentDubIDs = Set(dubs.map(\.id))
            let persistedTranscriptions = snapshot.transcriptions
                .filter { !currentTranscriptionIDs.contains($0.id) }
                .map(Self.recoveredForLaunch)
            let persistedDubs = snapshot.dubs
                .filter { !currentDubIDs.contains($0.id) }
                .map(Self.recoveredForLaunch)
            transcriptions.append(contentsOf: persistedTranscriptions)
            dubs.append(contentsOf: persistedDubs)
        }
        hasHydrated = true
        if pendingNewDubDraft {
            pendingNewDubDraft = false
            startNewDubDraft()
            return
        }
        if saveRequestedBeforeHydration
            || snapshot?.transcriptions.contains(where: Self.needsLaunchRecovery) == true
            || snapshot?.dubs.contains(where: Self.needsLaunchRecovery) == true {
            saveRequestedBeforeHydration = false
            save()
        }
    }

    nonisolated static func recoveredForLaunch(
        _ job: WorkbenchTranscriptionJob
    ) -> WorkbenchTranscriptionJob {
        guard needsLaunchRecovery(job) else { return job }
        var repaired = job
        repaired.state = .ready
        repaired.progress = 0
        repaired.progressMessage = "Interrupted — ready to retry"
        repaired.progressStage = nil
        repaired.flowProgressStage = nil
        repaired.progressStep = nil
        repaired.progressCompleted = nil
        repaired.progressTotal = nil
        repaired.errorMessage = nil
        return repaired
    }

    nonisolated static func recoveredForLaunch(_ job: WorkbenchDubJob) -> WorkbenchDubJob {
        guard needsLaunchRecovery(job) else { return job }
        var repaired = job
        repaired.state = .ready
        repaired.progress = 0
        repaired.progressMessage = "Interrupted — ready to retry"
        repaired.flowProgressStage = nil
        repaired.progressStep = nil
        repaired.progressCompleted = nil
        repaired.progressTotal = nil
        repaired.errorMessage = nil
        return repaired
    }

    private nonisolated static func needsLaunchRecovery(_ job: WorkbenchTranscriptionJob) -> Bool {
        job.state == .running || job.state == .cancelling
            || (job.state == .ready && job.result == nil && job.progress > 0)
    }

    private nonisolated static func needsLaunchRecovery(_ job: WorkbenchDubJob) -> Bool {
        job.state == .running || job.state == .cancelling
            || (job.state == .ready && job.outputPath == nil && job.progress > 0)
    }

    private nonisolated static func combinedState(
        primary: WorkbenchJobState,
        secondary: WorkbenchJobState?
    ) -> WorkbenchJobState {
        guard let secondary else { return primary }
        let priority: [WorkbenchJobState: Int] = [
            .failed: 6, .cancelling: 5, .running: 4, .ready: 3,
            .cancelled: 2, .completed: 1,
        ]
        return (priority[secondary] ?? 0) > (priority[primary] ?? 0) ? secondary : primary
    }

    private nonisolated static func fallbackDubSegments(
        for job: WorkbenchDubJob
    ) -> [DubRenderedSegment] {
        if let segments = job.segments, !segments.isEmpty {
            return segments.map {
                DubRenderedSegment(
                    index: $0.index,
                    text: $0.text,
                    start: $0.start ?? 0,
                    end: $0.end ?? ($0.start ?? 0),
                    speaker: $0.speaker,
                    sourceSubtitleID: $0.sourceSubtitleID
                )
            }
        }
        let text = job.script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [DubRenderedSegment(index: 0, text: text, start: 0, end: 0)]
    }

    private func save() {
        guard hasHydrated else {
            saveRequestedBeforeHydration = true
            return
        }
        let snapshot = WorkbenchSnapshot(
            schemaVersion: 4,
            transcriptions: transcriptions,
            dubs: dubs
        )
        saveRevision += 1
        let revision = saveRevision
        Task {
            await persistence.save(snapshot, revision: revision)
        }
    }
}
