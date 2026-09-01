import Foundation
import Testing
@testable import PalmierPro

@Suite("Workbench session deletion")
struct WorkbenchSessionDeletionTests {
    @Test func remoteOnlySessionUsesItsCloudSessionID() {
        let remoteID = UUID()
        let session = WorkbenchSession(
            id: remoteID,
            title: "Cloud session",
            createdAt: Date(),
            modifiedAt: Date(),
            state: .completed,
            source: .media,
            sessionType: .upload,
            transcriptionID: nil,
            dubID: nil,
            sourceURL: nil,
            outputURL: nil,
            transcript: nil,
            subtitleTrack: nil,
            translationTracks: [],
            selectedTranslationLanguageCode: nil,
            summaryMarkdown: nil,
            summaryTemplateID: nil,
            summaryTemplateName: nil,
            summaryState: nil,
            summaryErrorMessage: nil,
            sessionTag: nil,
            dubTranscript: nil,
            dubSubtitleTrack: nil,
            dubSegments: [],
            remoteSessionID: remoteID,
            cloudSyncError: nil
        )

        #expect(WorkbenchStore.sessionDeletionTarget(for: session) == .remote(remoteID))
    }
}
