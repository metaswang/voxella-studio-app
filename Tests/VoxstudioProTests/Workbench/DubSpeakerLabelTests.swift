import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Generated voiceover speaker labels")
struct DubSpeakerLabelTests {
    private func voice(_ name: String?) -> DubVoiceReference {
        DubVoiceReference(
            audioURL: URL(fileURLWithPath: "/tmp/\(name ?? "legacy").wav"),
            transcript: "Reference speech",
            name: name
        )
    }

    @Test func referenceNamesAreNormalizedAndLegacyReferencesKeepSourceLabels() throws {
        #expect(voice("  中文男声 \n").speakerLabel(fallback: "Host") == "中文男声")
        #expect(voice(" ").speakerLabel(fallback: "Host") == "Host")
        #expect(voice(nil).speakerLabel(fallback: nil) == nil)
        let legacyJSON = Data(#"{"audioURL":"file:///tmp/legacy.wav","transcript":"Reference speech","overrideSourceVoice":true}"#.utf8)
        let decoded = try JSONDecoder().decode(DubVoiceReference.self, from: legacyJSON)
        #expect(decoded.name == nil)
        #expect(decoded.speakerLabel(fallback: "Original") == "Original")
        let named = voice("女声")
        #expect(try JSONDecoder().decode(DubVoiceReference.self, from: JSONEncoder().encode(named)) == named)
    }

    @Test func actualSelectedVoiceSurvivesSemanticSplittingAndReindexing() throws {
        let defaultVoice = voice("默认音")
        let speakerVoice = voice("主持人参考音")
        let segmentVoice = voice("逐段参考音")
        let original = [
            DubSegmentPayload(index: 3, text: "开场。", speaker: "Host"),
            DubSegmentPayload(index: 7, text: String(repeating: "这是一段需要切割的长配音文本。", count: 8), speaker: "Host"),
            DubSegmentPayload(index: 9, text: "结尾。")
        ]
        let payload = DubFlowPayload(
            segments: original, language: "zh", model: .medium,
            reference: defaultVoice, speakerReferences: ["Host": speakerVoice],
            segmentReferences: [7: segmentVoice]
        )
        let prepared = try SemanticDubPreprocessor.prepare(
            payload,
            configuration: .init(maximumSequenceCharacters: 30)
        )
        #expect(prepared.count > original.count)
        #expect(prepared.first?.reference == speakerVoice)
        #expect(prepared.last?.reference == defaultVoice)
        let split = prepared.dropFirst().dropLast()
        #expect(split.allSatisfy { $0.reference == segmentVoice })
        #expect(split.allSatisfy { $0.reference?.speakerLabel(fallback: $0.segment.speaker) == "逐段参考音" })
        #expect(!split.contains { $0.segment.index == 7 })
        #expect(original[1].speaker == "Host")
        let rendererInput = try LocalDubFlowRenderer.prepare(payload)
        #expect(rendererInput.first?.source.speaker == "主持人参考音")
        #expect(rendererInput.last?.source.speaker == "默认音")
        #expect(rendererInput.dropFirst().dropLast().allSatisfy {
            $0.source.speaker == "逐段参考音" && $0.reference == segmentVoice
        })
    }

    @Test func defaultVoiceLabelsEveryTimedAndUntimedPreparedSegment() throws {
        for mode in [DubTimelineMode.audioFlow, .videoTimeline] {
            let payload = DubFlowPayload(
                segments: [
                    DubSegmentPayload(index: 0, text: "第一句话。", start: 0, end: 2),
                    DubSegmentPayload(index: 1, text: "第二句话。", start: 4, end: 6)
                ],
                language: "zh", model: .medium, reference: voice("中文参考音"),
                speakerReferences: [:], timelineMode: mode
            )
            let prepared = try LocalDubFlowRenderer.prepare(payload)
            #expect(!prepared.isEmpty)
            #expect(prepared.allSatisfy { $0.source.speaker == "中文参考音" })
            #expect(prepared.allSatisfy { !$0.chunks.isEmpty })
        }
    }

    @Test func completedCloudSyncUsesGeneratedLabelsAndCuts() {
        var job = WorkbenchDubJob()
        job.script = "Original draft"
        job.segments = [DubSegmentPayload(index: 7, text: "Original draft", speaker: "Host")]
        job.renderedSegments = [
            DubRenderedSegment(index: 0, text: "First cut", start: 0, end: 1, speaker: "参考音甲", sourceSubtitleID: 7),
            DubRenderedSegment(index: 1, text: "Second cut", start: 1.2, end: 2, speaker: "参考音甲", sourceSubtitleID: 7)
        ]
        let synced = WorkbenchStore.cloudDubSegments(for: job)
        #expect(synced.map(\.speaker) == ["参考音甲", "参考音甲"])
        #expect(synced.map(\.index) == [0, 1])
        #expect(synced.map(\.text) == ["First cut", "Second cut"])
        #expect(synced.map(\.start) == [0, 1.2])
        #expect(synced.map(\.end) == [1, 2])
        #expect(synced.map(\.sourceSubtitleID) == [7, 7])
        job.renderedSegments = nil
        #expect(WorkbenchStore.cloudDubSegments(for: job) == job.segments)
    }
}
