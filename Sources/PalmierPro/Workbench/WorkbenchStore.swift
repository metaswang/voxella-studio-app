import AppKit
import AVFoundation
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
        case .auto: "Auto (1–4 speakers)"
        case .one: "1 speaker (skip diarization)"
        case .two: "Expected: 2 speakers"
        case .three: "Expected: 3 speakers"
        case .four: "Expected: 4 speakers"
        }
    }
}

enum WorkbenchTranscriptTrack: String, Codable, CaseIterable, Identifiable, Sendable {
    case source
    case translation

    var id: String { rawValue }
    var label: String { self == .source ? "Source" : "Translation" }
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
    var result: TranscriptionResult?
    var editedText = ""
    var useLLMSubtitleProcessing: Bool?
    var targetLanguageCode: String?
    var subtitleTrack: SubtitleTrack?
    var translationTrack: SubtitleTrack?
    var selectedTrack: WorkbenchTranscriptTrack?
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
    var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }
    var sessionTitle: String {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayName : trimmed
    }

    func shouldProcessSubtitles(hasAPIKey: Bool) -> Bool {
        useLLMSubtitleProcessing ?? hasAPIKey
    }

    var normalizedTargetLanguageCode: String? {
        let trimmed = targetLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
            + (translationTrack?.cues.compactMap(\.speaker) ?? [])
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
}

enum DubModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium

    var id: String { rawValue }
    var label: String { self == .small ? "Small · 0.6B" : "Medium · 1.7B" }
    var modelID: LocalModelID { self == .small ? .qwenTTS06B : .qwenTTS17B }
}

struct WorkbenchDubJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var title = "Untitled project"
    var createdAt = Date()
    var modifiedAt = Date()
    var state: WorkbenchJobState = .ready
    var script = ""
    var language = "auto"
    var model: DubModelChoice = .small
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
    var progress: Double = 0
    var progressMessage = "Ready to synthesize"
    var flowProgressStage: MediaFlowStage?
    var progressStep: String?
    var progressCompleted: Int?
    var progressTotal: Int?
    var errorMessage: String?

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
    var translationTrack: SubtitleTrack?
    var dubTranscript: TranscriptionResult?
    var dubSubtitleTrack: SubtitleTrack?
    var dubSegments: [DubRenderedSegment]

    var duration: Double? {
        let transcriptEnd = transcript?.segments.map(\.end).max()
        let dubEnd = dubSegments.map(\.end).max()
        return [transcriptEnd, dubEnd].compactMap { $0 }.max()
    }

    var hasDub: Bool { outputURL != nil }
}

private struct WorkbenchSnapshot: Codable, Sendable {
    var schemaVersion: Int? = 4
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
                speakerCount: job.speakerCount.count
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
    private var audioPlayer: AVAudioPlayer?
    private var flowTasks: [UUID: Task<Void, Never>] = [:]
    private let persistence: WorkbenchPersistence
    private var hasHydrated = false
    private var saveRequestedBeforeHydration = false
    private var saveRevision = 0

    private init() {
        route = UserDefaults.standard.string(forKey: Self.routeDefaultsKey)
            .flatMap(WorkbenchRoute.init(rawValue:)) ?? .dashboard
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
                transcript: job.displayedResult ?? job.result,
                subtitleTrack: job.subtitleTrack,
                translationTrack: job.translationTrack,
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
                title: job.title,
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
                translationTrack: nil,
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
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        route = .session
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
            dubs[index].title = trimmed
            dubs[index].modifiedAt = Date()
            save()
        }
    }

    @discardableResult
    func createDub(for sessionID: UUID, track: WorkbenchTranscriptTrack = .source) -> UUID? {
        guard let transcript = transcriptions.first(where: { $0.id == sessionID }) else { return nil }
        if let existing = dubs.first(where: { $0.sourceTranscriptionID == sessionID }) {
            selectedDubID = existing.id
            route = .dub
            return existing.id
        }
        let id = addDub(title: "\(transcript.sessionTitle) Dub")
        updateDub(id) { $0.sourceTranscriptionID = sessionID }
        useTranscript(sessionID, forDub: id, track: track)
        return id
    }

    @discardableResult
    func addTranscription(sourceURL: URL) -> UUID {
        let job = WorkbenchTranscriptionJob(sourcePath: sourceURL.path)
        transcriptions.insert(job, at: 0)
        selectedTranscriptionID = job.id
        route = .transcribe
        save()
        return job.id
    }

    @discardableResult
    func addDub(script: String = "", title: String = "Untitled project") -> UUID {
        var job = WorkbenchDubJob(title: title)
        job.script = script
        job.segments = [DubSegmentPayload(index: 0, text: script)]
        if job.language == "auto" {
            job.language = Locale.current.language.languageCode?.identifier == "zh" ? "zh" : "en"
        }
        dubs.insert(job, at: 0)
        selectedDubID = job.id
        route = .dub
        save()
        return job.id
    }

    /// Ensure the Dub route always has an editable draft, matching web Create Voiceover.
    func ensureActiveDubDraft() {
        if selectedDubIndex == nil {
            if let first = dubs.first {
                selectedDubID = first.id
            } else {
                addDub()
                return
            }
        }
        guard let id = selectedDubID else { return }
        normalizeDubSegments(id)
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
        flowTasks[id]?.cancel()
        flowTasks[id] = nil
        transcriptions.removeAll { $0.id == id }
        if selectedTranscriptionID == id { selectedTranscriptionID = transcriptions.first?.id }
        save()
    }

    func deleteDub(_ id: UUID) {
        flowTasks[id]?.cancel()
        flowTasks[id] = nil
        dubs.removeAll { $0.id == id }
        if selectedDubID == id { selectedDubID = dubs.first?.id }
        save()
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
            job.translationTrack = job.translationTrack?.assigningSpeaker(speaker, from: start, to: end)
        }
    }

    func renameSpeaker(_ current: String, to replacement: String, inTranscription id: UUID) {
        updateTranscription(id) { job in
            job.result = job.result?.renamingSpeaker(current, to: replacement)
            job.subtitleTrack = job.subtitleTrack?.renamingSpeaker(current, to: replacement)
            job.translationTrack = job.translationTrack?.renamingSpeaker(current, to: replacement)
        }
    }

    func updateDub(_ id: UUID, _ mutate: (inout WorkbenchDubJob) -> Void) {
        guard let index = dubs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&dubs[index])
        dubs[index].modifiedAt = Date()
        save()
    }

    func runTranscription(_ id: UUID) {
        guard flowTasks[id] == nil,
              let index = transcriptions.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = transcriptions[index]
        transcriptions[index].state = .running
        transcriptions[index].progress = 0.02
        transcriptions[index].progressMessage = "Preparing audio…"
        transcriptions[index].progressStage = nil
        transcriptions[index].flowProgressStage = .transcription
        transcriptions[index].progressStep = "flow_started"
        transcriptions[index].progressCompleted = nil
        transcriptions[index].progressTotal = nil
        transcriptions[index].subtitleTrack = nil
        transcriptions[index].translationTrack = nil
        transcriptions[index].selectedTrack = .source
        transcriptions[index].errorMessage = nil
        save()

        let task = Task { [weak self] in
            guard let self else { return }
            defer { flowTasks[id] = nil }
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
            let request = MediaFlowRequest(
                id: id,
                input: .media(snapshot.sourceURL),
                steps: WorkbenchMediaFlowPlanner.transcriptionSteps(
                    for: snapshot,
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

    func cancelTranscription(_ id: UUID) {
        guard flowTasks[id] != nil else { return }
        flowTasks[id]?.cancel()
        updateTranscription(id) {
            $0.state = .cancelling
            $0.errorMessage = nil
            $0.progressMessage = "Cancelling media flow…"
        }
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
        save()

        let payload = DubFlowPayload(
            segments: snapshot.segments ?? [],
            language: snapshot.language,
            model: snapshot.model,
            reference: reference,
            speakerReferences: speakerReferences,
            segmentReferences: segmentReferences
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
            }
        }
        flowTasks[id] = task
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
            $0.title = "\(source.sessionTitle) \(track == .translation ? "Translation " : "")Dub"
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
            updateTranscription(jobID) {
                $0.translationTrack = track
                $0.selectedTrack = .translation
            }

        case .artifact(.alignment), .artifact(.dub):
            break
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
                job.renderedSegments = output.segments
                job.revisions = (job.revisions ?? []) + [revision]
                job.activeRevisionID = revision.id
            }

        case .artifact(.alignment(let output)):
            updateDub(jobID) { job in
                job.alignedTranscript = output.result
                job.alignmentDiagnostics = output.diagnostics
                if let activeRevisionID = job.activeRevisionID,
                   let index = job.revisions?.firstIndex(where: { $0.id == activeRevisionID }) {
                    job.revisions?[index].alignedTranscript = output.result
                    job.revisions?[index].alignmentDiagnostics = output.diagnostics
                }
            }

        case .artifact(.subtitles(let track)):
            updateDub(jobID) { job in
                job.subtitleTrack = track
                if let activeRevisionID = job.activeRevisionID,
                   let index = job.revisions?.firstIndex(where: { $0.id == activeRevisionID }) {
                    job.revisions?[index].subtitleTrack = track
                }
            }

        case .artifact:
            break
        }
    }

    func playDub(_ id: UUID) throws {
        guard let job = dubs.first(where: { $0.id == id }), let url = job.outputURL else { return }
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
    }

    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
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

    private static var snapshotURL: URL {
        dataDirectory.appendingPathComponent("workbench.json")
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
