#if BUNDLED_SPEECH
import AudioCommon
import Foundation
import MLX
import MLXAudioSTT
import Qwen3ASR
import Testing
@testable import PalmierPro

@Suite("Opt-in Whisper alignment integration replay", .serialized)
struct WhisperAlignmentReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXELLA_ALIGNMENT_REPLAY"] == "1"))
    func replaySelectedAudio() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXELLA_ALIGNMENT_REPLAY_AUDIO"])
        let replay = Task.detached {
            let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: path), targetSampleRate: 16_000)
            let duration = Double(samples.count) / 16_000
            let whisper = try await WhisperModel.fromDirectory(
                LocalModelManager.directory(for: .whisperLargeV3Turbo8Bit)
            )
            let aligner = try await Qwen3ForcedAligner.fromPretrained(
                cacheDir: LocalModelManager.directory(for: .forcedAligner), offlineMode: true
            )
            for offset in [0.0, max(0, duration / 2 - 60), max(0, duration - 120)] {
                try Task.checkCancellation()
                let end = min(duration, offset + 120)
                let audio = Array(samples[Int(offset * 16_000)..<Int(end * 16_000)])
                let localDuration = Double(audio.count) / 16_000
                let chunks = ASRChunkPlanner.chunks(
                    speechRanges: [.init(start: 0, end: localDuration)],
                    audioDuration: localDuration,
                    configuration: .init(maximumWindowDuration: 28, boundaryContextDuration: 0.5, maximumMergeGap: 0.3)
                )
                var spans: [RecognizedSpan] = []
                for chunk in chunks {
                    try Task.checkCancellation()
                    let input = MLXArray(Array(audio[Int(chunk.inputStart * 16_000)..<Int(chunk.inputEnd * 16_000)]))
                    let output = whisper.generate(audio: input, generationParameters: whisper.defaultGenerationParameters)
                    spans += ASRRecognitionSpans.ownedChunk(
                        segments: ASRRecognitionSpans.segments(from: output.segments), fallbackText: output.text,
                        recognitionStart: chunk.inputStart, recognitionEnd: chunk.inputEnd,
                        ownershipStart: chunk.ownershipStart, ownershipEnd: chunk.ownershipEnd,
                        audioDuration: localDuration
                    ).spans
                }
                let result = try LongFormAlignmentEngine.alignDetailed(
                    audio: audio, sampleRate: 16_000, spans: spans,
                    language: "English", aligner: aligner, progress: { _, _ in }
                )
                #expect(!result.words.isEmpty)
                #expect(result.words.allSatisfy {
                    $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime >= $0.startTime
                })
                print("ALIGNMENT_REPLAY offset=\(offset) duration=\(localDuration) asrSpans=\(spans.count) words=\(result.words.count) rejected=\(result.rejectedAlignmentChunkCount) retries=\(result.retriedAlignmentChunkCount) estimated=\(result.coarseTimedUnitCount) longestRejected=\(result.longestRejectedUnitDuration ?? 0) peak=\(Memory.peakMemory)")
                Memory.clearCache()
            }
        }
        try await withTaskCancellationHandler {
            try await replay.value
        } onCancel: {
            replay.cancel()
        }
    }
}
#endif
