import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Cloud dub speaker labels")
struct CloudDubSpeakerLabelTests {
    private func voice(_ name: String?) -> DubVoiceReference {
        DubVoiceReference(
            audioURL: URL(fileURLWithPath: "/tmp/reference.wav"),
            transcript: "Reference speech",
            name: name
        )
    }

    private func request(
        segments: [DubSegmentPayload] = [],
        script: String = "Hello",
        reference: DubVoiceReference? = nil,
        speakerReferences: [String: DubVoiceReference] = [:],
        segmentReferences: [Int: DubVoiceReference] = [:]
    ) -> DubTaskRequest {
        DubTaskRequest(
            jobID: UUID(),
            script: script,
            segments: segments,
            language: "en",
            model: .medium,
            referenceVoiceID: nil,
            reference: reference,
            speakerReferences: speakerReferences,
            segmentReferences: segmentReferences,
            referenceAudioID: nil,
            referenceAudioR2Key: "reference.wav",
            referenceText: "Reference speech",
            placement: TaskPlacement(storage: .cloud, compute: .cloud),
            remoteSessionID: nil,
            generationID: "generation",
            clientRequestID: "request",
            title: nil,
            cacheURL: URL(fileURLWithPath: "/tmp/dub.m4a"),
            hasSubtitleModel: false
        )
    }

    private func remote(_ rows: [[String: Any]]) throws -> [VoxellaDubSegment] {
        try JSONDecoder().decode(
            [VoxellaDubSegment].self,
            from: JSONSerialization.data(withJSONObject: rows)
        )
    }

    @Test func cloudGenerationUsesSegmentThenSpeakerThenDefaultVoiceNames() {
        let segments = [
            DubSegmentPayload(index: 7, text: "A", speaker: "Alice", sourceSubtitleID: 70,
                              options: ["reference_audio_r2_key": "guest.wav"]),
            DubSegmentPayload(index: 8, text: "B", speaker: "Alice"),
            DubSegmentPayload(index: 9, text: "C", speaker: "Bob"),
            DubSegmentPayload(index: 10, text: "D"),
        ]
        let request = request(
            segments: segments,
            reference: voice(" Narrator "),
            speakerReferences: ["Alice": voice("Host")],
            segmentReferences: [7: voice("Guest")]
        )
        let labeled = CloudDubTaskAccess.labeledSegments(for: request)

        #expect(labeled.map(\.speaker) == ["Guest", "Host", "Narrator", "Narrator"])
        #expect(labeled.map(\.index) == segments.map(\.index))
        #expect(labeled[0].sourceSubtitleID == 70)
        #expect(labeled[0].options == segments[0].options)
        #expect(request.segments == segments)
    }

    @Test func scriptOnlyCloudGenerationLabelsItsDefaultVoice() {
        let request = request(script: "  Hello world.  ", reference: voice("Narrator"))
        let labeled = CloudDubTaskAccess.labeledSegments(for: request)
        #expect(labeled.count == 1)
        #expect(labeled.first?.text == "Hello world.")
        #expect(labeled.first?.speaker == "Narrator")
        #expect(labeled.first?.index == 0)
    }

    @Test func downloadedCloudOutputRepairsMissingAndSourceSpeakerLabels() throws {
        let request = request(
            segments: [
                DubSegmentPayload(index: 7, text: "A", speaker: "Alice", sourceSubtitleID: 70),
                DubSegmentPayload(index: 8, text: "B", speaker: "Alice"),
                DubSegmentPayload(index: 9, text: "C", speaker: "Bob"),
            ],
            reference: voice("Narrator"),
            speakerReferences: ["Alice": voice("Host")],
            segmentReferences: [7: voice("Guest")]
        )
        let remote = try remote([
            ["index": 7, "text": "A", "start_s": 0, "end_s": 1, "speaker_label": "Alice"],
            ["index": 8, "text": "B", "start_s": 1, "end_s": 2],
            ["index": 9, "text": "C", "start_s": 2, "end_s": 3, "speaker_label": "Bob"],
            ["index": 100, "text": "A again", "start_s": 3, "end_s": 4,
             "source_subtitle_id": 70],
        ])
        let rendered = CloudDubTaskAccess.renderedSegments(from: remote, request: request)
        #expect(rendered.map(\.speaker) == ["Guest", "Host", "Narrator", "Guest"])
        #expect(rendered.map(\.index) == [7, 8, 9, 100])
        #expect(rendered.last?.sourceSubtitleID == 70)
    }

    @Test func cloudFallbackPreservesOriginalIndexesAndUsesVoiceNames() {
        let request = request(
            segments: [DubSegmentPayload(index: 12, text: "Hello", start: 2, end: 3, speaker: "Alice")],
            reference: voice("Narrator")
        )
        let rendered = CloudDubTaskAccess.renderedSegments(from: [], request: request)
        #expect(rendered.map(\.index) == [12])
        #expect(rendered.map(\.speaker) == ["Narrator"])
        #expect(rendered.first?.start == 2)
        #expect(rendered.first?.end == 3)
    }

    @Test func cloudSemanticRenumberingPreservesAlreadyResolvedVoiceNames() throws {
        let request = request(
            segments: [DubSegmentPayload(index: 12, text: "Hello", speaker: "Alice")],
            reference: voice("Narrator"),
            speakerReferences: ["Alice": voice("Host")]
        )
        let remote = try remote([
            ["index": 0, "text": "Hello", "start_s": 0, "end_s": 1, "speaker_label": "Host"],
        ])
        #expect(CloudDubTaskAccess.renderedSegments(from: remote, request: request).first?.speaker == "Host")
    }

    @Test func cloudSemanticSplitIndexCollisionKeepsTheRenderedVoiceName() throws {
        let request = request(
            segments: [
                DubSegmentPayload(index: 0, text: "A first. A second.", speaker: "Speaker 1"),
                DubSegmentPayload(index: 1, text: "B first.", speaker: "Speaker 2"),
            ],
            speakerReferences: ["Speaker 1": voice("A"), "Speaker 2": voice("B")]
        )
        let remote = try remote([
            ["index": 0, "text": "A first.", "start_s": 0, "end_s": 1, "speaker_label": "A"],
            ["index": 1, "text": "A second.", "start_s": 1, "end_s": 2, "speaker_label": "A"],
            ["index": 2, "text": "B first.", "start_s": 2, "end_s": 3, "speaker_label": "B"],
        ])
        #expect(CloudDubTaskAccess.renderedSegments(from: remote, request: request).map(\.speaker) == ["A", "A", "B"])
    }

    @Test func unnamedReferenceSourceLabelsDoNotOverrideTheSelectedReferenceName() throws {
        let request = request(
            segments: [
                DubSegmentPayload(index: 0, text: "Named", speaker: "Source"),
                DubSegmentPayload(index: 1, text: "Unnamed", speaker: "Original"),
            ],
            reference: voice("Narrator"),
            segmentReferences: [1: voice(nil)]
        )
        let remote = try remote([
            ["index": 0, "text": "Named", "start_s": 0, "end_s": 1, "speaker_label": "Original"],
        ])
        #expect(CloudDubTaskAccess.renderedSegments(from: remote, request: request).first?.speaker == "Narrator")
    }

    @Test func uniqueSourceSubtitleIdentityOverridesALabelMatchingAnotherVoice() throws {
        let request = request(
            segments: [
                DubSegmentPayload(index: 0, text: "Narrator speech", speaker: "A", sourceSubtitleID: 100),
                DubSegmentPayload(index: 1, text: "Other speech", speaker: "B", sourceSubtitleID: 200),
            ],
            speakerReferences: ["A": voice("Narrator"), "B": voice("A")]
        )
        let remote = try remote([
            ["index": 0, "text": "Narrator speech", "start_s": 0, "end_s": 1,
             "speaker_label": "A", "source_subtitle_id": 100],
        ])
        #expect(CloudDubTaskAccess.renderedSegments(from: remote, request: request).first?.speaker == "Narrator")
    }

    @Test func unnamedReferencesAndUnselectedVoicesPreserveAvailableSpeakerLabels() throws {
        let segment = DubSegmentPayload(index: 0, text: "Hello", speaker: "Original")
        let unnamed = request(segments: [segment], reference: voice(" "))
        #expect(CloudDubTaskAccess.labeledSegments(for: unnamed).first?.speaker == "Original")
        let remote = try remote([
            ["index": 0, "text": "Hello", "start_s": 0, "end_s": 1, "speaker_label": "Stored name"],
        ])
        #expect(CloudDubTaskAccess.renderedSegments(from: remote, request: unnamed).first?.speaker == "Stored name")
        #expect(CloudDubTaskAccess.labeledSegments(for: request(segments: [segment])).first?.speaker == "Original")
    }
}
