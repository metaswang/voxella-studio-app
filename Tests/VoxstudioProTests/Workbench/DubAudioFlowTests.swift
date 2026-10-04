import Foundation
import AVFoundation
import Testing
@testable import VoxstudioPro

@Suite("Standalone dub audio flow")
struct DubAudioFlowTests {
    private static let replayInput = ProcessInfo.processInfo.environment["VOXSTUDIO_DUB_REPLAY_INPUT"]
    // The incident's imported range placed two semantic chunks at 80.8 and
    // 202.82 seconds, despite a script requiring only about 40 seconds.
    private func request() -> DubTaskRequest {
        let script = "我总能在评论区看到有人留言，说自己都没发现还没订阅。所以麻烦你确认一下有没有订阅这个频道，真的会非常感谢。这很简单，而且完全免费。经常看这个节目的朋友，只要做这件事，就能帮我们继续做下去，让节目沿着现在的方向发展。所以请确认一下你有没有订阅。非常感谢。说来也奇妙，你们已经成为我们历史的一部分，也和我们一起走过这段旅程。对此我很感激。所以，真的谢谢大家。唐纳德·霍夫曼教授。您觉得这个节目的听众，也就是此刻正在收听的人，了解现实的本质吗？他们看得懂眼前的世界吗？"
        return DubTaskRequest(
            jobID: UUID(), script: script,
            segments: [.init(index: 0, text: script, start: 80.8, end: 324.84, speaker: "Host")],
            language: "zh", model: .medium, referenceVoiceID: nil, reference: nil,
            speakerReferences: [:], segmentReferences: [:], referenceAudioID: nil,
            referenceAudioR2Key: nil, referenceText: "",
            placement: .init(storage: .local, compute: .local), remoteSessionID: nil,
            generationID: "test", clientRequestID: "test", title: nil,
            cacheURL: URL(fileURLWithPath: "/tmp/dub-audio-flow.wav"), hasSubtitleModel: false
        )
    }

    @Test func importedTimesDoNotInsertSilenceBetweenGeneratedChunks() throws {
        let request = request()
        guard case .dub(let payload) = request.localFlowRequest.steps.first else {
            Issue.record("Expected a dub flow")
            return
        }
        #expect(payload.resolvedTimelineMode == .audioFlow)
        let prepared = try LocalDubFlowRenderer.prepare(payload)
        #expect(prepared.count >= 2)
        #expect(prepared.allSatisfy { $0.source.start == nil && $0.source.end == nil })
        #expect(prepared.map(\.source.text).joined() == request.script)
        #expect(prepared.last?.source.text == "他们看得懂眼前的世界吗？")

        let generated = prepared.enumerated().map { index, segment in
            LocalDubFlowRenderer.GeneratedSegment(
                source: segment.source, samples: Array(repeating: Float(index + 1) / 10, count: 1_000)
            )
        }
        let result = LocalDubFlowRenderer.assemble(generated, sampleRate: 1_000, gapSeconds: 0.2)
        #expect(result.segments.first?.start == 0)
        #expect(result.samples.count == generated.count * 1_000 + (generated.count - 1) * 200)
        for index in 1..<result.segments.count {
            #expect(abs(result.segments[index].start - result.segments[index - 1].end - 0.2) < 0.0001)
        }
        #expect(request.segments.first?.start == 80.8)
    }

    @Test func explicitVideoTimelineStillPreservesSourcePlacement() throws {
        let request = request()
        guard case .dub(var payload) = request.localFlowRequest.steps.first else { return }
        payload.timelineMode = .videoTimeline
        let prepared = try LocalDubFlowRenderer.prepare(payload)
        #expect(prepared.first?.source.start == 80.8)
        let generated = prepared.map {
            LocalDubFlowRenderer.GeneratedSegment(source: $0.source, samples: [0.5])
        }
        let result = LocalDubFlowRenderer.assemble(generated, sampleRate: 100, gapSeconds: 0.2)
        #expect(result.segments.first?.start == 80.8)
        #expect(result.samples.prefix(8_080).allSatisfy { $0 == 0 })
        #expect(result.segments.last?.start == prepared.last?.source.start)
    }

    #if BUNDLED_SPEECH
    @Test(.enabled(if: replayInput != nil))
    func replayImportedScriptWithOriginalReferenceVoice() async throws {
        struct Input: Decodable {
            var script: String
            var segments: [DubSegmentPayload]
            var language: String
            var reference: DubVoiceReference
            var seed: UInt64
            var outputPath: String
        }
        let path = try #require(Self.replayInput)
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var request = request()
        request.script = input.script
        request.segments = input.segments
        request.language = input.language
        request.reference = input.reference
        guard case .dub(var payload) = request.localFlowRequest.steps.first else { return }
        payload.seed = input.seed
        let result = try await LocalDubFlowRenderer.shared.render(payload: payload) { progress in
            print("[dub-replay] \(progress.message)")
        }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let outputURL = URL(fileURLWithPath: input.outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: result.outputURL, to: outputURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.segments).write(to: outputURL.deletingPathExtension().appendingPathExtension("json"))
        let audio = try AVAudioFile(forReading: outputURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        print("[dub-replay] duration=\(duration)s output=\(outputURL.path)")
        #expect(duration > 10 && duration < 80)
        #expect(result.segments.first?.start == 0)
        #expect(result.segments.last?.text == "他们看得懂眼前的世界吗？")
        for index in 1..<result.segments.count {
            #expect(abs(result.segments[index].start - result.segments[index - 1].end - 0.2) < 0.0001)
        }
    }
    #endif
}
