import Foundation
import Observation

/// Provenance of a dub script imported from an SRT/VTT file.
struct WorkbenchDubSubtitleImport: Codable, Equatable, Sendable {
    var fileName: String
    var coverage: DubPunctuationRestorer.Coverage
    var insertedCount: Int
    /// Cue text without inserted punctuation, for undo.
    var originalText: String
    /// Script as last written by the importer or AI pass; edits after that hide undo.
    var restoredText: String
    var aiApplied = false
}

extension WorkbenchStore {
    /// True when importing would overwrite text the user already typed.
    func dubHasScript(_ id: UUID) -> Bool {
        guard let job = dubs.first(where: { $0.id == id }) else { return false }
        return (job.segments ?? []).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Replaces the dub draft with one segment holding the subtitle text.
    /// Timestamps are intentionally dropped so generation runs as audio flow.
    func importSubtitleScript(_ url: URL, forDub id: UUID) throws {
        guard let job = dubs.first(where: { $0.id == id }) else { return }
        let cues = try SubtitleScriptImporter.load(url)
        let sample = cues.prefix(200).map(\.text).joined(separator: " ")
        let detected = DubPunctuationRestorer.detectedLanguage(sample)
        let language = detected ?? (job.language == "auto" ? Self.preferredDubLanguageCode : job.language)
        let result = DubPunctuationRestorer.restore(cues, language: language)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleScriptImporter.Failure.noSpeech
        }
        let firstVoice = job.resolvedSegmentVoiceIDs[job.segments?.map(\.index).min() ?? 0]
        updateDub(id) {
            $0.segments = [DubSegmentPayload(index: 0, text: result.text)]
            $0.script = result.text
            $0.segmentVoiceIDs = firstVoice.map { [0: $0] }
            $0.speakerVoiceIDs = nil
            $0.sourceTranscriptionID = nil
            if detected != nil { $0.language = language }
            if !SessionTitlePolicy.isUserProvided($0.title) {
                $0.title = SessionTitlePolicy.normalizedUserTitle(url.deletingPathExtension().lastPathComponent) ?? ""
            }
            $0.subtitleImport = WorkbenchDubSubtitleImport(
                fileName: url.lastPathComponent,
                coverage: result.coverage,
                insertedCount: result.insertedCount,
                originalText: result.originalText,
                restoredText: result.text
            )
            $0.state = .notStarted
            $0.progress = 0
            $0.progressMessage = $0.outputURL == nil
                ? "Ready to synthesize"
                : "Configuration changed — ready to regenerate"
            $0.errorMessage = nil
        }
        Log.app.info("Dub subtitle import: cues=\(cues.count) coverage=\(result.coverage.rawValue) inserted=\(result.insertedCount) language=\(language)")
    }

    func undoSubtitlePunctuation(_ id: UUID) {
        guard let info = dubs.first(where: { $0.id == id })?.subtitleImport else { return }
        updateDubSegmentText(id, segmentIndex: 0, text: info.originalText)
        updateDub(id) {
            $0.subtitleImport?.restoredText = info.originalText
            $0.subtitleImport?.insertedCount = 0
            $0.subtitleImport?.aiApplied = false
        }
    }

    func dismissSubtitleImportNotice(_ id: UUID) {
        updateDub(id) { $0.subtitleImport = nil }
    }

    fileprivate func applyAIPunctuation(_ id: UUID, text: String) {
        updateDubSegmentText(id, segmentIndex: 0, text: text)
        updateDub(id) {
            $0.subtitleImport?.restoredText = text
            $0.subtitleImport?.aiApplied = true
        }
    }

    nonisolated static var preferredDubLanguageCode: String {
        Locale.current.language.languageCode?.identifier == "zh" ? "zh" : "en"
    }
}

@MainActor
@Observable
final class DubPunctuationController {
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(store: WorkbenchStore, jobID: UUID) {
        guard !isRunning,
              let job = store.dubs.first(where: { $0.id == jobID }),
              let segment = job.segments?.first,
              job.segments?.count == 1 else { return }
        let snapshot = DubRewriteSnapshot(job: job)
        let request = DubPunctuationRequest(script: segment.text, language: job.language)
        let attempt = UUID()
        generation = attempt
        errorMessage = nil
        notice = nil
        isRunning = true
        task = Task { [weak self] in
            do {
                let client = try await AITransportPolicy.makeTextClient(for: .subtitleProcessing)
                let outcome = try await request.complete(using: client)
                try Task.checkCancellation()
                guard let self, generation == attempt else { return }
                guard let current = store.dubs.first(where: { $0.id == jobID }),
                      snapshot.matches(current, selectedID: store.selectedDubIndex.map({ store.dubs[$0].id })) else {
                    throw DubRewriteError.changed
                }
                isRunning = false
                task = nil
                guard outcome.acceptedBatches > 0 else {
                    errorMessage = L10n.string("AI punctuation changed words, so the original punctuation was kept.")
                    return
                }
                if outcome.text != segment.text { store.applyAIPunctuation(jobID, text: outcome.text) }
                if outcome.acceptedBatches < outcome.totalBatches {
                    notice = L10n.format(
                        "AI punctuation applied to %@ of %@ parts; the rest kept the original punctuation.",
                        outcome.acceptedBatches, outcome.totalBatches
                    )
                }
            } catch {
                guard let self, generation == attempt else { return }
                isRunning = false
                task = nil
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }
}
