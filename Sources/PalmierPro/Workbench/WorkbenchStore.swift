import AppKit
import Foundation
import Observation

enum WorkbenchRoute: String, Codable, CaseIterable, Identifiable {
    case recent
    case dashboard
    case transcribe
    case meetBot
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
        case .meetBot: "Meet Bot"
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
        case .meetBot: "calendar.badge.clock"
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
        case .meetBot: .meetBot
        case .dub: .voiceover
        default: .system(systemImage)
        }
    }

    static let sidebarRoutes: [WorkbenchRoute] = [
        .recent, .dashboard, .transcribe, .meetBot, .dub, .voiceLibrary, .videoEditor,
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
    var netVideoSourceURL: String?
    var netVideoVideoID: String?
    var netVideoPlatform: String?
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
    var summaryTemplateUserEdition: String?
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
    var transcriptionAlignmentDiagnostics: TranscriptionAlignmentDiagnostics?
    var errorMessage: String?
    var storage: TaskStorageDestination = .local
    var compute: TaskComputeDestination = .local
    var remoteSessionID: UUID?
    var localCachePath: String?
    var cloudSyncRevision = 0
    var cloudSyncState: DubCloudSyncState?
    var pendingCloudSyncError: String?
    var isRecordedCapture = false

    var placement: TranscriptionPlacement {
        get { TranscriptionPlacement(storage: storage, compute: compute) }
        set {
            storage = newValue.storage
            compute = newValue.compute
        }
    }

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

    var resolvedCloudSyncState: DubCloudSyncState { cloudSyncState ?? .none }

    var processingOptions: LocalProcessingOptions {
        LocalProcessingOptions(
            languageCode: languageCode,
            customTitle: customTitle,
            speakerCount: speakerCount,
            enableTranslation: normalizedTargetLanguageCode != nil,
            targetLanguageCode: targetLanguageCode,
            useLLMSubtitleProcessing: useLLMSubtitleProcessing,
            clipStartMs: clipStartMs,
            clipEndMs: clipEndMs
        )
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
        case id, sourcePath, netVideoSourceURL, netVideoVideoID, netVideoPlatform, customTitle, createdAt, modifiedAt, state
        case languageCode, speakerCount, clipStartMs, clipEndMs, batchID
        case result, editedText, useLLMSubtitleProcessing, targetLanguageCode
        case subtitleTrack, translationTrack, translationTracks
        case selectedTranslationLanguageCode, selectedTrack
        case summaryMarkdown, summaryTemplateID, summaryTemplateName, summaryTemplateUserEdition
        case sessionTag, internalSummary, summaryState, summaryErrorMessage
        case progress, progressMessage, progressStage, flowProgressStage
        case progressStep, progressCompleted, progressTotal
        case diarizationDiagnostics, transcriptionAlignmentDiagnostics, errorMessage
        case storage, compute, remoteSessionID, localCachePath
        case cloudSyncRevision, cloudSyncState, pendingCloudSyncError
        case isRecordedCapture
    }

    init(
        id: UUID = UUID(),
        sourcePath: String,
        netVideoSourceURL: String? = nil,
        netVideoVideoID: String? = nil,
        netVideoPlatform: String? = nil,
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
        summaryTemplateUserEdition: String? = nil,
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
        transcriptionAlignmentDiagnostics: TranscriptionAlignmentDiagnostics? = nil,
        errorMessage: String? = nil,
        storage: TaskStorageDestination = .local,
        compute: TaskComputeDestination = .local,
        remoteSessionID: UUID? = nil,
        localCachePath: String? = nil,
        cloudSyncRevision: Int = 0,
        cloudSyncState: DubCloudSyncState? = nil,
        pendingCloudSyncError: String? = nil,
        isRecordedCapture: Bool = false
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.netVideoSourceURL = netVideoSourceURL
        self.netVideoVideoID = netVideoVideoID
        self.netVideoPlatform = netVideoPlatform
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
        self.summaryTemplateUserEdition = summaryTemplateUserEdition
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
        self.transcriptionAlignmentDiagnostics = transcriptionAlignmentDiagnostics
        self.errorMessage = errorMessage
        self.storage = storage
        self.compute = compute
        self.remoteSessionID = remoteSessionID
        self.localCachePath = localCachePath
        self.cloudSyncRevision = cloudSyncRevision
        self.cloudSyncState = cloudSyncState
        self.pendingCloudSyncError = pendingCloudSyncError
        self.isRecordedCapture = isRecordedCapture
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        netVideoSourceURL = try container.decodeIfPresent(String.self, forKey: .netVideoSourceURL)
        netVideoVideoID = try container.decodeIfPresent(String.self, forKey: .netVideoVideoID)
        netVideoPlatform = try container.decodeIfPresent(String.self, forKey: .netVideoPlatform)
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
        summaryTemplateUserEdition = try container.decodeIfPresent(String.self, forKey: .summaryTemplateUserEdition)
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
        transcriptionAlignmentDiagnostics = try container.decodeIfPresent(
            TranscriptionAlignmentDiagnostics.self,
            forKey: .transcriptionAlignmentDiagnostics
        )
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        storage = try container.decodeIfPresent(TaskStorageDestination.self, forKey: .storage) ?? .local
        compute = try container.decodeIfPresent(TaskComputeDestination.self, forKey: .compute) ?? .local
        remoteSessionID = try container.decodeIfPresent(UUID.self, forKey: .remoteSessionID)
        localCachePath = try container.decodeIfPresent(String.self, forKey: .localCachePath)
        cloudSyncRevision = try container.decodeIfPresent(Int.self, forKey: .cloudSyncRevision) ?? 0
        cloudSyncState = try container.decodeIfPresent(DubCloudSyncState.self, forKey: .cloudSyncState)
        pendingCloudSyncError = try container.decodeIfPresent(String.self, forKey: .pendingCloudSyncError)
        isRecordedCapture = try container.decodeIfPresent(Bool.self, forKey: .isRecordedCapture) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(netVideoSourceURL, forKey: .netVideoSourceURL)
        try container.encodeIfPresent(netVideoVideoID, forKey: .netVideoVideoID)
        try container.encodeIfPresent(netVideoPlatform, forKey: .netVideoPlatform)
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
        try container.encodeIfPresent(summaryTemplateUserEdition, forKey: .summaryTemplateUserEdition)
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
        try container.encodeIfPresent(
            transcriptionAlignmentDiagnostics,
            forKey: .transcriptionAlignmentDiagnostics
        )
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(storage, forKey: .storage)
        try container.encode(compute, forKey: .compute)
        try container.encodeIfPresent(remoteSessionID, forKey: .remoteSessionID)
        try container.encodeIfPresent(localCachePath, forKey: .localCachePath)
        try container.encode(cloudSyncRevision, forKey: .cloudSyncRevision)
        try container.encodeIfPresent(cloudSyncState, forKey: .cloudSyncState)
        try container.encodeIfPresent(pendingCloudSyncError, forKey: .pendingCloudSyncError)
        try container.encode(isRecordedCapture, forKey: .isRecordedCapture)
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

enum DubCloudSyncState: String, Codable, Sendable {
    case none
    case pending
    case completed
    case failed
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
    var summaryTemplateUserEdition: String?
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
    // Optional storage fields preserve local/local defaults for pre-placement projects.
    var storage: TaskStorageDestination?
    var compute: TaskComputeDestination?
    var remoteSessionID: UUID?
    var remoteGenerationID: String?
    var clientRequestID: String?
    var localCachePath: String?
    var cloudSyncRevision = 0
    var cloudSyncState: DubCloudSyncState?
    var remoteResultVersion: String?
    var pendingCloudSyncError: String?

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

    var placement: TaskPlacement {
        get {
            TaskPlacement(
                storage: storage ?? .local,
                compute: compute ?? .local
            )
        }
        set {
            storage = newValue.storage
            compute = newValue.compute
        }
    }

    var resolvedStorage: TaskStorageDestination { storage ?? .local }
    var resolvedCompute: TaskComputeDestination { compute ?? .local }
    var resolvedCloudSyncState: DubCloudSyncState { cloudSyncState ?? .none }

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, modifiedAt, state, script, language, model
        case referenceAudioPath, referenceText, referenceVoiceID
        case speakerVoiceIDs, segmentVoiceIDs, sourceTranscriptionID, outputPath
        case segments, renderedSegments, alignedTranscript, subtitleTrack
        case alignmentDiagnostics, revisions, activeRevisionID
        case summaryMarkdown, summaryTemplateID, summaryTemplateName, summaryTemplateUserEdition
        case sessionTag, internalSummary, summaryState, summaryErrorMessage
        case progress, progressMessage, flowProgressStage, progressStep
        case progressCompleted, progressTotal, errorMessage
        case storage, compute, remoteSessionID, remoteGenerationID, clientRequestID
        case localCachePath, cloudSyncRevision, cloudSyncState, remoteResultVersion
        case pendingCloudSyncError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        state = try container.decodeIfPresent(WorkbenchJobState.self, forKey: .state) ?? .ready
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        model = try container.decodeIfPresent(DubModelChoice.self, forKey: .model) ?? .medium
        referenceAudioPath = try container.decodeIfPresent(String.self, forKey: .referenceAudioPath)
        referenceText = try container.decodeIfPresent(String.self, forKey: .referenceText) ?? ""
        referenceVoiceID = try container.decodeIfPresent(UUID.self, forKey: .referenceVoiceID)
        speakerVoiceIDs = try container.decodeIfPresent([String: UUID].self, forKey: .speakerVoiceIDs)
        segmentVoiceIDs = try container.decodeIfPresent([Int: UUID].self, forKey: .segmentVoiceIDs)
        sourceTranscriptionID = try container.decodeIfPresent(UUID.self, forKey: .sourceTranscriptionID)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        segments = try container.decodeIfPresent([DubSegmentPayload].self, forKey: .segments)
        renderedSegments = try container.decodeIfPresent([DubRenderedSegment].self, forKey: .renderedSegments)
        alignedTranscript = try container.decodeIfPresent(TranscriptionResult.self, forKey: .alignedTranscript)
        subtitleTrack = try container.decodeIfPresent(SubtitleTrack.self, forKey: .subtitleTrack)
        alignmentDiagnostics = try container.decodeIfPresent(
            KnownTextAlignmentDiagnostics.self,
            forKey: .alignmentDiagnostics
        )
        revisions = try container.decodeIfPresent([WorkbenchDubRevision].self, forKey: .revisions)
        activeRevisionID = try container.decodeIfPresent(UUID.self, forKey: .activeRevisionID)
        summaryMarkdown = try container.decodeIfPresent(String.self, forKey: .summaryMarkdown)
        summaryTemplateID = try container.decodeIfPresent(String.self, forKey: .summaryTemplateID)
        summaryTemplateName = try container.decodeIfPresent(String.self, forKey: .summaryTemplateName)
        summaryTemplateUserEdition = try container.decodeIfPresent(
            String.self,
            forKey: .summaryTemplateUserEdition
        )
        sessionTag = try container.decodeIfPresent(String.self, forKey: .sessionTag)
        internalSummary = try container.decodeIfPresent(String.self, forKey: .internalSummary)
        summaryState = try container.decodeIfPresent(WorkbenchJobState.self, forKey: .summaryState)
        summaryErrorMessage = try container.decodeIfPresent(String.self, forKey: .summaryErrorMessage)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        progressMessage = try container.decodeIfPresent(String.self, forKey: .progressMessage)
            ?? "Ready to synthesize"
        flowProgressStage = try container.decodeIfPresent(MediaFlowStage.self, forKey: .flowProgressStage)
        progressStep = try container.decodeIfPresent(String.self, forKey: .progressStep)
        progressCompleted = try container.decodeIfPresent(Int.self, forKey: .progressCompleted)
        progressTotal = try container.decodeIfPresent(Int.self, forKey: .progressTotal)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        storage = try container.decodeIfPresent(TaskStorageDestination.self, forKey: .storage)
        compute = try container.decodeIfPresent(TaskComputeDestination.self, forKey: .compute)
        remoteSessionID = try container.decodeIfPresent(UUID.self, forKey: .remoteSessionID)
        remoteGenerationID = try container.decodeIfPresent(String.self, forKey: .remoteGenerationID)
        clientRequestID = try container.decodeIfPresent(String.self, forKey: .clientRequestID)
        localCachePath = try container.decodeIfPresent(String.self, forKey: .localCachePath)
        // Older snapshots omit this key; default keeps cloud-edit sync monotonic.
        cloudSyncRevision = try container.decodeIfPresent(Int.self, forKey: .cloudSyncRevision) ?? 0
        cloudSyncState = try container.decodeIfPresent(DubCloudSyncState.self, forKey: .cloudSyncState)
        remoteResultVersion = try container.decodeIfPresent(String.self, forKey: .remoteResultVersion)
        pendingCloudSyncError = try container.decodeIfPresent(String.self, forKey: .pendingCloudSyncError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(state, forKey: .state)
        try container.encode(script, forKey: .script)
        try container.encode(language, forKey: .language)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(referenceAudioPath, forKey: .referenceAudioPath)
        try container.encode(referenceText, forKey: .referenceText)
        try container.encodeIfPresent(referenceVoiceID, forKey: .referenceVoiceID)
        try container.encodeIfPresent(speakerVoiceIDs, forKey: .speakerVoiceIDs)
        try container.encodeIfPresent(segmentVoiceIDs, forKey: .segmentVoiceIDs)
        try container.encodeIfPresent(sourceTranscriptionID, forKey: .sourceTranscriptionID)
        try container.encodeIfPresent(outputPath, forKey: .outputPath)
        try container.encodeIfPresent(segments, forKey: .segments)
        try container.encodeIfPresent(renderedSegments, forKey: .renderedSegments)
        try container.encodeIfPresent(alignedTranscript, forKey: .alignedTranscript)
        try container.encodeIfPresent(subtitleTrack, forKey: .subtitleTrack)
        try container.encodeIfPresent(alignmentDiagnostics, forKey: .alignmentDiagnostics)
        try container.encodeIfPresent(revisions, forKey: .revisions)
        try container.encodeIfPresent(activeRevisionID, forKey: .activeRevisionID)
        try container.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
        try container.encodeIfPresent(summaryTemplateID, forKey: .summaryTemplateID)
        try container.encodeIfPresent(summaryTemplateName, forKey: .summaryTemplateName)
        try container.encodeIfPresent(summaryTemplateUserEdition, forKey: .summaryTemplateUserEdition)
        try container.encodeIfPresent(sessionTag, forKey: .sessionTag)
        try container.encodeIfPresent(internalSummary, forKey: .internalSummary)
        try container.encodeIfPresent(summaryState, forKey: .summaryState)
        try container.encodeIfPresent(summaryErrorMessage, forKey: .summaryErrorMessage)
        try container.encode(progress, forKey: .progress)
        try container.encode(progressMessage, forKey: .progressMessage)
        try container.encodeIfPresent(flowProgressStage, forKey: .flowProgressStage)
        try container.encodeIfPresent(progressStep, forKey: .progressStep)
        try container.encodeIfPresent(progressCompleted, forKey: .progressCompleted)
        try container.encodeIfPresent(progressTotal, forKey: .progressTotal)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(storage, forKey: .storage)
        try container.encodeIfPresent(compute, forKey: .compute)
        try container.encodeIfPresent(remoteSessionID, forKey: .remoteSessionID)
        try container.encodeIfPresent(remoteGenerationID, forKey: .remoteGenerationID)
        try container.encodeIfPresent(clientRequestID, forKey: .clientRequestID)
        try container.encodeIfPresent(localCachePath, forKey: .localCachePath)
        try container.encode(cloudSyncRevision, forKey: .cloudSyncRevision)
        try container.encodeIfPresent(cloudSyncState, forKey: .cloudSyncState)
        try container.encodeIfPresent(remoteResultVersion, forKey: .remoteResultVersion)
        try container.encodeIfPresent(pendingCloudSyncError, forKey: .pendingCloudSyncError)
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

enum WorkbenchMediaImportOrigin: String, Equatable, Sendable {
    case files
    case netVideo
    case recording
}

enum WorkbenchSessionSource: String, Sendable {
    case media
    case standaloneDub
}

enum WorkbenchSessionType: String, Sendable {
    case upload
    case netVideo = "net_video"
    case record
    case live
    case meetingRecord = "meeting_record"
    case googleMeet = "google_meet"
    case dub

    init(sourceType: String?, isDub: Bool = false) {
        if isDub {
            self = .dub
            return
        }
        let normalized = sourceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = WorkbenchSessionType(rawValue: normalized ?? "") ?? .upload
    }

    var label: String {
        switch self {
        case .upload: "Upload Transcribe"
        case .netVideo: "Net Video Transcribe"
        case .record: "Record Transcribe"
        case .live: "Live Transcribe"
        case .meetingRecord: "Meeting"
        case .googleMeet: "Google Meet"
        case .dub: "AI Voiceover"
        }
    }

    var navGlyph: WorkbenchNavGlyph {
        switch self {
        case .upload: .captions
        case .netVideo: .squarePlay
        case .record: .system("mic")
        case .live: .system("dot.radiowaves.left.and.right")
        case .meetingRecord, .googleMeet: .meetBot
        case .dub: .voiceover
        }
    }

    /// Shown in Recent session metadata. Upload omits a type label (icon is enough).
    var showsRecentListLabel: Bool {
        self != .upload
    }
}

enum WorkbenchNetVideoPlatform: String, Sendable {
    case youtube
    case gettr
    case ganjingworld
    case x
    case unknown
}

struct WorkbenchNetVideoSource: Sendable, Equatable {
    let sourceURL: URL
    let embedURL: URL?
    let playbackURL: URL?
    let platform: WorkbenchNetVideoPlatform
    let title: String?
}

struct WorkbenchSession: Identifiable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var state: WorkbenchJobState
    var source: WorkbenchSessionSource
    var sessionType: WorkbenchSessionType
    var transcriptionID: UUID?
    var dubID: UUID?
    var sourceURL: URL?
    var outputURL: URL?
    var durationHint: Double? = nil
    var transcript: TranscriptionResult?
    var subtitleTrack: SubtitleTrack?
    var translationTracks: [WorkbenchTranslationTrack]
    var selectedTranslationLanguageCode: String?
    var summaryMarkdown: String?
    var summaryTemplateID: String?
    var summaryTemplateName: String?
    var summaryState: WorkbenchJobState?
    var summaryErrorMessage: String?
    var sessionTag: String?
    var dubTranscript: TranscriptionResult?
    var dubSubtitleTrack: SubtitleTrack?
    var dubSegments: [DubRenderedSegment]
    var storage: TaskStorageDestination = .local
    var compute: TaskComputeDestination = .local
    var remoteSessionID: UUID?
    var cloudSyncState: DubCloudSyncState = .none
    var cloudSyncError: String?
    var remoteSourcePlaybackURL: URL? = nil
    var remoteSourceHasVideo: Bool? = nil
    var remoteSourcePosterURL: URL? = nil
    var netVideoSource: WorkbenchNetVideoSource? = nil

    var isRemoteOnly: Bool {
        transcriptionID == nil && dubID == nil && remoteSessionID != nil
    }

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
        return [durationHint, transcriptEnd, dubEnd].compactMap { $0 }.max()
    }

    var hasDub: Bool { outputURL != nil || source == .standaloneDub || !dubSegments.isEmpty }
}

private struct WorkbenchSnapshot: Codable, Sendable {
    var schemaVersion: Int? = 6
    var transcriptions: [WorkbenchTranscriptionJob]
    var dubs: [WorkbenchDubJob]
}

private struct TranscriptionCloudEditableProjection: Equatable {
    var result: TranscriptionResult?
    var editedText: String
    var subtitleTrack: SubtitleTrack?
    var translationTracks: [WorkbenchTranslationTrack]
    var customTitle: String?
    var summaryMarkdown: String?
    var summaryTemplateID: String?
    var summaryTemplateName: String?
    var summaryTemplateUserEdition: String?
    var sessionTag: String?

    init(_ job: WorkbenchTranscriptionJob) {
        result = job.result
        editedText = job.editedText
        subtitleTrack = job.subtitleTrack
        translationTracks = job.translationTracks
        customTitle = job.customTitle
        summaryMarkdown = job.summaryMarkdown
        summaryTemplateID = job.summaryTemplateID
        summaryTemplateName = job.summaryTemplateName
        summaryTemplateUserEdition = job.summaryTemplateUserEdition
        sessionTag = job.sessionTag
    }
}

private struct DubCloudEditableProjection: Equatable {
    var script: String
    var segments: [DubSegmentPayload]?
    var renderedSegments: [DubRenderedSegment]?
    var alignedTranscript: TranscriptionResult?
    var subtitleTrack: SubtitleTrack?
    var title: String
    var summaryMarkdown: String?
    var summaryTemplateID: String?
    var summaryTemplateName: String?
    var summaryTemplateUserEdition: String?
    var sessionTag: String?

    init(_ job: WorkbenchDubJob) {
        script = job.script
        segments = job.segments
        renderedSegments = job.renderedSegments
        alignedTranscript = job.alignedTranscript
        subtitleTrack = job.subtitleTrack
        title = job.title
        summaryMarkdown = job.summaryMarkdown
        summaryTemplateID = job.summaryTemplateID
        summaryTemplateName = job.summaryTemplateName
        summaryTemplateUserEdition = job.summaryTemplateUserEdition
        sessionTag = job.sessionTag
    }
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
            steps.append(.prepareSubtitles(SubtitleProcessingPayload()))
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
            steps.append(.prepareSubtitles(SubtitleProcessingPayload()))
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
            steps.append(.prepareSubtitles(SubtitleProcessingPayload()))
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
        do {
            return try JSONDecoder().decode(WorkbenchSnapshot.self, from: data)
        } catch {
            Log.project.error("workbench load failed: \(error.localizedDescription)")
            return nil
        }
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
    private let taskAccess: any TranscriptionTaskAccessing
    private let dubTaskAccess: any DubTaskAccessing
    private let cloudSessionSync: any CloudSessionSyncing
    private let voxellaAPI: VoxellaAPIClient

    private struct StagedTranscriptionArtifacts {
        var rawResult: TranscriptionResult?
        var preparedResult: TranscriptionResult?
        var subtitleTrack: SubtitleTrack?
        var translationTracks: [WorkbenchTranslationTrack] = []
        var diarizationDiagnostics: DiarizationDiagnostics?
        var alignmentDiagnostics: TranscriptionAlignmentDiagnostics?
        var processedSourcePath: String?
        var cloudUploadPath: String?

        mutating func upsertTranslation(_ track: SubtitleTrack, languageCode: String) {
            let normalizedCode = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCode.isEmpty else { return }
            let item = WorkbenchTranslationTrack(languageCode: normalizedCode, track: track)
            if let index = translationTracks.firstIndex(where: {
                $0.languageCode.caseInsensitiveCompare(normalizedCode) == .orderedSame
            }) {
                translationTracks[index] = item
            } else {
                translationTracks.append(item)
            }
        }

        var completedArtifacts: CompletedTranscriptionArtifacts? {
            guard let rawResult else { return nil }
            return CompletedTranscriptionArtifacts(
                rawResult: rawResult,
                result: preparedResult ?? rawResult,
                subtitleTrack: subtitleTrack,
                translationTracks: translationTracks,
                diarizationDiagnostics: diarizationDiagnostics,
                alignmentDiagnostics: alignmentDiagnostics,
                processedSourcePath: processedSourcePath
            )
        }
    }

    private struct MaterializedTranscriptionInput: Sendable {
        let sourceURL: URL
        let usesExtractedClip: Bool
    }

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
    private var stagedTranscriptions: [UUID: StagedTranscriptionArtifacts] = [:]
    private var summaryTaskIDs: Set<UUID> = []
    private var cloudSyncTasks: [UUID: Task<Void, Never>] = [:]
    private var cloudSyncGenerations: [UUID: Int] = [:]
    private var deletingSessionIDs: Set<UUID> = []
    /// FIFO of transcription job IDs waiting for the single local ASR slot.
    private var pendingTranscriptionQueue: [UUID] = []
    private var activeQueuedTranscriptionID: UUID?
    private let persistence: WorkbenchPersistence
    private var hasHydrated = false
    private var pendingNewDubDraft = false
    private var saveRequestedBeforeHydration = false
    private var saveRevision = 0
    private(set) var remoteSessions: [UUID: WorkbenchSession] = [:]
    private(set) var isLoadingRemoteSessions = false
    private(set) var remoteSessionsError: String?
    private(set) var remoteSessionLoadingID: UUID?
    private var remoteSessionLoadTask: Task<Void, Never>?
    private var remoteSessionsLoadGeneration = UUID()

    init(
        taskAccess: any TranscriptionTaskAccessing = RoutedTranscriptionTaskAccess(),
        dubTaskAccess: any DubTaskAccessing = RoutedDubTaskAccess(),
        cloudSessionSync: any CloudSessionSyncing = VoxellaCloudSessionSync(),
        voxellaAPI: VoxellaAPIClient = .shared
    ) {
        self.taskAccess = taskAccess
        self.dubTaskAccess = dubTaskAccess
        self.cloudSessionSync = cloudSessionSync
        self.voxellaAPI = voxellaAPI
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
                sessionType: job.netVideoSourceURL == nil ? .upload : .netVideo,
                transcriptionID: job.id,
                dubID: dub?.id,
                sourceURL: job.sourceURL,
                outputURL: dub?.outputURL,
                transcript: job.result,
                subtitleTrack: job.subtitleTrack,
                translationTracks: job.translationTracks,
                selectedTranslationLanguageCode: job.selectedTranslationLanguageCode,
                summaryMarkdown: job.summaryMarkdown,
                summaryTemplateID: job.summaryTemplateID,
                summaryTemplateName: job.summaryTemplateName,
                summaryState: job.summaryState,
                summaryErrorMessage: job.summaryErrorMessage,
                sessionTag: job.sessionTag,
                dubTranscript: dub?.alignedTranscript,
                dubSubtitleTrack: dub?.renderedSubtitleTrack,
                dubSegments: dub?.renderedSegments ?? [],
                storage: dub?.resolvedStorage ?? job.storage,
                compute: dub?.resolvedCompute ?? job.compute,
                remoteSessionID: dub?.remoteSessionID ?? job.remoteSessionID,
                cloudSyncState: Self.combinedCloudSyncState(
                    primary: job.resolvedCloudSyncState,
                    secondary: dub?.resolvedCloudSyncState
                ),
                cloudSyncError: dub?.pendingCloudSyncError ?? job.pendingCloudSyncError,
                netVideoSource: Self.localNetVideoSource(from: job)
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
                sessionType: .dub,
                transcriptionID: nil,
                dubID: job.id,
                sourceURL: nil,
                outputURL: job.outputURL,
                transcript: nil,
                subtitleTrack: nil,
                translationTracks: [],
                selectedTranslationLanguageCode: nil,
                summaryMarkdown: job.summaryMarkdown,
                summaryTemplateID: job.summaryTemplateID,
                summaryTemplateName: job.summaryTemplateName,
                summaryState: job.summaryState,
                summaryErrorMessage: job.summaryErrorMessage,
                sessionTag: job.sessionTag,
                dubTranscript: job.alignedTranscript,
                dubSubtitleTrack: job.renderedSubtitleTrack,
                dubSegments: job.renderedSegments ?? Self.fallbackDubSegments(for: job),
                storage: job.resolvedStorage,
                compute: job.resolvedCompute,
                remoteSessionID: job.remoteSessionID,
                cloudSyncState: job.resolvedCloudSyncState,
                cloudSyncError: job.pendingCloudSyncError
            )
        }
        let localSessions = transcriptSessions + standaloneDubs
        let localRemoteIDs = Set(localSessions.compactMap(\.remoteSessionID))
        let cloudSessions = AccountService.shared.isSignedIn
            ? remoteSessions.values.filter { !localRemoteIDs.contains($0.id) }
            : []
        return (localSessions + cloudSessions).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var selectedSession: WorkbenchSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func openSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        remoteSessionLoadTask?.cancel()
        remoteSessionLoadTask = nil
        remoteSessionLoadingID = nil
        selectedSessionID = id

        if session.isRemoteOnly {
            route = .session
            loadRemoteSession(id)
            return
        }

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

    func refreshRemoteSessions() async {
        guard AccountService.shared.isSignedIn else {
            remoteSessions = [:]
            remoteSessionsError = nil
            return
        }

        remoteSessionsLoadGeneration = UUID()
        let generation = remoteSessionsLoadGeneration
        isLoadingRemoteSessions = true
        remoteSessionsError = nil
        defer {
            if remoteSessionsLoadGeneration == generation {
                isLoadingRemoteSessions = false
            }
        }

        do {
            var summaries: [VoxellaSessionDetail] = []
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                try Task.checkCancellation()
                let page = try await voxellaAPI.listSessions(cursor: cursor)
                summaries.append(contentsOf: page.items)
                guard let next = page.nextCursor,
                      !next.isEmpty,
                      next != cursor,
                      seenCursors.insert(next).inserted else {
                    cursor = nil
                    break
                }
                cursor = next
            } while cursor != nil

            guard remoteSessionsLoadGeneration == generation, !Task.isCancelled else { return }
            let localRemoteIDs = Set(
                transcriptions.compactMap(\.remoteSessionID)
                    + dubs.compactMap(\.remoteSessionID)
            )
            remoteSessions = Dictionary(
                uniqueKeysWithValues: summaries
                    .filter { !localRemoteIDs.contains($0.id) }
                    .map { ($0.id, Self.remoteSession(from: $0)) }
            )
        } catch is CancellationError {
        } catch VoxellaAPIError.cancelled {
        } catch {
            guard remoteSessionsLoadGeneration == generation, !Task.isCancelled else { return }
            remoteSessionsError = error.localizedDescription
            Log.account.warning(
                "remote recent sessions load failed error=\(error.localizedDescription)",
                telemetry: "Remote recent sessions load failed"
            )
        }
    }

    func clearRemoteSessions() {
        remoteSessionsLoadGeneration = UUID()
        remoteSessionLoadTask?.cancel()
        remoteSessionLoadTask = nil
        remoteSessions = [:]
        remoteSessionsError = nil
        isLoadingRemoteSessions = false
        remoteSessionLoadingID = nil
    }

    private func loadRemoteSession(_ id: UUID) {
        remoteSessionLoadTask?.cancel()
        remoteSessionLoadingID = id
        remoteSessionLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rendering = try await self.voxellaAPI.sessionRenderingData(id)
                try Task.checkCancellation()
                guard self.selectedSessionID == id else { return }
                self.remoteSessions[id] = Self.remoteSession(
                    from: rendering.detail,
                    transcriptSegments: rendering.transcriptSegments,
                    subtitleCues: rendering.subtitleCues,
                    mediaPlaybackURL: rendering.mediaPlaybackURL,
                    mediaHasVideo: rendering.mediaHasVideo
                )
                self.remoteSessionLoadingID = nil
            } catch is CancellationError {
            } catch VoxellaAPIError.cancelled {
            } catch {
                guard self.selectedSessionID == id else { return }
                self.remoteSessionLoadingID = nil
                self.remoteSessionsError = error.localizedDescription
                WorkbenchTipCenter.shared.show(
                    "Could not open the VoxStudio session: \(error.localizedDescription)",
                    kind: .error,
                    id: "remote-session.open.failed.\(id.uuidString)"
                )
            }
        }
    }

    private func needsSummary(
        markdown: String?,
        state: WorkbenchJobState?
    ) -> Bool {
        Self.summaryNeedsGeneration(markdown: markdown, state: state)
    }

    nonisolated static func summaryNeedsGeneration(
        markdown: String?,
        state: WorkbenchJobState?
    ) -> Bool {
        guard state != .completed else { return false }
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
        remoteSessionLoadTask?.cancel()
        remoteSessionLoadTask = nil
        remoteSessionLoadingID = nil
        selectedSessionID = nil
        route = .recent
    }

    func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if transcriptions.contains(where: { $0.id == id }) {
            updateTranscription(id) { job in
                job.customTitle = trimmed == job.displayName ? nil : trimmed
            }
            return
        }
        if dubs.contains(where: { $0.id == id }) {
            updateDub(id) { job in
                job.title = SessionTitlePolicy.normalizedUserTitle(trimmed) ?? ""
            }
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
    var pendingNetVideoSource: WorkbenchNetVideoSource?
    var pendingMediaImportOrigin: WorkbenchMediaImportOrigin = .files
    /// Open the transcribe empty state on the Net Video entry instead of file import.
    var preferNetVideoEntry = false
    var preferRecordEntry = false

    func stageMediaImport(_ urls: [URL]) {
        transcriptionAdmissionError = nil
        pendingNetVideoSource = nil
        pendingMediaImportOrigin = .files
        pendingMediaImportURLs = urls
        selectedTranscriptionID = nil
        route = .transcribe
    }

    func stageNetVideoImport(
        mediaURL: URL,
        sourceURL: URL,
        videoID: String,
        title: String?
    ) {
        transcriptionAdmissionError = nil
        pendingNetVideoSource = WorkbenchNetVideoSource(
            sourceURL: sourceURL,
            embedURL: Self.youtubeEmbedURL(for: sourceURL),
            playbackURL: nil,
            platform: .youtube,
            title: title
        )
        pendingMediaImportOrigin = .netVideo
        pendingMediaImportURLs = [mediaURL]
        selectedTranscriptionID = nil
        route = .transcribe
    }

    func stageRecordedMedia(_ url: URL) {
        transcriptionAdmissionError = nil
        pendingNetVideoSource = nil
        pendingMediaImportOrigin = .recording
        pendingMediaImportURLs = [url]
        selectedTranscriptionID = nil
        preferRecordEntry = true
        route = .transcribe
    }

    func clearPendingMediaImport() {
        pendingMediaImportURLs = []
        pendingNetVideoSource = nil
        pendingMediaImportOrigin = .files
    }

    func discardPendingMediaImport() {
        for url in pendingMediaImportURLs {
            Self.removeManagedClipMediaIfNeeded(url)
        }
        pendingMediaImportURLs = []
        pendingNetVideoSource = nil
        pendingMediaImportOrigin = .files
    }

    func showNetVideoImport() {
        transcriptionAdmissionError = nil
        preferNetVideoEntry = true
        selectedTranscriptionID = nil
        route = .transcribe
    }

    func showRecordImport() {
        transcriptionAdmissionError = nil
        preferRecordEntry = true
        selectedTranscriptionID = nil
        route = .transcribe
    }

    func consumeNetVideoEntryPreference() -> Bool {
        defer { preferNetVideoEntry = false }
        return preferNetVideoEntry
    }

    func consumeRecordEntryPreference() -> Bool {
        defer { preferRecordEntry = false }
        return preferRecordEntry
    }

    nonisolated static var netVideoMediaDirectory: URL {
        dataDirectory.appendingPathComponent("NetVideo", isDirectory: true)
    }

    nonisolated static var recordingMediaDirectory: URL {
        dataDirectory.appendingPathComponent("Recordings", isDirectory: true)
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
        openSessionWhenDone: Bool = true,
        netVideoSource: WorkbenchNetVideoSource? = nil
    ) -> UUID? {
        beginTranscriptions(
            sourceURLs: sourceURLs,
            submission: TranscriptionSubmission(options: options, placement: .localDefault),
            openSessionWhenDone: openSessionWhenDone,
            netVideoSource: netVideoSource
        )
    }

    @discardableResult
    func beginTranscriptions(
        sourceURLs: [URL],
        submission: TranscriptionSubmission,
        openSessionWhenDone: Bool = true,
        netVideoSource: WorkbenchNetVideoSource? = nil,
        isRecordedCapture: Bool = false
    ) -> UUID? {
        transcriptionAdmissionError = nil
        if submission.placement.compute == .local {
            do {
                try LocalTranscriptionResourcePolicy.admit(sourceURLs)
            } catch {
                transcriptionAdmissionError = error.localizedDescription
                return nil
            }
        }

        let batchID = UUID()
        var created: [WorkbenchTranscriptionJob] = []
        created.reserveCapacity(sourceURLs.count)
        for url in sourceURLs {
            var job = WorkbenchTranscriptionJob(sourcePath: url.path)
            if sourceURLs.count == 1, let netVideoSource, netVideoSource.platform == .youtube {
                job.netVideoSourceURL = netVideoSource.sourceURL.absoluteString
                job.netVideoVideoID = Self.youtubeVideoID(for: netVideoSource.sourceURL)
                job.netVideoPlatform = netVideoSource.platform.rawValue
            }
            job.languageCode = submission.options.languageCode
            job.speakerCount = submission.options.speakerCount
            job.clipStartMs = sourceURLs.count == 1 ? submission.options.clipStartMs : nil
            job.clipEndMs = sourceURLs.count == 1 ? submission.options.clipEndMs : nil
            job.useLLMSubtitleProcessing = submission.options.useLLMSubtitleProcessing
            job.targetLanguageCode = submission.options.normalizedTargetLanguageCode
            if sourceURLs.count == 1 {
                job.customTitle = SessionTitlePolicy.normalizedUserTitle(submission.options.customTitle)
            }
            job.batchID = batchID
            job.placement = submission.placement
            job.isRecordedCapture = isRecordedCapture
            job.progressMessage = submission.placement.compute == .local
                ? "Queued"
                : "Queued for VoxStudio Cloud"
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
        guard let job = transcriptions.first(where: { $0.id == id }) else { return }
        if job.compute == .cloud {
            selectedTranscriptionID = id
            updateTranscription(id) {
                if $0.state == .ready {
                    $0.progressMessage = "Connecting to VoxStudio Cloud…"
                }
            }
            startTranscriptionPipeline(id)
            return
        }
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
        job.placement = latest?.placement ?? .localDefault
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
        guard transcriptions.contains(where: { $0.id == id }) else { return }
        beginRemoteFirstDeletion(
            transcriptionIDs: [id],
            dubIDs: [],
            selectedSessionID: selectedSessionID == id ? id : nil
        )
    }

    func deleteDub(_ id: UUID) {
        guard dubs.contains(where: { $0.id == id }) else { return }
        beginRemoteFirstDeletion(
            transcriptionIDs: [],
            dubIDs: [id],
            selectedSessionID: selectedSessionID == id ? id : nil
        )
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

        beginRemoteFirstDeletion(
            transcriptionIDs: session.transcriptionID.map { [$0] } ?? [],
            dubIDs: relatedDubIDs,
            selectedSessionID: id
        )
    }

    private func beginRemoteFirstDeletion(
        transcriptionIDs: [UUID],
        dubIDs: [UUID],
        selectedSessionID: UUID? = nil
    ) {
        let transcriptionIDs = Array(Set(transcriptionIDs))
        let dubIDs = Array(Set(dubIDs))
        let localIDs = Set(transcriptionIDs).union(dubIDs)
        guard !localIDs.isEmpty,
              localIDs.isDisjoint(with: deletingSessionIDs) else { return }

        deletingSessionIDs.formUnion(localIDs)
        let flowIDs = localIDs.filter { flowTasks[$0] != nil }
        for id in flowIDs {
            flowTasks[id]?.cancel()
        }

        Task { [weak self] in
            guard let self else { return }
            for id in flowIDs {
                if let flowTask = flowTasks[id] {
                    await flowTask.value
                }
            }

            let remoteIDs = remoteSessionIDs(
                transcriptionIDs: transcriptionIDs,
                dubIDs: dubIDs
            )
            do {
                for remoteID in remoteIDs {
                    try await cloudSessionSync.delete(remoteSessionID: remoteID)
                }
            } catch {
                deletingSessionIDs.subtract(localIDs)
                WorkbenchTipCenter.shared.show(
                    "Cloud deletion failed. The local session was kept so you can retry: \(error.localizedDescription)",
                    kind: .error,
                    id: "session.delete.cloud.\(selectedSessionID?.uuidString ?? localIDs.first!.uuidString)"
                )
                Log.project.warning(
                    "cloud session deletion failed ids=\(remoteIDs.map(\.uuidString).joined(separator: ",")) "
                        + "error=\(error.localizedDescription)"
                )
                return
            }

            for id in transcriptionIDs {
                removeTranscriptionLocally(id)
            }
            for id in dubIDs {
                removeDubLocally(id)
            }
            deletingSessionIDs.subtract(localIDs)
            if let selectedSessionID,
               self.selectedSessionID == selectedSessionID {
                self.selectedSessionID = nil
                if self.route == .session { self.route = .recent }
            }
        }
    }

    private func remoteSessionIDs(
        transcriptionIDs: [UUID],
        dubIDs: [UUID]
    ) -> [UUID] {
        var result: Set<UUID> = []
        for id in transcriptionIDs {
            guard let job = transcriptions.first(where: { $0.id == id }),
                  job.placement.storage == .cloud,
                  let remoteSessionID = job.remoteSessionID else { continue }
            result.insert(remoteSessionID)
        }
        for id in dubIDs {
            guard let job = dubs.first(where: { $0.id == id }),
                  job.placement.storage == .cloud,
                  let remoteSessionID = job.remoteSessionID else { continue }
            result.insert(remoteSessionID)
        }
        return result.sorted { $0.uuidString < $1.uuidString }
    }

    private func removeTranscriptionLocally(_ id: UUID) {
        pendingTranscriptionQueue.removeAll { $0 == id }
        if activeQueuedTranscriptionID == id { activeQueuedTranscriptionID = nil }
        cloudSyncTasks[id]?.cancel()
        cloudSyncTasks[id] = nil
        cloudSyncGenerations[id, default: 0] += 1
        discardStagedTranscription(id)
        if let job = transcriptions.first(where: { $0.id == id }) {
            Self.removeManagedClipMediaIfNeeded(job.sourceURL)
        }
        transcriptions.removeAll { $0.id == id }
        SessionIndexCoordinator.shared.remove(id)
        if selectedTranscriptionID == id { selectedTranscriptionID = transcriptions.first?.id }
        if var batch = activeTranscriptionBatch {
            batch.jobIDs.removeAll { $0 == id }
            activeTranscriptionBatch = batch.jobIDs.isEmpty ? nil : batch
        }
        save()
        drainTranscriptionQueue()
    }

    private func removeDubLocally(_ id: UUID) {
        cloudSyncTasks[id]?.cancel()
        cloudSyncTasks[id] = nil
        cloudSyncGenerations[id, default: 0] += 1
        dubs.removeAll { $0.id == id }
        if selectedDubID == id { selectedDubID = dubs.first?.id }
        save()
    }

    func updateTranscription(_ id: UUID, _ mutate: (inout WorkbenchTranscriptionJob) -> Void) {
        guard let index = transcriptions.firstIndex(where: { $0.id == id }) else { return }
        let before = TranscriptionCloudEditableProjection(transcriptions[index])
        mutate(&transcriptions[index])
        transcriptions[index].modifiedAt = Date()
        let changed = before != TranscriptionCloudEditableProjection(transcriptions[index])
        if changed {
            transcriptions[index].cloudSyncRevision = Self.nextCloudSyncRevision(
                transcriptions[index].cloudSyncRevision
            )
        }
        save()
        if changed {
            scheduleCloudSync(forTranscription: id)
        }
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
        if let job = transcriptions.first(where: { $0.id == id }),
           job.state == .completed {
            SessionIndexCoordinator.shared.patchSpeakers(job)
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

    func updateSessionCueTiming(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        start: Double,
        end: Double
    ) {
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            track.updatingCueTiming(id: cueID, start: start, end: end)
        }
    }

    func adjustSessionCueTiming(
        sessionID: UUID,
        scope: SessionCueScope,
        cueID: Int,
        startDelta: Double,
        endDelta: Double
    ) {
        guard startDelta != 0 || endDelta != 0 else { return }
        mutateSessionCueTrack(sessionID: sessionID, scope: scope) { track in
            guard let cue = track.cues.first(where: { $0.id == cueID }) else { return nil }
            return track.updatingCueTiming(
                id: cueID,
                start: cue.start + startDelta,
                end: cue.end + endDelta
            )
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
        let before = DubCloudEditableProjection(dubs[index])
        mutate(&dubs[index])
        dubs[index].modifiedAt = Date()
        let changed = before != DubCloudEditableProjection(dubs[index])
        if changed {
            dubs[index].cloudSyncRevision = Self.nextCloudSyncRevision(dubs[index].cloudSyncRevision)
        }
        save()
        if changed {
            scheduleCloudSync(forDub: id)
        }
    }

    func retryCloudSessionSync(_ sessionID: UUID) {
        var transcriptionIDs: Set<UUID> = []
        var dubIDs: Set<UUID> = []
        if let transcriptionID = transcriptions.first(where: { $0.id == sessionID })?.id {
            transcriptionIDs.insert(transcriptionID)
        }
        if let dubID = dubs.first(where: { $0.id == sessionID })?.id {
            dubIDs.insert(dubID)
        }
        if let session = sessions.first(where: { $0.id == sessionID }) {
            if let transcriptionID = session.transcriptionID {
                transcriptionIDs.insert(transcriptionID)
            }
            if let dubID = session.dubID {
                dubIDs.insert(dubID)
            }
        }
        for transcriptionID in transcriptionIDs {
            scheduleCloudSync(forTranscription: transcriptionID)
        }
        for dubID in dubIDs {
            scheduleCloudSync(forDub: dubID)
        }
    }

    private func scheduleCloudSync(forTranscription id: UUID) {
        guard hasHydrated,
              let job = transcriptions.first(where: { $0.id == id }),
              TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
              job.state == .completed,
              job.remoteSessionID != nil,
              job.result != nil else {
            return
        }

        let generation = cloudSyncGenerations[id, default: 0] + 1
        cloudSyncGenerations[id] = generation
        cloudSyncTasks[id]?.cancel()
        if let index = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[index].cloudSyncState = .pending
            transcriptions[index].pendingCloudSyncError = nil
            transcriptions[index].progressMessage = "Saving changes to VoxStudio Cloud…"
            save()
        }

        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                guard let self,
                      self.cloudSyncGenerations[id] == generation,
                      let snapshot = self.transcriptionCloudSnapshot(id) else {
                    return
                }
                try await self.cloudSessionSync.sync(snapshot)
                try Task.checkCancellation()
                guard self.cloudSyncGenerations[id] == generation,
                      self.transcriptions.contains(where: { $0.id == id }) else {
                    return
                }
                self.updateTranscription(id) { job in
                    job.cloudSyncState = .completed
                    job.pendingCloudSyncError = nil
                    job.progressMessage = "Changes saved to VoxStudio Cloud"
                }
                self.cloudSyncTasks[id] = nil
            } catch is CancellationError {
                // A newer edit owns the next sync attempt.
            } catch {
                guard let self,
                      self.cloudSyncGenerations[id] == generation,
                      self.transcriptions.contains(where: { $0.id == id }) else {
                    return
                }
                self.updateTranscription(id) { job in
                    job.cloudSyncState = .pending
                    job.pendingCloudSyncError = error.localizedDescription
                    job.progressMessage = "Changes saved locally · cloud sync pending"
                }
                self.cloudSyncTasks[id] = nil
                WorkbenchTipCenter.shared.show(
                    "Changes saved locally, but the cloud update failed: \(error.localizedDescription)",
                    kind: .error,
                    id: "session.cloud-sync.\(id.uuidString)"
                )
                Log.project.warning(
                    "transcription cloud edit sync failed id=\(id.uuidString) error=\(error.localizedDescription)"
                )
            }
        }
        cloudSyncTasks[id] = task
    }

    private func scheduleCloudSync(forDub id: UUID) {
        guard hasHydrated,
              let job = dubs.first(where: { $0.id == id }),
              TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
              job.state == .completed,
              job.remoteSessionID != nil,
              dubTranscriptForCloudSync(job) != nil else {
            return
        }

        let generation = cloudSyncGenerations[id, default: 0] + 1
        cloudSyncGenerations[id] = generation
        cloudSyncTasks[id]?.cancel()
        if let index = dubs.firstIndex(where: { $0.id == id }) {
            dubs[index].cloudSyncState = .pending
            dubs[index].pendingCloudSyncError = nil
            dubs[index].progressMessage = "Saving changes to VoxStudio Cloud…"
            save()
        }

        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                guard let self,
                      self.cloudSyncGenerations[id] == generation,
                      let snapshot = self.dubCloudSnapshot(id) else {
                    return
                }
                try await self.cloudSessionSync.sync(snapshot)
                try Task.checkCancellation()
                guard self.cloudSyncGenerations[id] == generation,
                      self.dubs.contains(where: { $0.id == id }) else {
                    return
                }
                self.updateDub(id) { job in
                    job.cloudSyncState = .completed
                    job.pendingCloudSyncError = nil
                    job.progressMessage = "Changes saved to VoxStudio Cloud"
                }
                self.cloudSyncTasks[id] = nil
            } catch is CancellationError {
                // A newer edit owns the next sync attempt.
            } catch {
                guard let self,
                      self.cloudSyncGenerations[id] == generation,
                      self.dubs.contains(where: { $0.id == id }) else {
                    return
                }
                self.updateDub(id) { job in
                    job.cloudSyncState = .pending
                    job.pendingCloudSyncError = error.localizedDescription
                    job.progressMessage = "Changes saved locally · cloud sync pending"
                }
                self.cloudSyncTasks[id] = nil
                WorkbenchTipCenter.shared.show(
                    "Changes saved locally, but the cloud update failed: \(error.localizedDescription)",
                    kind: .error,
                    id: "session.cloud-sync.\(id.uuidString)"
                )
                Log.project.warning(
                    "dub cloud edit sync failed id=\(id.uuidString) error=\(error.localizedDescription)"
                )
            }
        }
        cloudSyncTasks[id] = task
    }

    private func transcriptionCloudSnapshot(_ id: UUID) -> CloudSessionSyncSnapshot? {
        guard let job = transcriptions.first(where: { $0.id == id }),
              let remoteSessionID = job.remoteSessionID,
              let sourceResult = job.result else {
            return nil
        }
        var result = sourceResult
        if job.editedText != sourceResult.text {
            result = TranscriptionResult(
                text: job.editedText,
                language: sourceResult.language,
                words: job.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? []
                    : sourceResult.words,
                segments: job.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? []
                    : sourceResult.segments
            )
        }
        return CloudSessionSyncSnapshot(
            jobID: job.id,
            remoteSessionID: remoteSessionID,
            contentKind: .transcription,
            revision: job.cloudSyncRevision,
            sourceLanguage: result.language ?? job.languageCode,
            result: result,
            subtitleTrack: job.subtitleTrack ?? SubtitleTrack.fromTranscript(result),
            translationTracks: job.translationTracks,
            dubSegments: [],
            title: job.sessionTitle,
            summary: job.summaryMarkdown,
            summaryTemplateID: job.summaryTemplateID,
            summaryTemplateName: job.summaryTemplateName,
            summaryTemplateUserEdition: job.summaryTemplateUserEdition,
            sessionTag: job.sessionTag
        )
    }

    private func dubCloudSnapshot(_ id: UUID) -> CloudSessionSyncSnapshot? {
        guard let job = dubs.first(where: { $0.id == id }),
              let remoteSessionID = job.remoteSessionID,
              let result = dubTranscriptForCloudSync(job) else {
            return nil
        }
        return CloudSessionSyncSnapshot(
            jobID: job.id,
            remoteSessionID: remoteSessionID,
            contentKind: .dub,
            revision: job.cloudSyncRevision,
            sourceLanguage: result.language ?? (job.language == "auto" ? nil : job.language),
            result: result,
            subtitleTrack: job.subtitleTrack ?? job.renderedSubtitleTrack,
            translationTracks: [],
            dubSegments: cloudDubSegments(for: job),
            title: SessionTitlePolicy.normalizedUserTitle(job.title),
            summary: job.summaryMarkdown,
            summaryTemplateID: job.summaryTemplateID,
            summaryTemplateName: job.summaryTemplateName,
            summaryTemplateUserEdition: job.summaryTemplateUserEdition,
            sessionTag: job.sessionTag
        )
    }

    private func dubTranscriptForCloudSync(_ job: WorkbenchDubJob) -> TranscriptionResult? {
        let editableSegments = cloudDubSegments(for: job).compactMap { segment -> TranscriptionSegment? in
            guard let start = segment.start, let end = segment.end,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return TranscriptionSegment(
                text: segment.text,
                start: start,
                end: end,
                speaker: segment.speaker
            )
        }
        if !editableSegments.isEmpty {
            return TranscriptionResult(
                text: job.script,
                language: job.language == "auto" ? nil : job.language,
                words: job.alignedTranscript?.words ?? [],
                segments: editableSegments
            ).aggregatingSegments()
        }
        if let aligned = job.alignedTranscript {
            return aligned.aggregatingSegments()
        }
        if let track = job.subtitleTrack ?? job.renderedSubtitleTrack {
            return track.asTranscriptionResult().aggregatingSegments()
        }
        let segments = cloudDubSegments(for: job).compactMap { segment -> TranscriptionSegment? in
            guard let start = segment.start, let end = segment.end,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return TranscriptionSegment(
                text: segment.text,
                start: start,
                end: end,
                speaker: segment.speaker
            )
        }
        guard !segments.isEmpty || !job.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TranscriptionResult(
            text: job.script,
            language: job.language == "auto" ? nil : job.language,
            words: [],
            segments: segments
        ).aggregatingSegments()
    }

    private func cloudDubSegments(for job: WorkbenchDubJob) -> [DubSegmentPayload] {
        if let segments = job.segments {
            guard !segments.isEmpty else { return [] }
            if let renderedSegments = job.renderedSegments, !renderedSegments.isEmpty {
                let renderedByIndex = Dictionary(
                    renderedSegments.map { ($0.index, $0) },
                    uniquingKeysWith: { current, _ in current }
                )
                return segments.map { segment in
                    guard let rendered = renderedByIndex[segment.index] else { return segment }
                    var enriched = segment
                    enriched.start = segment.start ?? rendered.start
                    enriched.end = segment.end ?? rendered.end
                    return enriched
                }
            }
            return segments
        }
        if let renderedSegments = job.renderedSegments, !renderedSegments.isEmpty {
            return renderedSegments.map {
                DubSegmentPayload(
                    index: $0.index,
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speaker: $0.speaker,
                    sourceSubtitleID: $0.sourceSubtitleID
                )
            }
        }
        let text = job.script.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [DubSegmentPayload(index: 0, text: text)]
    }

    func runTranscription(_ id: UUID) {
        guard let job = transcriptions.first(where: { $0.id == id }) else { return }
        guard flowTasks[id] == nil,
              job.state != .running,
              job.state != .cancelling else { return }
        if job.state == .completed || job.state == .cancelled || job.state == .failed {
            updateTranscription(id) {
                $0.state = .ready
                $0.progress = 0
                $0.progressMessage = job.compute == .cloud
                    ? "Queued for VoxStudio Cloud"
                    : "Queued"
                $0.errorMessage = nil
            }
        }
        selectedTranscriptionID = id
        route = .transcribe
        enqueueTranscription(id, openSessionWhenBatchCompletes: true)
    }

    func prepareCloudAccess(for placement: TranscriptionPlacement) async -> CloudAccessPreparation {
        guard TranscriptionPlacementRouter.requiresAuthentication(placement) else { return .ready }
        return await AccountService.shared.ensureCloudAccess()
    }

    /// Applies new processing options and re-runs ASR for an existing transcription job.
    func retranscribe(_ id: UUID, options: LocalProcessingOptions) {
        retranscribe(id, submission: TranscriptionSubmission(options: options, placement: .localDefault))
    }

    func retranscribe(_ id: UUID, submission: TranscriptionSubmission) {
        guard let job = transcriptions.first(where: { $0.id == id }) else { return }
        guard job.state != .running, job.state != .cancelling else { return }
        updateTranscription(id) {
            $0.languageCode = submission.options.languageCode
            $0.speakerCount = submission.options.speakerCount
            $0.clipStartMs = submission.options.clipStartMs
            $0.clipEndMs = submission.options.clipEndMs
            $0.useLLMSubtitleProcessing = submission.options.useLLMSubtitleProcessing
            $0.targetLanguageCode = submission.options.normalizedTargetLanguageCode
            $0.customTitle = SessionTitlePolicy.normalizedUserTitle(submission.options.customTitle)
            $0.placement = submission.placement
        }
        runTranscription(id)
    }

    private func startTranscriptionPipeline(_ id: UUID) {
        guard flowTasks[id] == nil,
              let index = transcriptions.firstIndex(where: { $0.id == id }) else {
            finishTranscriptionSlot(id)
            return
        }
        transcriptions[index].state = .running
        transcriptions[index].progress = 0.02
        transcriptions[index].progressMessage = transcriptions[index].compute == .cloud
            ? "Connecting to VoxStudio Cloud…"
            : "Preparing audio…"
        transcriptions[index].progressStage = nil
        transcriptions[index].flowProgressStage = .transcription
        transcriptions[index].progressStep = "flow_started"
        transcriptions[index].progressCompleted = nil
        transcriptions[index].progressTotal = nil
        transcriptions[index].errorMessage = nil
        transcriptions[index].cloudSyncState = DubCloudSyncState.none
        transcriptions[index].pendingCloudSyncError = nil
        stagedTranscriptions[id] = .init()
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
            if Task.isCancelled {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                discardStagedTranscription(id)
                return
            }
            let input: MaterializedTranscriptionInput
            do {
                input = try await materializeClipMediaIfNeeded(for: id)
            } catch is CancellationError {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                discardStagedTranscription(id)
                return
            } catch {
                updateTranscription(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.progressMessage = "Clip extraction failed"
                    $0.flowProgressStage = nil
                    $0.progressStep = nil
                }
                discardStagedTranscription(id)
                return
            }
            guard let job = transcriptions.first(where: { $0.id == id }) else { return }
            if input.usesExtractedClip, var staged = stagedTranscriptions[id] {
                staged.processedSourcePath = input.sourceURL.path
                stagedTranscriptions[id] = staged
            }
            var flowJob = job
            flowJob.sourcePath = input.sourceURL.path
            if input.usesExtractedClip {
                flowJob.clipStartMs = nil
                flowJob.clipEndMs = nil
            }
            let isCloud = flowJob.compute == .cloud
            var uploadURL = input.sourceURL
            if isCloud, flowJob.isRecordedCapture {
                do {
                    if let stripped = try await materializeRecordingCloudAudioIfNeeded(
                        sourceURL: input.sourceURL,
                        jobID: id
                    ) {
                        uploadURL = stripped
                        if var staged = stagedTranscriptions[id] {
                            staged.cloudUploadPath = stripped.path
                            stagedTranscriptions[id] = staged
                        }
                    }
                } catch is CancellationError {
                    updateTranscription(id) {
                        $0.state = .cancelled
                        $0.errorMessage = nil
                        $0.progressMessage = "Cancelled — ready to retry"
                    }
                    discardStagedTranscription(id)
                    return
                } catch {
                    updateTranscription(id) {
                        $0.state = .failed
                        $0.errorMessage = error.localizedDescription
                        $0.progressMessage = "Audio extraction failed"
                        $0.flowProgressStage = nil
                        $0.progressStep = nil
                    }
                    discardStagedTranscription(id)
                    return
                }
            }
            if !isCloud {
                _ = await LLMSettingsStore.shared.credentialAvailable()
            }
            let hasSubtitleModel = !isCloud && LLMSettingsStore.shared.hasConfiguredModel(
                for: .subtitleProcessing
            )
            let request = TranscriptionTaskRequest(
                jobID: id,
                sourceURL: input.sourceURL,
                originalFilename: uploadURL.lastPathComponent,
                mimeType: Self.mimeType(for: uploadURL),
                sizeBytes: (try? uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                durationHintSec: flowJob.clipRangeSeconds.map { $0.upperBound - $0.lowerBound },
                options: flowJob.processingOptions,
                placement: flowJob.placement,
                flowRequest: MediaFlowRequest(
                    id: id,
                    input: .media(input.sourceURL),
                    steps: flowJob.compute == .cloud
                        ? []
                        : WorkbenchMediaFlowPlanner.transcriptionSteps(
                            for: flowJob,
                            hasAPIKey: hasSubtitleModel
                        )
                ),
                remoteSessionID: flowJob.remoteSessionID,
                shouldReuseRemoteSession: input.usesExtractedClip == false
                    && flowJob.remoteSessionID != nil
                    && flowJob.placement.storage == .cloud
                    && flowJob.placement.compute == .cloud,
                sourcePreview: Self.sourcePreview(for: flowJob),
                uploadURL: uploadURL == input.sourceURL ? nil : uploadURL
            )
            for await event in taskAccess.events(for: request) {
                if Task.isCancelled {
                    break
                }
                await consumeTranscriptionEvent(
                    event,
                    jobID: id,
                    sourceURL: input.sourceURL,
                    languageCode: flowJob.languageCode,
                    speakerCount: flowJob.speakerCount.count
                )
            }
            if Task.isCancelled {
                updateTranscription(id) {
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
                discardStagedTranscription(id)
                return
            }
            guard let completed = transcriptions.first(where: { $0.id == id }),
                  completed.state == .completed else { return }

            if TranscriptionPlacementRouter.shouldSyncLocalResults(completed.placement) {
                updateTranscription(id) {
                    $0.cloudSyncState = .pending
                    $0.pendingCloudSyncError = nil
                    $0.progressMessage = "Completed locally · preparing cloud sync…"
                }
            }

            // Free the local ASR slot before title/summary LLM enrichment.
            finishTranscriptionSlot(id)
            releasedSlot = true
            await enrichCompletedTranscription(id)
            await syncCompletedTranscriptionToCloud(id, sourceURL: input.sourceURL)
        }
        flowTasks[id] = task
    }

    private func syncCompletedTranscriptionToCloud(_ id: UUID, sourceURL: URL) async {
        guard let current = transcriptions.first(where: { $0.id == id }),
              TranscriptionPlacementRouter.shouldSyncLocalResults(current.placement),
              current.state == .completed,
              let result = current.result else {
            return
        }

        updateTranscription(id) {
            $0.cloudSyncState = .pending
            $0.pendingCloudSyncError = nil
            $0.errorMessage = nil
            $0.progressMessage = "Completed locally · syncing to VoxStudio Cloud…"
        }
        guard let snapshot = transcriptions.first(where: { $0.id == id }) else { return }

        do {
            let remoteID = try await taskAccess.persistCloudCopyIfNeeded(
                TranscriptionResultSyncRequest(
                    jobID: id,
                    remoteSessionID: snapshot.remoteSessionID,
                    sourceURL: sourceURL,
                    originalFilename: snapshot.originalFilename,
                    mimeType: Self.mimeType(for: sourceURL),
                    sizeBytes: nil,
                    options: snapshot.processingOptions,
                    placement: snapshot.placement,
                    result: result,
                    subtitleTrack: snapshot.subtitleTrack,
                    translationTracks: snapshot.translationTracks,
                    title: snapshot.sessionTitle,
                    summary: snapshot.summaryMarkdown,
                    sessionTag: snapshot.sessionTag,
                    sourcePreview: Self.sourcePreview(for: snapshot)
                )
            )
            updateTranscription(id) {
                $0.remoteSessionID = remoteID ?? $0.remoteSessionID
                $0.cloudSyncState = .completed
                $0.pendingCloudSyncError = nil
                $0.errorMessage = nil
                $0.progressMessage = $0.summaryMarkdown == nil
                    ? "Transcript ready · saved to VoxStudio Cloud"
                    : "Transcript and summary ready · saved to VoxStudio Cloud"
            }
            scheduleCloudSync(forTranscription: id)
        } catch is CancellationError {
            updateTranscription(id) {
                $0.cloudSyncState = .pending
                $0.pendingCloudSyncError = "Cloud sync was cancelled."
                $0.progressMessage = "Completed locally · cloud sync pending"
            }
        } catch {
            updateTranscription(id) {
                $0.cloudSyncState = .pending
                $0.pendingCloudSyncError = error.localizedDescription
                $0.progressMessage = "Completed locally · cloud sync pending"
            }
        }
    }

    func retryTranscriptionCloudSync(_ id: UUID) {
        guard flowTasks[id] == nil,
              let job = transcriptions.first(where: { $0.id == id }),
              job.state == .completed,
              TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
              job.result != nil else {
            return
        }
        if job.remoteSessionID != nil {
            scheduleCloudSync(forTranscription: id)
            return
        }
        guard TranscriptionPlacementRouter.shouldSyncLocalResults(job.placement),
              job.resolvedCloudSyncState == .pending else { return }
        let sourceURL = job.sourceURL
        updateTranscription(id) {
            $0.progressMessage = "Retrying cloud sync…"
            $0.pendingCloudSyncError = nil
            $0.errorMessage = nil
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.syncCompletedTranscriptionToCloud(id, sourceURL: sourceURL)
            self.flowTasks[id] = nil
        }
        flowTasks[id] = task
    }

    /// Writes the selected clip window to managed storage without changing persisted job state.
    private func materializeClipMediaIfNeeded(for id: UUID) async throws -> MaterializedTranscriptionInput {
        guard let index = transcriptions.firstIndex(where: { $0.id == id }),
              let range = transcriptions[index].clipRangeSeconds else {
            guard let job = transcriptions.first(where: { $0.id == id }) else {
                throw CancellationError()
            }
            return .init(sourceURL: job.sourceURL, usesExtractedClip: false)
        }

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
            $0.progressMessage = "Preparing audio…"
            $0.progressStep = "flow_started"
        }
        return .init(sourceURL: destinationURL, usesExtractedClip: true)
    }

    private func materializeRecordingCloudAudioIfNeeded(sourceURL: URL, jobID: UUID) async throws -> URL? {
        let hasVideo = await WorkbenchAudioStripper.assetHasVideoTrack(at: sourceURL)
        guard hasVideo else { return nil }
        updateTranscription(jobID) {
            $0.progress = 0.05
            $0.progressMessage = "Extracting audio for VoxStudio Cloud…"
            $0.flowProgressStage = .transcription
            $0.progressStep = "extract_audio"
        }
        let destinationURL = Self.clipsDirectory
            .appendingPathComponent("\(jobID.uuidString)-cloud-audio")
            .appendingPathExtension("m4a")
        try await WorkbenchAudioStripper.extractM4A(from: sourceURL, to: destinationURL)
        try Task.checkCancellation()
        updateTranscription(jobID) {
            $0.progressMessage = "Uploading to VoxStudio Cloud…"
            $0.progressStep = "flow_started"
        }
        return destinationURL
    }

    func cancelTranscription(_ id: UUID) {
        let shouldReturnToSession = transcriptions.first(where: { $0.id == id }).map {
            TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
                $0.placement,
                hasRemoteSession: $0.remoteSessionID != nil
            )
        } ?? false
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
        updateTranscription(id) {
            $0.state = .cancelling
            $0.errorMessage = nil
            $0.progressMessage = $0.compute == .cloud
                ? "Cancelling VoxStudio Cloud…"
                : "Cancelling media flow…"
        }
        Task { [weak self] in
            do {
                try await self?.taskAccess.cancel(id)
                if shouldReturnToSession, let self {
                    self.activeTranscriptionBatch = nil
                    self.selectedTranscriptionID = nil
                    self.selectedDubID = nil
                    self.selectedSessionID = id
                    self.route = .session
                }
                // Let the remote workflow acknowledge cancellation before stopping its event consumer.
                self?.flowTasks[id]?.cancel()
            } catch {
                guard let self,
                      self.transcriptions.first(where: { $0.id == id })?.state == .cancelling
                else {
                    return
                }
                self.updateTranscription(id) {
                    $0.state = .failed
                    $0.progressMessage = "Could not cancel VoxStudio Cloud"
                    $0.errorMessage = error.localizedDescription
                }
                self.flowTasks[id]?.cancel()
            }
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
                await consumeTranslationEvent(event, jobID: id)
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
        let generationID = UUID().uuidString.lowercased()
        let clientRequestID = "desktop-dub-\(id.uuidString.lowercased())-\(generationID)"
        let cacheURL = Self.dataDirectory
            .appendingPathComponent("Dubs", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("dub-\(generationID)")
            .appendingPathExtension("m4a")
        dubs[index].state = .running
        dubs[index].progress = 0.02
        dubs[index].progressMessage = snapshot.placement.compute == .cloud
            ? "Preparing VoxStudio Cloud…"
            : "Loading local voice model…"
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
        dubs[index].summaryTemplateUserEdition = nil
        dubs[index].sessionTag = nil
        dubs[index].internalSummary = nil
        dubs[index].summaryState = nil
        dubs[index].summaryErrorMessage = nil
        dubs[index].remoteGenerationID = generationID
        dubs[index].clientRequestID = clientRequestID
        dubs[index].localCachePath = cacheURL.path
        dubs[index].remoteSessionID = snapshot.placement.storage == .cloud
            ? snapshot.remoteSessionID
            : nil
        dubs[index].cloudSyncState = snapshot.placement.storage == .cloud && snapshot.placement.compute == .local
            ? .pending
            : DubCloudSyncState.none
        dubs[index].pendingCloudSyncError = nil
        dubs[index].remoteResultVersion = nil
        save()

        let task = Task { [weak self] in
            guard let self else { return }
            defer { flowTasks[id] = nil }
            do {
                if snapshot.placement.needsAuthentication {
                    switch await AccountService.shared.ensureCloudAccess() {
                    case .ready:
                        break
                    case .cancelled:
                        updateDub(id) {
                            guard $0.remoteGenerationID == generationID else { return }
                            $0.state = .cancelled
                            $0.errorMessage = nil
                            $0.progressMessage = "Cancelled — ready to retry"
                        }
                        return
                    case .failed(let message):
                        updateDub(id) {
                            guard $0.remoteGenerationID == generationID else { return }
                            $0.state = .failed
                            $0.errorMessage = message
                            $0.progressMessage = "Cloud account unavailable"
                        }
                        return
                    }
                }
                if snapshot.placement.compute != .cloud {
                    _ = await LLMSettingsStore.shared.credentialAvailable()
                }
                let hasSubtitleModel = snapshot.placement.compute == .local
                    && LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing)
                var remoteReferences: [UUID: LocalVoiceReference] = [:]
                if snapshot.placement.needsAuthentication {
                    for voiceID in missingVoiceIDs.union(
                        Set([defaultVoiceID].compactMap { $0 })
                            .union(snapshot.resolvedSpeakerVoiceIDs.values)
                            .union(snapshot.resolvedSegmentVoiceIDs.values)
                    ) {
                        let synced = try await voiceLibrary.ensureCloudReference(voiceID)
                        remoteReferences[voiceID] = synced
                    }
                }
                guard !snapshot.placement.needsAuthentication
                    || (defaultVoiceID.flatMap { remoteReferences[$0]?.cloudObjectKey } != nil) else {
                    throw VoxellaAPIError.http(409, "VoxStudio Cloud needs a synchronized voice reference.")
                }
                let remoteSegments = (snapshot.segments ?? []).map { segment in
                    guard snapshot.placement.needsAuthentication else { return segment }
                    let voiceID = snapshot.resolvedSegmentVoiceIDs[segment.index]
                        ?? segment.speaker.flatMap { snapshot.resolvedSpeakerVoiceIDs[$0] }
                        ?? defaultVoiceID
                    guard let voiceID, let remote = remoteReferences[voiceID] else { return segment }
                    var updated = segment
                    if let remoteID = remote.cloudReferenceID {
                        updated.options["reference_audio_id"] = remoteID.uuidString
                    }
                    if let objectKey = remote.cloudObjectKey {
                        updated.options["reference_audio_r2_key"] = objectKey
                    }
                    return updated
                }
                let remoteDefault = defaultVoiceID.flatMap { remoteReferences[$0] }
                let request = DubTaskRequest(
                    jobID: id,
                    script: snapshot.script,
                    segments: remoteSegments,
                    language: snapshot.language,
                    model: snapshot.model,
                    referenceVoiceID: defaultVoiceID,
                    reference: reference,
                    speakerReferences: speakerReferences,
                    segmentReferences: segmentReferences,
                    referenceAudioID: remoteDefault?.cloudReferenceID,
                    referenceAudioR2Key: remoteDefault?.cloudObjectKey,
                    referenceText: snapshot.referenceText,
                    placement: snapshot.placement,
                    remoteSessionID: snapshot.placement.storage == .cloud
                        ? snapshot.remoteSessionID
                        : nil,
                    generationID: generationID,
                    clientRequestID: clientRequestID,
                    title: snapshot.title.isEmpty ? nil : snapshot.title,
                    cacheURL: cacheURL,
                    hasSubtitleModel: hasSubtitleModel
                )
                for await event in dubTaskAccess.events(for: request) {
                    if Task.isCancelled { break }
                    consumeDubTaskEvent(
                        event,
                        jobID: id,
                        resolvedReferenceVoiceID: defaultVoiceID,
                        generationID: generationID
                    )
                }
                if Task.isCancelled {
                    updateDub(id) {
                        guard $0.remoteGenerationID == generationID else { return }
                        $0.state = .cancelled
                        $0.errorMessage = nil
                        $0.progressMessage = "Cancelled — ready to retry"
                    }
                    return
                }
                guard let job = dubs.first(where: { $0.id == id }),
                      job.remoteGenerationID == generationID,
                      job.state == .completed else { return }
                await enrichAfterDubCompletion(job)
            } catch is CancellationError {
                updateDub(id) {
                    guard $0.remoteGenerationID == generationID else { return }
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
            } catch {
                updateDub(id) {
                    guard $0.remoteGenerationID == generationID else { return }
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.progressMessage = "Dub failed"
                }
            }
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
        guard flowTasks[id] != nil,
              let snapshot = dubs.first(where: { $0.id == id }) else { return }
        let shouldReturnToSession = TranscriptionPlacementRouter.shouldReturnToSessionAfterCancellation(
            snapshot.placement,
            hasRemoteSession: snapshot.remoteSessionID != nil
        )
        updateDub(id) {
            $0.state = .cancelling
            $0.errorMessage = nil
            $0.progressMessage = snapshot.placement.compute == .cloud
                ? "Cancelling VoxStudio Cloud…"
                : "Cancelling media flow…"
        }
        Task { [weak self] in
            do {
                try await self?.dubTaskAccess.cancel(id)
                guard let self else { return }
                if shouldReturnToSession {
                    self.selectedDubID = nil
                    self.selectedTranscriptionID = nil
                    self.selectedSessionID = id
                    self.route = .session
                }
                self.flowTasks[id]?.cancel()
            } catch {
                guard let self,
                      self.dubs.first(where: { $0.id == id })?.state == .cancelling else { return }
                self.updateDub(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.progressMessage = "Cancellation failed"
                }
            }
        }
    }

    func retryDubCloudSync(_ id: UUID) {
        guard flowTasks[id] == nil,
              let job = dubs.first(where: { $0.id == id }),
              job.state == .completed,
              TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
              job.remoteSessionID != nil else { return }
        scheduleCloudSync(forDub: id)
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
            let committed: Bool
            if progress.status == .completed {
                committed = await commitStagedTranscription(
                    jobID,
                    sourceURL: sourceURL,
                    languageCode: languageCode,
                    speakerCount: speakerCount
                )
            } else if progress.status == .cancelled || progress.status == .failed {
                discardStagedTranscription(jobID)
                committed = false
            } else {
                committed = false
            }
            updateTranscription(jobID) { job in
                job.flowProgressStage = progress.stage
                job.progressStep = progress.step
                job.progressCompleted = progress.current
                job.progressTotal = progress.total
                job.progressMessage = progress.message
                if progress.step == "bind_remote_session",
                   let remoteToken = progress.message.split(whereSeparator: \.isWhitespace).last,
                   let remote = UUID(uuidString: String(remoteToken)) {
                    job.remoteSessionID = remote
                }
                if progress.status == .started || progress.status == .processing {
                    job.state = .running
                    job.progress = max(job.progress, progress.progress)
                } else if progress.status == .completed {
                    guard committed else {
                        job.state = .failed
                        job.progressMessage = "Transcription result unavailable"
                        job.errorMessage = "The transcription finished without a result to apply."
                        return
                    }
                    job.state = .completed
                    job.progress = 1
                    job.localCachePath = sourceURL.path
                    if let detail = job.transcriptionAlignmentDiagnostics?.completionDetail {
                        job.progressMessage = "Transcript ready · \(detail)"
                    } else if job.translationTrack != nil {
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

            if committed,
               let job = transcriptions.first(where: { $0.id == jobID }),
               job.state == .completed {
                SessionIndexCoordinator.shared.ingest(job)
            }

        case .artifact(.transcription(let result, let diagnostics, let alignmentDiagnostics)):
            guard var staged = stagedTranscriptions[jobID] else { return }
            staged.rawResult = result
            staged.preparedResult = result
            staged.diarizationDiagnostics = diagnostics
            staged.alignmentDiagnostics = alignmentDiagnostics
            stagedTranscriptions[jobID] = staged

        case .artifact(.subtitles(let track, let rebuiltSegments)):
            guard var staged = stagedTranscriptions[jobID] else { return }
            staged.subtitleTrack = track
            staged.preparedResult = Self.preparedTranscript(
                from: track,
                base: staged.preparedResult ?? staged.rawResult,
                rebuiltSegments: rebuiltSegments
            )
            stagedTranscriptions[jobID] = staged

        case .artifact(.translation(let track)):
            guard var staged = stagedTranscriptions[jobID],
                  let job = transcriptions.first(where: { $0.id == jobID }) else { return }
            let code = (track.language ?? job.targetLanguageCode ?? "und")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            staged.upsertTranslation(track, languageCode: code.isEmpty ? "und" : code)
            stagedTranscriptions[jobID] = staged

        case .artifact(.alignment), .artifact(.dub):
            break
        }
    }

    private func consumeTranslationEvent(_ event: MediaJobEvent, jobID: UUID) async {
        switch event {
        case .progress(let progress):
            updateTranscription(jobID) { job in
                job.flowProgressStage = progress.stage
                job.progressStep = progress.step
                job.progressCompleted = progress.current
                job.progressTotal = progress.total
                job.progressMessage = progress.message
                switch progress.status {
                case .started, .processing:
                    job.state = .running
                    job.progress = max(job.progress, progress.progress)
                case .completed:
                    job.state = .completed
                    job.progress = 1
                    job.progressMessage = job.subtitleTrack == nil
                        ? "Translation ready"
                        : "Subtitles and translation ready"
                    job.selectedTrack = job.translationTrack == nil ? .source : .translation
                    job.errorMessage = nil
                case .cancelled:
                    job.state = .cancelled
                    job.progressMessage = "Cancelled — ready to retry"
                    job.errorMessage = nil
                case .failed:
                    job.state = .failed
                    job.errorMessage = progress.message
                }
            }

        case .artifact(.subtitles(let track, let rebuiltSegments)):
            updateTranscription(jobID) { job in
                job.subtitleTrack = track
                let prepared = Self.preparedTranscript(
                    from: track,
                    base: job.result,
                    rebuiltSegments: rebuiltSegments
                )
                job.result = prepared
                job.editedText = prepared.text
            }

        case .artifact(.translation(let track)):
            updateTranscription(jobID) { job in
                let code = (track.language ?? job.targetLanguageCode ?? "und")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                job.upsertTranslation(track, languageCode: code.isEmpty ? "und" : code)
                job.selectedTrack = .translation
            }

        case .artifact(.transcription), .artifact(.alignment), .artifact(.dub):
            break
        }
    }

    private func commitStagedTranscription(
        _ id: UUID,
        sourceURL: URL,
        languageCode: String?,
        speakerCount: Int?
    ) async -> Bool {
        guard let staged = stagedTranscriptions.removeValue(forKey: id),
              let artifacts = staged.completedArtifacts,
              TranscriptionCommitPolicy.shouldCommit(status: .completed, artifacts: artifacts) else {
            return false
        }
        if let cloudUploadPath = staged.cloudUploadPath {
            Task.detached(priority: .utility) {
                Self.removeManagedClipMediaIfNeeded(URL(fileURLWithPath: cloudUploadPath))
            }
        }
        updateTranscription(id) { job in
            artifacts.apply(to: &job)
        }
        await TranscriptCache.shared.storeLocalTranscript(
            artifacts.rawResult,
            for: sourceURL,
            configuration: .init(languageCode: languageCode, speakerCount: speakerCount)
        )
        markDubsOutdated(afterRetranscription: id)
        return true
    }

    private func discardStagedTranscription(_ id: UUID) {
        guard let staged = stagedTranscriptions.removeValue(forKey: id) else { return }
        let paths = [staged.processedSourcePath, staged.cloudUploadPath].compactMap { $0 }
        Task.detached(priority: .utility) {
            for path in paths {
                Self.removeManagedClipMediaIfNeeded(URL(fileURLWithPath: path))
            }
        }
    }

    private func markDubsOutdated(afterRetranscription id: UUID) {
        if TranscriptionCommitPolicy.markLinkedCompletedDubsOutdated(
            &dubs,
            sourceTranscriptionID: id
        ) {
            save()
        }
    }

    private static func preparedTranscript(
        from track: SubtitleTrack,
        base: TranscriptionResult?,
        rebuiltSegments: [TranscriptionSegment]?
    ) -> TranscriptionResult {
        let fallback = track.asTranscriptionResult(
            preservingWords: base?.words ?? []
        ).aggregatingSegments()
        guard let rebuiltSegments, !rebuiltSegments.isEmpty else {
            return fallback
        }

        let language = base?.language ?? track.language ?? track.sourceLanguage
        return TranscriptionResult(
            text: TranscriptSegmenter.joinedText(
                rebuiltSegments.map(\.text),
                language: language
            ),
            language: language,
            words: base?.words ?? fallback.words,
            segments: rebuiltSegments
        )
    }

    /// Auto title + template summary after transcription, aligned with postprocess finalize → digest → template summary.
    @discardableResult
    private func enrichCompletedTranscription(
        _ id: UUID,
        userInstruction: String? = nil,
        regenerateMetadata: Bool? = nil,
        taskAlreadyRegistered: Bool = false,
        requireConfiguredModel: Bool = true,
        reportFailure: Bool = true
    ) async -> Bool {
        if !taskAlreadyRegistered {
            guard summaryTaskIDs.insert(id).inserted else { return false }
        }
        defer {
            if !taskAlreadyRegistered {
                summaryTaskIDs.remove(id)
            }
        }

        guard !requireConfiguredModel || LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing) else {
            updateTranscription(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
            if reportFailure {
                WorkbenchTipCenter.shared.show(
                    LLMConfigurationError.noConfiguredModel(.subtitleProcessing).localizedDescription,
                    kind: .error,
                    id: "summary.missing-llm",
                    actionLabel: "Open AI Settings",
                    action: .openAISettings
                )
            }
            return false
        }
        guard let job = transcriptions.first(where: { $0.id == id }),
              let transcript = job.result ?? job.sourceTimedResult else { return false }
        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptText.isEmpty else { return false }
        let isRefinement = !(userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let shouldRegenerateMetadata = regenerateMetadata ?? !isRefinement

        updateTranscription(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = isRefinement || !shouldRegenerateMetadata
                ? "Regenerating summary…"
                : "Generating title and summary…"
        }

        do {
            let route = try await LLMSettingsStore.shared.runtimeRoute(for: .subtitleProcessing)
            let client = ResilientLLMTextClient(route: route)
            var title = job.sessionTitle
            var tagText = job.sessionTag ?? "general"
            var internalSummary = job.internalSummary ?? ""
            if shouldRegenerateMetadata {
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

            let templateJob = transcriptions.first(where: { $0.id == id }) ?? job
            let templateWasUnassigned = templateJob.summaryTemplateID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
            let template = await SummaryTemplateCatalog.shared.template(
                forID: templateJob.summaryTemplateID,
                name: templateJob.summaryTemplateName,
                userEdition: templateJob.summaryTemplateUserEdition
            )
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
            try Task.checkCancellation()
            guard isCurrentSummaryTemplate(
                template.id,
                forTranscription: id,
                allowUnassignedDefault: templateWasUnassigned
            ) else { return false }
            updateTranscription(id) {
                $0.summaryMarkdown = markdown
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryTemplateUserEdition = template.userEdition
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.translationTracks.isEmpty
                    ? "Transcript and summary ready"
                    : "Transcript, translation, and summary ready"
            }
            if let job = transcriptions.first(where: { $0.id == id }),
               job.state == .completed {
                SessionIndexCoordinator.shared.patchSessionCard(job)
            }
            return true
        } catch {
            updateTranscription(id) {
                $0.summaryState = .failed
                $0.summaryErrorMessage = error.localizedDescription
                $0.progressMessage = isRefinement
                    ? "Summary regeneration failed"
                    : "Transcript ready — summary unavailable"
            }
            if reportFailure {
                WorkbenchTipCenter.shared.show(
                    error.localizedDescription,
                    kind: .error,
                    id: "summary.failed.\(id.uuidString)"
                )
            }
            Log.project.warning("session enrichment failed: \(error.localizedDescription)")
            return false
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

    func regenerateSummary(
        forTranscription id: UUID,
        userPrompt: String? = nil,
        regenerateMetadata: Bool? = nil
    ) {
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
        Task {
            await enrichCompletedTranscription(
                id,
                userInstruction: prompt,
                regenerateMetadata: regenerateMetadata
            )
        }
    }

    func regenerateSummary(
        forDub id: UUID,
        userPrompt: String? = nil,
        regenerateMetadata: Bool? = nil
    ) {
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
        Task {
            await enrichCompletedDub(
                id,
                userInstruction: prompt,
                regenerateMetadata: regenerateMetadata
            )
        }
    }

    func applySummaryTemplate(_ template: SummaryTemplateDefinition, to session: WorkbenchSession) {
        if let transcriptionID = session.transcriptionID {
            updateTranscription(transcriptionID) {
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryTemplateUserEdition = template.userEdition
            }
            Task { [weak self] in
                guard let self else { return }
                await self.applySummaryTemplateToTranscription(template, id: transcriptionID)
            }
            return
        }
        if let dubID = session.dubID {
            updateDub(dubID) {
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryTemplateUserEdition = template.userEdition
            }
            Task { [weak self] in
                guard let self else { return }
                await self.applySummaryTemplateToDub(template, id: dubID)
            }
        }
    }

    private func applySummaryTemplateToTranscription(
        _ template: SummaryTemplateDefinition,
        id: UUID
    ) async {
        guard summaryTaskIDs.insert(id).inserted else { return }
        defer { summaryTaskIDs.remove(id) }

        let localRouteAvailable = (try? await LLMSettingsStore.shared.runtimeRoute(
            for: .subtitleProcessing
        )) != nil
        if localRouteAvailable,
           await enrichCompletedTranscription(
               id,
               regenerateMetadata: false,
               taskAlreadyRegistered: true,
               requireConfiguredModel: false,
               reportFailure: false
           ) {
            await syncSummaryToCloud(forTranscription: id)
            return
        }

        updateTranscription(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = "Generating summary in VoxStudio Cloud…"
        }
        do {
            let response = try await requestCloudSummary(
                template: template,
                sessionID: try cloudSessionID(forTranscription: id),
                hasExistingSummary: hasSummary(forTranscription: id)
            )
            try Task.checkCancellation()
            guard let summary = response.summary,
                  !summary.outputMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isCurrentSummaryTemplate(template.id, forTranscription: id) else {
                return
            }
            let remoteTemplate = response.template
            updateTranscription(id) {
                $0.summaryMarkdown = summary.outputMarkdown
                $0.summaryTemplateID = summary.templateID ?? remoteTemplate?.id ?? template.id
                $0.summaryTemplateName = remoteTemplate?.name ?? template.name
                $0.summaryTemplateUserEdition = remoteTemplate?.userEdition ?? template.userEdition
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.translationTracks.isEmpty
                    ? "Transcript and summary ready"
                    : "Transcript, translation, and summary ready"
            }
        } catch is CancellationError {
            markCloudSummaryFailure(
                forTranscription: id,
                message: "Cloud summary generation was cancelled."
            )
        } catch {
            markCloudSummaryFailure(forTranscription: id, message: error.localizedDescription)
        }
    }

    private func applySummaryTemplateToDub(
        _ template: SummaryTemplateDefinition,
        id: UUID
    ) async {
        guard summaryTaskIDs.insert(id).inserted else { return }
        defer { summaryTaskIDs.remove(id) }

        let localRouteAvailable = (try? await LLMSettingsStore.shared.runtimeRoute(
            for: .subtitleProcessing
        )) != nil
        if localRouteAvailable,
           await enrichCompletedDub(
               id,
               regenerateMetadata: false,
               taskAlreadyRegistered: true,
               requireConfiguredModel: false,
               reportFailure: false
           ) {
            await syncSummaryToCloud(forDub: id)
            return
        }

        updateDub(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = "Generating summary in VoxStudio Cloud…"
        }
        do {
            let response = try await requestCloudSummary(
                template: template,
                sessionID: try cloudSessionID(forDub: id),
                hasExistingSummary: hasSummary(forDub: id)
            )
            try Task.checkCancellation()
            guard let summary = response.summary,
                  !summary.outputMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isCurrentSummaryTemplate(template.id, forDub: id) else {
                return
            }
            let remoteTemplate = response.template
            updateDub(id) {
                $0.summaryMarkdown = summary.outputMarkdown
                $0.summaryTemplateID = summary.templateID ?? remoteTemplate?.id ?? template.id
                $0.summaryTemplateName = remoteTemplate?.name ?? template.name
                $0.summaryTemplateUserEdition = remoteTemplate?.userEdition ?? template.userEdition
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.subtitleTrack == nil
                    ? "Dub and summary ready"
                    : "Dub, subtitles, and summary ready"
            }
        } catch is CancellationError {
            markCloudSummaryFailure(forDub: id, message: "Cloud summary generation was cancelled.")
        } catch {
            markCloudSummaryFailure(forDub: id, message: error.localizedDescription)
        }
    }

    private func requestCloudSummary(
        template: SummaryTemplateDefinition,
        sessionID: UUID,
        hasExistingSummary: Bool
    ) async throws -> VoxellaSessionSummaryResponse {
        guard UUID(uuidString: template.id) != nil else {
            throw VoxellaAPIError.http(422, "The selected summary template is not available in VoxStudio Cloud.")
        }
        try await ensureCloudAccessForSummary()

        let update = VoxellaSummaryTemplateUpdatePayload(
            name: nonEmpty(template.name),
            description: nonEmpty(template.description),
            userEdition: nonEmpty(template.userEdition)
        )
        let client = VoxellaAPIClient.shared
        if hasExistingSummary {
            _ = try await client.regenerateSessionSummary(
                sessionID: sessionID,
                templateID: template.id,
                templateUpdate: update
            )
        } else {
            _ = try await client.generateSessionSummary(
                sessionID: sessionID,
                templateID: template.id,
                templateUpdate: update
            )
        }
        return try await waitForCloudSummary(
            sessionID: sessionID,
            expectedTemplateID: template.id,
            locale: SummaryTemplateLocale.resolve(AppLocalization.shared.activeIdentifier)
        )
    }

    private func waitForCloudSummary(
        sessionID: UUID,
        expectedTemplateID: String,
        locale: String
    ) async throws -> VoxellaSessionSummaryResponse {
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let response = try await VoxellaAPIClient.shared.sessionSummary(
                sessionID: sessionID,
                locale: locale
            )
            if let summary = response.summary {
                let returnedTemplateID = summary.templateID ?? response.template?.id
                guard let returnedTemplateID,
                      returnedTemplateID.caseInsensitiveCompare(expectedTemplateID) == .orderedSame else {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                switch summary.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "failed":
                    let message = summary.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw VoxellaAPIError.http(
                        422,
                        message.isEmpty ? "Cloud summary generation failed." : message
                    )
                case "completed":
                    if !summary.outputMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return response
                    }
                default:
                    break
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw VoxellaAPIError.http(408, "Cloud summary generation timed out.")
    }

    private func ensureCloudAccessForSummary() async throws {
        switch await AccountService.shared.ensureCloudAccess() {
        case .ready:
            return
        case .cancelled:
            throw VoxellaAPIError.cancelled
        case .failed(let message):
            throw VoxellaAPIError.http(0, message)
        }
    }

    private func cloudSessionID(forTranscription id: UUID) throws -> UUID {
        guard let remoteSessionID = transcriptions.first(where: { $0.id == id })?.remoteSessionID else {
            throw VoxellaAPIError.http(0, "This session has no cloud copy for summary generation.")
        }
        return remoteSessionID
    }

    private func cloudSessionID(forDub id: UUID) throws -> UUID {
        guard let remoteSessionID = dubs.first(where: { $0.id == id })?.remoteSessionID else {
            throw VoxellaAPIError.http(0, "This session has no cloud copy for summary generation.")
        }
        return remoteSessionID
    }

    private func hasSummary(forTranscription id: UUID) -> Bool {
        guard let summary = transcriptions.first(where: { $0.id == id })?.summaryMarkdown else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasSummary(forDub id: UUID) -> Bool {
        guard let summary = dubs.first(where: { $0.id == id })?.summaryMarkdown else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isCurrentSummaryTemplate(
        _ templateID: String,
        forTranscription id: UUID,
        allowUnassignedDefault: Bool = false
    ) -> Bool {
        Self.summaryTemplateMatches(
            requestedTemplateID: templateID,
            currentTemplateID: transcriptions.first(where: { $0.id == id })?.summaryTemplateID,
            allowUnassignedDefault: allowUnassignedDefault
        )
    }

    private func isCurrentSummaryTemplate(
        _ templateID: String,
        forDub id: UUID,
        allowUnassignedDefault: Bool = false
    ) -> Bool {
        Self.summaryTemplateMatches(
            requestedTemplateID: templateID,
            currentTemplateID: dubs.first(where: { $0.id == id })?.summaryTemplateID,
            allowUnassignedDefault: allowUnassignedDefault
        )
    }

    nonisolated static func summaryTemplateMatches(
        requestedTemplateID: String,
        currentTemplateID: String?,
        allowUnassignedDefault: Bool = false
    ) -> Bool {
        guard let currentTemplateID = currentTemplateID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !currentTemplateID.isEmpty else {
            return allowUnassignedDefault
                && requestedTemplateID.caseInsensitiveCompare(
                    SummaryTemplateDefinition.generalSummaryID
                ) == .orderedSame
        }
        return currentTemplateID.caseInsensitiveCompare(requestedTemplateID) == .orderedSame
    }

    private func syncSummaryToCloud(forTranscription id: UUID) async {
        scheduleCloudSync(forTranscription: id)
    }

    private func syncSummaryToCloud(forDub id: UUID) async {
        scheduleCloudSync(forDub: id)
    }

    private func markCloudSummaryFailure(forTranscription id: UUID, message: String) {
        updateTranscription(id) {
            $0.summaryState = .failed
            $0.summaryErrorMessage = message
            $0.progressMessage = "Transcript ready — summary unavailable"
        }
        WorkbenchTipCenter.shared.show(
            message,
            kind: .error,
            id: "summary.failed.\(id.uuidString)"
        )
        Log.project.warning("cloud summary failed id=\(id.uuidString) error=\(message)")
    }

    private func markCloudSummaryFailure(forDub id: UUID, message: String) {
        updateDub(id) {
            $0.summaryState = .failed
            $0.summaryErrorMessage = message
            $0.progressMessage = "Dub ready — summary unavailable"
        }
        WorkbenchTipCenter.shared.show(
            message,
            kind: .error,
            id: "summary.failed.\(id.uuidString)"
        )
        Log.project.warning("cloud summary failed id=\(id.uuidString) error=\(message)")
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Auto title + template summary after standalone dub, mirrored from transcription enrichment.
    @discardableResult
    private func enrichCompletedDub(
        _ id: UUID,
        userInstruction: String? = nil,
        regenerateMetadata: Bool? = nil,
        taskAlreadyRegistered: Bool = false,
        requireConfiguredModel: Bool = true,
        reportFailure: Bool = true
    ) async -> Bool {
        if !taskAlreadyRegistered {
            guard summaryTaskIDs.insert(id).inserted else { return false }
        }
        defer {
            if !taskAlreadyRegistered {
                summaryTaskIDs.remove(id)
            }
        }

        guard !requireConfiguredModel || LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing) else {
            updateDub(id) {
                $0.summaryState = nil
                $0.summaryErrorMessage = nil
            }
            if reportFailure {
                WorkbenchTipCenter.shared.show(
                    LLMConfigurationError.noConfiguredModel(.subtitleProcessing).localizedDescription,
                    kind: .error,
                    id: "summary.missing-llm",
                    actionLabel: "Open AI Settings",
                    action: .openAISettings
                )
            }
            return false
        }
        guard let job = dubs.first(where: { $0.id == id }),
              let transcript = dubTranscriptForEnrichment(job) else { return false }
        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptText.isEmpty else { return false }
        let isRefinement = !(userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let shouldRegenerateMetadata = regenerateMetadata ?? !isRefinement

        updateDub(id) {
            $0.summaryState = .running
            $0.summaryErrorMessage = nil
            $0.progressMessage = isRefinement || !shouldRegenerateMetadata
                ? "Regenerating summary…"
                : "Generating title and summary…"
        }

        do {
            let route = try await LLMSettingsStore.shared.runtimeRoute(for: .subtitleProcessing)
            let client = ResilientLLMTextClient(route: route)
            var title = job.displayTitle
            var tagText = job.sessionTag ?? "general"
            var internalSummary = job.internalSummary ?? ""
            if shouldRegenerateMetadata {
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

            let templateJob = dubs.first(where: { $0.id == id }) ?? job
            let templateWasUnassigned = templateJob.summaryTemplateID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
            let template = await SummaryTemplateCatalog.shared.template(
                forID: templateJob.summaryTemplateID,
                name: templateJob.summaryTemplateName,
                userEdition: templateJob.summaryTemplateUserEdition
            )
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
            try Task.checkCancellation()
            guard isCurrentSummaryTemplate(
                template.id,
                forDub: id,
                allowUnassignedDefault: templateWasUnassigned
            ) else { return false }
            updateDub(id) {
                $0.summaryMarkdown = markdown
                $0.summaryTemplateID = template.id
                $0.summaryTemplateName = template.name
                $0.summaryTemplateUserEdition = template.userEdition
                $0.summaryState = .completed
                $0.summaryErrorMessage = nil
                $0.progressMessage = $0.subtitleTrack == nil
                    ? "Dub and summary ready"
                    : "Dub, subtitles, and summary ready"
            }
            return true
        } catch {
            updateDub(id) {
                $0.summaryState = .failed
                $0.summaryErrorMessage = error.localizedDescription
                $0.progressMessage = isRefinement
                    ? "Summary regeneration failed"
                    : "Dub ready — summary unavailable"
            }
            if reportFailure {
                WorkbenchTipCenter.shared.show(
                    error.localizedDescription,
                    kind: .error,
                    id: "summary.failed.\(id.uuidString)"
                )
            }
            Log.project.warning("dub session enrichment failed: \(error.localizedDescription)")
            return false
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

    private func consumeDubTaskEvent(
        _ event: DubTaskEvent,
        jobID: UUID,
        resolvedReferenceVoiceID: UUID?,
        generationID: String
    ) {
        guard dubs.first(where: { $0.id == jobID })?.remoteGenerationID == generationID else {
            return
        }
        switch event {
        case .media(let mediaEvent):
            consumeDubEvent(
                mediaEvent,
                jobID: jobID,
                resolvedReferenceVoiceID: resolvedReferenceVoiceID
            )
        case .remoteSession(let remoteID, let eventGenerationID):
            guard eventGenerationID == generationID else { return }
            updateDub(jobID) { job in
                guard job.remoteGenerationID == generationID else { return }
                job.remoteSessionID = remoteID
                job.cloudSyncState = job.placement.storage == .cloud && job.placement.compute == .local
                    ? .pending
                    : job.cloudSyncState
            }
        case .cloudSyncPending(let localPath, let message, let eventGenerationID):
            guard eventGenerationID == generationID else { return }
            updateDub(jobID) { job in
                guard job.remoteGenerationID == generationID else { return }
                job.state = .completed
                job.outputPath = localPath
                job.localCachePath = localPath
                job.cloudSyncState = .pending
                job.pendingCloudSyncError = message
                job.errorMessage = message
                job.progressMessage = "Completed locally · cloud sync pending"
            }
        case .cloudSyncCompleted(let remoteResultVersion, let eventGenerationID):
            guard eventGenerationID == generationID else { return }
            updateDub(jobID) { job in
                guard job.remoteGenerationID == generationID else { return }
                job.cloudSyncState = .completed
                job.remoteResultVersion = remoteResultVersion
                job.pendingCloudSyncError = nil
                job.errorMessage = nil
            }
        case .failure(let message, let eventGenerationID):
            guard eventGenerationID == generationID else { return }
            updateDub(jobID) { job in
                guard job.remoteGenerationID == generationID else { return }
                job.state = .failed
                job.errorMessage = message
                job.progressMessage = "Dub failed"
                if job.placement.storage == .cloud && job.placement.compute == .local {
                    job.cloudSyncState = .failed
                    job.pendingCloudSyncError = message
                }
            }
        }
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
                job.localCachePath = output.outputURL.path
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

        case .artifact(.subtitles(let track, let rebuiltSegments)):
            updateDub(jobID) { job in
                job.subtitleTrack = track
                let transcript = Self.preparedTranscript(
                    from: track,
                    base: job.alignedTranscript,
                    rebuiltSegments: rebuiltSegments
                )
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
              job.diarizationDiagnostics != nil || job.transcriptionAlignmentDiagnostics != nil else {
            return
        }
        let diagnostics = TranscriptionDiagnosticsReport(
            diarization: job.diarizationDiagnostics,
            alignment: job.transcriptionAlignmentDiagnostics
        )
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

    nonisolated private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio", isDirectory: true)
    }

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ClipType(fileExtension: ext) == .video {
            return ext == "mov" ? "video/quicktime" : "video/mp4"
        }
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    nonisolated private static var clipsDirectory: URL {
        dataDirectory.appendingPathComponent("Clips", isDirectory: true)
    }

    private static var snapshotURL: URL {
        dataDirectory.appendingPathComponent("workbench.json")
    }

    nonisolated private static func removeManagedClipMediaIfNeeded(_ url: URL) {
        let roots = [
            clipsDirectory.resolvingSymlinksInPath().path,
            netVideoMediaDirectory.resolvingSymlinksInPath().path,
            recordingMediaDirectory.resolvingSymlinksInPath().path,
        ]
        let candidate = url.resolvingSymlinksInPath().path
        guard roots.contains(where: { candidate.hasPrefix($0 + "/") }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func hydrate() async {
        let snapshot = await persistence.load()
        let resumableCloudDubs = snapshot?.dubs.filter { job in
            job.state == .running
                && job.placement.needsAuthentication
                && job.remoteSessionID != nil
                && job.remoteGenerationID != nil
        } ?? []
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
        schedulePersistedCloudSyncs()
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
        for job in resumableCloudDubs {
            resumePersistedCloudDub(job)
        }
        SessionIndexCoordinator.shared.reconcile(transcriptions)
    }

    private func schedulePersistedCloudSyncs() {
        let transcriptionIDs = transcriptions.compactMap { job -> UUID? in
            guard TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
                  job.state == .completed,
                  job.remoteSessionID != nil,
                  job.result != nil,
                  job.resolvedCloudSyncState != .completed else { return nil }
            return job.id
        }
        let dubIDs = dubs.compactMap { job -> UUID? in
            guard TranscriptionPlacementRouter.shouldSyncCloudEdits(job.placement),
                  job.state == .completed,
                  job.remoteSessionID != nil,
                  dubTranscriptForCloudSync(job) != nil,
                  job.resolvedCloudSyncState != .completed else { return nil }
            return job.id
        }
        for id in transcriptionIDs {
            scheduleCloudSync(forTranscription: id)
        }
        for id in dubIDs {
            scheduleCloudSync(forDub: id)
        }
    }

    private func resumePersistedCloudDub(_ persisted: WorkbenchDubJob) {
        guard flowTasks[persisted.id] == nil,
              let index = dubs.firstIndex(where: { $0.id == persisted.id }),
              let remoteSessionID = persisted.remoteSessionID,
              let generationID = persisted.remoteGenerationID,
              let cachePath = persisted.localCachePath ?? persisted.outputPath,
              !cachePath.isEmpty else { return }
        let voiceLibrary = VoiceLibraryStore.shared
        let referenceVoiceID = persisted.referenceVoiceID
            ?? voiceLibrary.defaultReference(languageCode: persisted.language)?.id
        let request = DubTaskRequest(
            jobID: persisted.id,
            script: persisted.script,
            segments: persisted.segments ?? [],
            language: persisted.language,
            model: persisted.model,
            referenceVoiceID: referenceVoiceID,
            reference: voiceLibrary.dubReference(for: referenceVoiceID),
            speakerReferences: persisted.resolvedSpeakerVoiceIDs.compactMapValues {
                voiceLibrary.dubReference(for: $0)
            },
            segmentReferences: persisted.resolvedSegmentVoiceIDs.compactMapValues {
                voiceLibrary.dubReference(for: $0)
            },
            referenceAudioID: nil,
            referenceAudioR2Key: nil,
            referenceText: persisted.referenceText,
            placement: persisted.placement,
            remoteSessionID: remoteSessionID,
            generationID: generationID,
            clientRequestID: persisted.clientRequestID ?? "desktop-dub-(persisted.id.uuidString.lowercased())",
            title: persisted.title.isEmpty ? nil : persisted.title,
            cacheURL: URL(fileURLWithPath: cachePath),
            hasSubtitleModel: persisted.placement.compute == .local
                && LLMSettingsStore.shared.hasConfiguredModel(for: .subtitleProcessing),
            resumeRemoteSession: true
        )
        dubs[index].state = .running
        dubs[index].progress = max(0.02, persisted.progress)
        dubs[index].progressMessage = "Reconnecting to VoxStudio Cloud…"
        dubs[index].flowProgressStage = .dubPreprocessing
        dubs[index].progressStep = "reconnect"
        dubs[index].errorMessage = nil
        save()

        let task = Task { [weak self] in
            guard let self else { return }
            defer { flowTasks[persisted.id] = nil }
            for await event in dubTaskAccess.events(for: request) {
                if Task.isCancelled { break }
                consumeDubTaskEvent(
                    event,
                    jobID: persisted.id,
                    resolvedReferenceVoiceID: referenceVoiceID,
                    generationID: generationID
                )
            }
            if Task.isCancelled {
                updateDub(persisted.id) {
                    guard $0.remoteGenerationID == generationID else { return }
                    $0.state = .cancelled
                    $0.errorMessage = nil
                    $0.progressMessage = "Cancelled — ready to retry"
                }
            }
        }
        flowTasks[persisted.id] = task
    }

    nonisolated static func recoveredForLaunch(
        _ job: WorkbenchTranscriptionJob
    ) -> WorkbenchTranscriptionJob {
        guard needsLaunchRecovery(job) else { return job }
        var repaired = job
        let recoverFlow = needsFlowLaunchRecovery(job)
        if recoverFlow {
            repaired.state = .ready
            repaired.progress = 0
            repaired.progressMessage = "Interrupted — ready to retry"
            repaired.progressStage = nil
            repaired.flowProgressStage = nil
            repaired.progressStep = nil
            repaired.progressCompleted = nil
            repaired.progressTotal = nil
            repaired.errorMessage = nil
        }
        if job.summaryState == .running {
            let summary = recoveredSummaryState(
                markdown: job.summaryMarkdown,
                state: job.summaryState,
                errorMessage: job.summaryErrorMessage
            )
            repaired.summaryState = summary.state
            repaired.summaryErrorMessage = summary.errorMessage
            if !recoverFlow, repaired.state == .completed {
                repaired.progressMessage = summary.state == .completed
                    ? (repaired.translationTracks.isEmpty
                        ? "Transcript and summary ready"
                        : "Transcript, translation, and summary ready")
                    : "Transcript ready — summary will retry"
            }
        }
        return repaired
    }

    nonisolated static func recoveredForLaunch(_ job: WorkbenchDubJob) -> WorkbenchDubJob {
        guard needsLaunchRecovery(job) else { return job }
        var repaired = job
        let recoverFlow = needsFlowLaunchRecovery(job)
        if recoverFlow {
            repaired.state = .ready
            repaired.progress = 0
            repaired.progressMessage = "Interrupted — ready to retry"
            repaired.flowProgressStage = nil
            repaired.progressStep = nil
            repaired.progressCompleted = nil
            repaired.progressTotal = nil
            repaired.errorMessage = nil
        }
        if job.summaryState == .running {
            let summary = recoveredSummaryState(
                markdown: job.summaryMarkdown,
                state: job.summaryState,
                errorMessage: job.summaryErrorMessage
            )
            repaired.summaryState = summary.state
            repaired.summaryErrorMessage = summary.errorMessage
            if !recoverFlow, repaired.state == .completed {
                repaired.progressMessage = summary.state == .completed
                    ? (repaired.subtitleTrack == nil
                        ? "Dub and summary ready"
                        : "Dub, subtitles, and summary ready")
                    : "Dub ready — summary will retry"
            }
        }
        return repaired
    }

    private nonisolated static func needsLaunchRecovery(_ job: WorkbenchTranscriptionJob) -> Bool {
        needsFlowLaunchRecovery(job) || job.summaryState == .running
    }

    private nonisolated static func needsLaunchRecovery(_ job: WorkbenchDubJob) -> Bool {
        needsFlowLaunchRecovery(job) || job.summaryState == .running
    }

    private nonisolated static func needsFlowLaunchRecovery(
        _ job: WorkbenchTranscriptionJob
    ) -> Bool {
        job.state == .running || job.state == .cancelling
            || (job.state == .ready && job.result == nil && job.progress > 0)
    }

    private nonisolated static func needsFlowLaunchRecovery(_ job: WorkbenchDubJob) -> Bool {
        job.state == .running || job.state == .cancelling
            || (job.state == .ready && job.outputPath == nil && job.progress > 0)
    }

    private nonisolated static func recoveredSummaryState(
        markdown: String?,
        state: WorkbenchJobState?,
        errorMessage: String?
    ) -> (state: WorkbenchJobState?, errorMessage: String?) {
        guard state == .running else { return (state, errorMessage) }
        let hasSummary = !(markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return (hasSummary ? .completed : nil, nil)
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

    private nonisolated static func remoteSession(
        from detail: VoxellaSessionDetail,
        transcriptSegments: [VoxellaTranscriptSegment] = [],
        subtitleCues: [VoxellaSubtitleCue] = [],
        mediaPlaybackURL: URL? = nil,
        mediaHasVideo: Bool = false
    ) -> WorkbenchSession {
        let resolvedMediaHasVideo = mediaHasVideo || Self.remoteSessionHasVideo(detail)
        let transcript = Self.remoteTranscript(
            segments: transcriptSegments,
            language: detail.sourceLanguage
        )
        let subtitleTrack = Self.remoteSubtitleTrack(
            cues: subtitleCues,
            language: detail.sourceLanguage
        )
        let dubSegments = detail.dubSegments.compactMap { segment -> DubRenderedSegment? in
            guard segment.startS.isFinite, segment.endS.isFinite, segment.endS >= segment.startS else {
                return nil
            }
            return DubRenderedSegment(
                index: segment.index,
                text: segment.text,
                start: segment.startS,
                end: segment.endS,
                speaker: segment.speakerLabel,
                sourceSubtitleID: segment.sourceSubtitleID
            )
        }
        let dubTranscript = Self.remoteTranscript(
            segments: detail.dubSegments.map {
                VoxellaTranscriptSegment(
                    startS: $0.startS,
                    endS: $0.endS,
                    text: $0.text,
                    speakerLabel: $0.speakerLabel,
                    words: []
                )
            },
            language: detail.sourceLanguage
        )
        let summary = detail.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDub = detail.sourceType == "dub"
            || !detail.dubSegments.isEmpty
        let netVideoSource = Self.remoteNetVideoSource(from: detail)
        let title = detail.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? detail.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Untitled session"
        return WorkbenchSession(
            id: detail.id,
            title: title.isEmpty ? "Untitled session" : title,
            createdAt: detail.createdAt ?? Date(),
            modifiedAt: detail.updatedAt ?? detail.createdAt ?? Date(),
            state: Self.remoteState(status: detail.status, resultReady: detail.resultReady),
            source: isDub ? .standaloneDub : .media,
            sessionType: WorkbenchSessionType(sourceType: detail.sourceType, isDub: isDub),
            transcriptionID: nil,
            dubID: nil,
            sourceURL: nil,
            outputURL: nil,
            durationHint: detail.durationSec,
            transcript: transcript,
            subtitleTrack: subtitleTrack,
            translationTracks: [],
            selectedTranslationLanguageCode: nil,
            summaryMarkdown: summary,
            summaryTemplateID: nil,
            summaryTemplateName: nil,
            summaryState: summary == nil ? nil : .completed,
            summaryErrorMessage: nil,
            sessionTag: nil,
            dubTranscript: dubTranscript,
            dubSubtitleTrack: nil,
            dubSegments: dubSegments,
            storage: .cloud,
            compute: detail.options?.clientCompute == .local ? .local : .cloud,
            remoteSessionID: detail.id,
            cloudSyncState: .completed,
            cloudSyncError: nil,
            remoteSourcePlaybackURL: mediaPlaybackURL,
            remoteSourceHasVideo: resolvedMediaHasVideo,
            remoteSourcePosterURL: remotePosterURL(for: detail),
            netVideoSource: netVideoSource
        )
    }

    private nonisolated static func remoteSessionHasVideo(_ detail: VoxellaSessionDetail) -> Bool {
        if detail.hasVideo == true || detail.mediaType?.lowercased() == "video" {
            return true
        }
        if detail.sourceType?.lowercased() == WorkbenchSessionType.netVideo.rawValue {
            return true
        }
        if detail.options?.recordHasVideo == true || detail.options?.uploadHasVideo == true {
            return true
        }
        let artifacts = detail.artifacts ?? [:]
        let videoFlags = [
            "record_has_video", "upload_has_video", "hls_m3u8", "hls_m3u8_path",
            "source_video_hls_path", "meeting_bot_recording_video"
        ]
        if videoFlags.contains(where: { isTruthy(artifacts[$0]) }) {
            return true
        }
        return artifacts["source_preview"]?.objectValue != nil
    }

    private nonisolated static func isTruthy(_ value: VoxellaJSONValue?) -> Bool {
        switch value {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1"].contains(value.lowercased())
        default: false
        }
    }

    private nonisolated static func localNetVideoSource(
        from job: WorkbenchTranscriptionJob
    ) -> WorkbenchNetVideoSource? {
        guard let source = localYouTubeSource(from: job) else {
            return nil
        }
        return WorkbenchNetVideoSource(
            sourceURL: source.url,
            embedURL: youtubeEmbedURL(for: source.url),
            playbackURL: nil,
            platform: .youtube,
            title: job.sessionTitle
        )
    }

    private nonisolated static func sourcePreview(
        for job: WorkbenchTranscriptionJob
    ) -> TranscriptionSourcePreview? {
        guard let source = localYouTubeSource(from: job) else {
            return nil
        }
        return TranscriptionSourcePreview(
            type: "net_video",
            platform: "youtube",
            sourceURL: source.url,
            videoID: source.videoID
        )
    }

    private nonisolated static func localYouTubeSource(
        from job: WorkbenchTranscriptionJob
    ) -> (url: URL, videoID: String)? {
        if job.netVideoPlatform?.lowercased() == "youtube",
           let sourceString = job.netVideoSourceURL,
           let sourceURL = remoteHTTPURL(sourceString),
           let videoID = job.netVideoVideoID ?? YouTubeURL.videoID(from: sourceString) {
            return (sourceURL, videoID)
        }

        let sourceURL = URL(fileURLWithPath: job.sourcePath)
            .resolvingSymlinksInPath()
        let netVideoRoot = netVideoMediaDirectory
            .resolvingSymlinksInPath()
            .path
        guard sourceURL.path.hasPrefix(netVideoRoot + "/") else { return nil }

        let filenameStem = sourceURL.deletingPathExtension().lastPathComponent
        let candidateID = filenameStem.split(separator: "-", maxSplits: 1).first.map(String.init)
        guard let videoID = candidateID.flatMap(YouTubeURL.videoID(from:)) else { return nil }
        let components = URLComponents(string: "https://www.youtube.com/watch")
        guard var components else { return nil }
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let canonicalURL = components.url else { return nil }
        return (canonicalURL, videoID)
    }

    private nonisolated static func remoteNetVideoSource(
        from detail: VoxellaSessionDetail
    ) -> WorkbenchNetVideoSource? {
        let preview = detail.artifacts?["source_preview"]?.objectValue
        let sourceString = preview?["source_url"]?.stringValue
            ?? detail.artifacts?["net_video_source_url"]?.stringValue
            ?? detail.originalFilename
        guard (detail.sourceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "net_video"
            || preview != nil),
              let sourceString,
              let sourceURL = remoteHTTPURL(sourceString) else {
            return nil
        }
        let platform = netVideoPlatform(
            detail.artifacts?["net_video_platform"]?.stringValue,
            sourceURL: sourceURL
        )
        let embedURL = remoteHTTPURL(detail.artifacts?["net_video_embed_url"]?.stringValue)
            ?? (platform == .youtube ? youtubeEmbedURL(for: sourceURL) : nil)
            ?? (platform == .ganjingworld ? ganjingWorldEmbedURL(for: sourceURL) : nil)
        let playbackURL = remoteHTTPURL(detail.artifacts?["net_video_playback_url"]?.stringValue)
        let title = detail.artifacts?["net_video_embed_probe_title"]?.stringValue
            ?? detail.title
        return WorkbenchNetVideoSource(
            sourceURL: sourceURL,
            embedURL: embedURL,
            playbackURL: playbackURL,
            platform: platform,
            title: title
        )
    }

    private nonisolated static func remoteHTTPURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        return url
    }

    private nonisolated static func remoteMediaURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let absolute = remoteHTTPURL(normalized) { return absolute }
        if normalized.hasPrefix("//") {
            return remoteHTTPURL("https:\(normalized)")
        }
        let path = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        if path.hasPrefix("/static/img/") {
            return URL(string: "https://assets.voxstudio.me")?.appending(path: path)
        }
        return VoxellaAPIConfiguration.baseURL.appending(path: path)
    }

    private nonisolated static func remotePosterURL(for detail: VoxellaSessionDetail) -> URL? {
        let artifactKeys = [
            "poster_url", "cover_url", "cover_path", "session_cover_url",
            "net_video_embed_probe_poster_url"
        ]
        let candidates = [detail.posterURL, detail.coverPath]
            + artifactKeys.map { detail.artifacts?[$0]?.stringValue }
        for candidate in candidates {
            if let url = remoteMediaURL(candidate) {
                return url
            }
        }

        guard let uploadPath = detail.uploadPath else { return nil }
        let components = uploadPath.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "customer_audio" else { return nil }
        return remoteMediaURL("/static/img/sessions/\(components[1])/\(detail.id.uuidString.lowercased())/cover.webp")
    }

    private nonisolated static func netVideoPlatform(
        _ rawValue: String?,
        sourceURL: URL
    ) -> WorkbenchNetVideoPlatform {
        if let rawValue {
            switch rawValue.lowercased() {
            case "youtube": return .youtube
            case "gettr": return .gettr
            case "ganjingworld": return .ganjingworld
            case "x", "twitter": return .x
            default: break
            }
        }
        switch sourceURL.host?.lowercased() {
        case "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be":
            return .youtube
        case "gettr.com", "www.gettr.com": return .gettr
        case "ganjingworld.com", "www.ganjingworld.com": return .ganjingworld
        case "x.com", "www.x.com", "twitter.com", "www.twitter.com": return .x
        default: return .unknown
        }
    }

    private nonisolated static func ganjingWorldEmbedURL(for sourceURL: URL) -> URL? {
        guard let host = sourceURL.host?.lowercased(),
              host == "ganjingworld.com" || host == "www.ganjingworld.com" else {
            return nil
        }
        let parts = sourceURL.path.split(separator: "/").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        let hasLocale = parts.first.map {
            $0.range(of: "^[a-z]{2}-[A-Z]{2}$", options: .regularExpression) != nil
        } ?? false
        let locale = hasLocale
            ? parts[0]
            : "zh-CN"
        return URL(string: "https://www.ganjingworld.com/\(locale)/embed/\(last.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? last)")
    }

    private nonisolated static func youtubeEmbedURL(for sourceURL: URL) -> URL? {
        guard let host = sourceURL.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) else {
            return nil
        }
        let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        let videoID: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = sourceURL.path.split(separator: "/").first.map(String.init)
        } else if components?.path == "/watch" {
            videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value
        } else {
            let parts = sourceURL.path.split(separator: "/").map(String.init)
            videoID = parts.count >= 2 && ["embed", "shorts", "live"].contains(parts[0]) ? parts[1] : nil
        }
        guard let videoID, !videoID.isEmpty,
              let escaped = videoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.voxella.studio"
        let appOrigin = "https://\(bundleID)".lowercased()
        var embedComponents = URLComponents(string: "https://www.youtube.com/embed/\(escaped)")
        embedComponents?.queryItems = [
            URLQueryItem(name: "autoplay", value: "0"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "origin", value: appOrigin),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
        ]
        return embedComponents?.url
    }

    private nonisolated static func youtubeVideoID(for sourceURL: URL) -> String? {
        guard let host = sourceURL.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) else {
            return nil
        }
        if host == "youtu.be" || host == "www.youtu.be" {
            return sourceURL.path.split(separator: "/").first.map(String.init)
        }
        let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        if components?.path == "/watch" {
            return components?.queryItems?.first(where: { $0.name == "v" })?.value
        }
        let parts = sourceURL.path.split(separator: "/").map(String.init)
        return parts.count >= 2 && ["embed", "shorts", "live"].contains(parts[0]) ? parts[1] : nil
    }

    private nonisolated static func remoteState(
        status: String?,
        resultReady: Bool?
    ) -> WorkbenchJobState {
        switch (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed", "error": .failed
        case "cancelled", "canceled", "stopped": .cancelled
        case "completed": resultReady == false ? .running : .completed
        case "queued", "processing", "running", "pending": .running
        default: .ready
        }
    }

    private nonisolated static func remoteTranscript(
        segments: [VoxellaTranscriptSegment],
        language: String?
    ) -> TranscriptionResult? {
        let validSegments = segments.enumerated().compactMap { _, segment -> TranscriptionSegment? in
            guard segment.startS.isFinite,
                  segment.endS.isFinite,
                  segment.startS >= 0,
                  segment.endS > segment.startS else { return nil }
            return TranscriptionSegment(
                text: segment.text,
                start: segment.startS,
                end: segment.endS,
                speaker: segment.speakerLabel
            )
        }
        guard !validSegments.isEmpty else { return nil }
        let words = segments.flatMap(\.words).map { word in
            TranscriptionWord(
                text: word.word,
                start: word.startS.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                end: word.endS.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                speaker: word.speaker
            )
        }
        return TranscriptionResult(
            text: validSegments.map(\.text).joined(separator: " "),
            language: language,
            words: words,
            segments: validSegments
        )
    }

    private nonisolated static func remoteSubtitleTrack(
        cues: [VoxellaSubtitleCue],
        language: String?
    ) -> SubtitleTrack? {
        let validCues = cues.enumerated().compactMap { index, cue -> SubtitleCue? in
            guard cue.startS.isFinite,
                  cue.endS.isFinite,
                  cue.startS >= 0,
                  cue.endS > cue.startS else { return nil }
            return SubtitleCue(
                id: index,
                sourceIDs: [index],
                text: cue.text,
                start: cue.startS,
                end: cue.endS,
                speaker: cue.speakerLabel
            )
        }
        guard !validCues.isEmpty else { return nil }
        return SubtitleTrack(
            sourceLanguage: language,
            language: language,
            cues: validCues
        )
    }

    private nonisolated static func combinedCloudSyncState(
        primary: DubCloudSyncState,
        secondary: DubCloudSyncState?
    ) -> DubCloudSyncState {
        let states = [primary, secondary].compactMap { $0 }
        if states.contains(.pending) { return .pending }
        if states.contains(.failed) { return .failed }
        if states.contains(.completed) { return .completed }
        return .none
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

    private static func nextCloudSyncRevision(_ revision: Int) -> Int {
        guard revision >= 0 else { return 1 }
        return revision == Int.max ? 1 : revision + 1
    }

    private func save() {
        guard hasHydrated else {
            saveRequestedBeforeHydration = true
            return
        }
        let snapshot = WorkbenchSnapshot(
            schemaVersion: 7,
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
