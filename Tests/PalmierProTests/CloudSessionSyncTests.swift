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

    @Test func invalidWordTimingsBecomeUntimedPairsForCloudSync() {
        let result = TranscriptionResult(
            text: "one two three four five",
            language: "en",
            words: [
                .init(text: "one", start: 0.1, end: 0.2, speaker: "Speaker 1"),
                .init(text: "two", start: 0.3, end: 0.3),
                .init(text: "three", start: 0.5, end: 0.4),
                .init(text: "four", start: -0.1, end: 0.2),
                .init(text: "five", start: 0.6, end: nil),
            ],
            segments: [
                .init(text: "one two three four five", start: 0, end: 1)
            ]
        )

        let normalized = result.clearingInvalidWordTimings()

        #expect(normalized.words[0] == result.words[0])
        #expect(normalized.words.dropFirst().allSatisfy { $0.start == nil && $0.end == nil })
        #expect(normalized.words.map(\.text) == result.words.map(\.text))
        #expect(normalized.segments == result.segments)
    }
}
