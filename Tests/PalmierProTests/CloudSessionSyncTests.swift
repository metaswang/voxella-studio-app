import Foundation
import Testing
@testable import PalmierPro

@Suite("Cloud session edit snapshots")
struct CloudSessionSyncTests {
    @Test func snapshotPreservesEditableSummaryTemplateMetadata() {
        let result = TranscriptionResult(
            text: "Hello",
            language: "en",
            words: [],
            segments: [TranscriptionSegment(text: "Hello", start: 0, end: 1)]
        )
        let snapshot = CloudSessionSyncSnapshot(
            jobID: UUID(),
            remoteSessionID: UUID(),
            contentKind: .transcription,
            revision: 4,
            sourceLanguage: "en",
            result: result,
            subtitleTrack: nil,
            translationTracks: [],
            dubSegments: [],
            title: "Session",
            summary: "# Summary",
            summaryTemplateID: "template-1",
            summaryTemplateName: "Meeting notes",
            summaryTemplateUserEdition: "Keep decisions",
            sessionTag: "meeting"
        )

        #expect(snapshot.revision == 4)
        #expect(snapshot.summary == "# Summary")
        #expect(snapshot.summaryTemplateID == "template-1")
        #expect(snapshot.sessionTag == "meeting")
    }

    @Test func dubSnapshotCanCarryScriptSegmentsWithoutRedubMetadata() {
        let segment = DubSegmentPayload(index: 0, text: "Edited line", start: 0, end: 1)
        let snapshot = CloudSessionSyncSnapshot(
            jobID: UUID(),
            remoteSessionID: UUID(),
            contentKind: .dub,
            revision: 2,
            sourceLanguage: "en",
            result: TranscriptionResult(
                text: "Edited line",
                language: "en",
                words: [],
                segments: [TranscriptionSegment(text: "Edited line", start: 0, end: 1)]
            ),
            subtitleTrack: nil,
            translationTracks: [],
            dubSegments: [segment],
            title: nil,
            summary: nil,
            summaryTemplateID: nil,
            summaryTemplateName: nil,
            summaryTemplateUserEdition: nil,
            sessionTag: nil
        )

        #expect(snapshot.contentKind == .dub)
        #expect(snapshot.dubSegments == [segment])
        #expect(snapshot.summary == nil)
    }
}
