import Foundation

struct CompletedTranscriptionArtifacts: Sendable {
    let rawResult: TranscriptionResult
    let result: TranscriptionResult
    let subtitleTrack: SubtitleTrack?
    let translationTracks: [WorkbenchTranslationTrack]
    let diarizationDiagnostics: DiarizationDiagnostics?
    let alignmentDiagnostics: TranscriptionAlignmentDiagnostics?
    let processedSourcePath: String?

    func apply(to job: inout WorkbenchTranscriptionJob) {
        let selectedLanguage = translationTracks.first?.languageCode
        job.result = result
        job.editedText = result.text
        job.subtitleTrack = subtitleTrack
        job.translationTracks = translationTracks
        job.selectedTranslationLanguageCode = selectedLanguage
        job.selectedTrack = selectedLanguage == nil ? .source : .translation
        job.diarizationDiagnostics = diarizationDiagnostics
        job.transcriptionAlignmentDiagnostics = alignmentDiagnostics
        if let processedSourcePath {
            job.sourcePath = processedSourcePath
            job.clipStartMs = nil
            job.clipEndMs = nil
        }
        job.summaryMarkdown = nil
        job.summaryTemplateID = nil
        job.summaryTemplateName = nil
        job.summaryTemplateUserEdition = nil
        job.sessionTag = nil
        job.internalSummary = nil
        job.summaryState = nil
        job.summaryErrorMessage = nil
    }
}

enum TranscriptionCommitPolicy {
    static func shouldCommit(
        status: MediaJobStatus,
        artifacts: CompletedTranscriptionArtifacts?
    ) -> Bool {
        status == .completed && artifacts != nil
    }

    @discardableResult
    static func markLinkedCompletedDubsOutdated(
        _ dubs: inout [WorkbenchDubJob],
        sourceTranscriptionID: UUID,
        now: Date = Date()
    ) -> Bool {
        var changed = false
        for index in dubs.indices where dubs[index].sourceTranscriptionID == sourceTranscriptionID
            && dubs[index].state == .completed {
            dubs[index].progressMessage = "Source subtitles changed — redub to update"
            dubs[index].modifiedAt = now
            changed = true
        }
        return changed
    }
}
