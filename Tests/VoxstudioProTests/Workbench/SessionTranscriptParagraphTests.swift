import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Transcript speaker paragraphs")
struct SessionTranscriptParagraphTests {
    @Test func cloudSpeakerMetadataPreservesCanonicalIdentityAndCustomColor() throws {
        let options = try JSONDecoder().decode(VoxellaSessionOptions.self, from: Data(##"{"speaker_names":{"SPEAKER_01":"Cloud Narrator","SPEAKER_02":"Cloud Guest"},"speaker_colors":{"SPEAKER_01":"#1558b0","SPEAKER_02":"#1f7869"}}"##.utf8))
        #expect(options.speakerNames?["SPEAKER_01"] == "Cloud Narrator")
        let color = try #require(SessionSpeakerColor(hex: options.speakerColors!["SPEAKER_01"]!))
        #expect(abs(color.blue - 176.0 / 255) < 0.0001)
        #expect(SessionSpeakerColor(hex: "#nope00") == nil)
        let legacy = try JSONDecoder().decode(VoxellaSessionOptions.self, from: Data("{}".utf8))
        #expect(legacy.speakerNames == nil && legacy.speakerColors == nil)
        let cues = [cue(1, "SPEAKER_01"), cue(2, "SPEAKER_01"), cue(3, "SPEAKER_02")]
        #expect(SessionTranscriptParagraph.group(cues).map { $0.cues.map(\.id) } == [[1, 2], [3]])
    }
    @Test func groupsConsecutiveTurnsWithoutChangingCueIdentity() {
        let cues = [cue(1, "A"), cue(2, "A"), cue(3, "B"), cue(4, "A")]
        let groups = SessionTranscriptParagraph.group(cues)
        #expect(groups.map { $0.cues.map(\.id) } == [[1, 2], [3], [4]])
        #expect(groups[0].end == cues[1].end)
        #expect(SessionTranscriptParagraph.group(cues, aggregate: false).count == 4)
    }
    @Test func unknownSpeakersStaySeparate() {
        #expect(SessionTranscriptParagraph.group([cue(1, nil), cue(2, nil)]).count == 2)
    }
    @Test func colorsSurviveRenameAndNewColorsAvoidExistingOnes() {
        var colors = SessionSpeakerColors()
        colors.ensure(["A", "B"])
        let original = colors.values["A"]
        colors.rename("A", to: "Narrator")
        #expect(colors.values["Narrator"] == original)
        colors.ensure(["C"])
        for label in ["Narrator", "B"] {
            #expect(colors.values["C"]!.distance(to: colors.values[label]!) >= 0.10)
        }
    }
    @Test func expandedRowsKeepUniqueIdentitiesAfterSplit() {
        let cues = [cue(1, "A"), cue(2, "A"), cue(3, "A"), cue(4, "B")]
        let rows = SessionTranscriptDisplayRow.rows(cues, aggregate: true, expandedID: 1, allowsEditing: true)
        #expect(rows.map(\.id) == ["cue-1", "divider-1", "cue-2", "divider-2", "cue-3", "done-1", "divider-3", "paragraph-4"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        let expandedTarget = SessionTranscriptDisplayRow.scrollID(cueID: 3, in: cues, aggregate: true, expandedID: 1)
        #expect(expandedTarget == "cue-3")
        #expect(rows.contains { $0.id == expandedTarget })
        #expect(SessionTranscriptDisplayRow.scrollID(cueID: 3, in: cues, aggregate: true, expandedID: nil) == "paragraph-1")
        #expect(SessionTranscriptDisplayRow.scrollID(cueID: 3, in: cues, aggregate: false, expandedID: nil) == "cue-3")
    }
    private func cue(_ id: Int, _ speaker: String?) -> SubtitleCue {
        SubtitleCue(id: id, sourceIDs: [id], text: "Text \(id)", start: Double(id), end: Double(id + 1), speaker: speaker)
    }
}
