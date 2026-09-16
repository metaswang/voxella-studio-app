#if BUNDLED_SPEECH
import AudioCommon
import Foundation
import Testing
@testable import PalmierPro

@Suite("Long-form alignment recovery")
struct LongFormAlignmentRecoveryTests {
    private final class Aligner: WordAlignmentProviding {
        var requests: [(text: String, samples: Int)] = []
        let response: (String, Int) -> [AlignedWord]

        init(response: @escaping (String, Int) -> [AlignedWord]) {
            self.response = response
        }

        func alignmentUnits(text: String, language: String) throws -> [String] {
            text.split(separator: " ").map(String.init)
        }

        func align(audio: [Float], text: String, sampleRate: Int, language: String) -> [AlignedWord] {
            requests.append((text, audio.count))
            return response(text, audio.count)
        }
    }

    @Test func failedSingleSpanDoesNotInventTextAudioBoundaries() throws {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        let aligner = Aligner { _, _ in [] }
        let result = try LongFormAlignmentEngine.alignDetailed(
            audio: Array(repeating: 0, count: 1_200), sampleRate: 100,
            spans: [.init(text: text, startTime: 0, endTime: 12)],
            language: "English", aligner: aligner, progress: { _, _ in }
        )

        #expect(aligner.requests.count == 1)
        #expect(result.retriedAlignmentChunkCount == 0)
        #expect(result.coarseTimedUnitCount == 12)
        #expect(result.words.map(\.text).joined(separator: " ") == text)
    }

    @Test func shortSpanStillRejectsAnExcessivelyLongWord() throws {
        let aligner = Aligner { _, _ in [AlignedWord(text: "hello", startTime: 0, endTime: 8)] }
        let result = try LongFormAlignmentEngine.alignDetailed(
            audio: Array(repeating: 0, count: 800), sampleRate: 100,
            spans: [.init(text: "hello", startTime: 0, endTime: 8)],
            language: "English", aligner: aligner, progress: { _, _ in }
        )

        #expect(result.rejectedAlignmentChunkCount == 1)
        #expect(result.coarseTimedUnitCount == 1)
        #expect(result.longestRejectedUnitDuration == 8)
        #expect(result.words.first?.endTime == 2)
    }

    @Test func retryPreservesOriginalUnequalDurationSpans() throws {
        let aligner = Aligner { text, _ in
            if text == "one two three four" { return [] }
            return text.split(separator: " ").enumerated().map { index, unit in
                AlignedWord(text: String(unit), startTime: Float(index) * 0.2, endTime: Float(index + 1) * 0.2)
            }
        }
        let result = try LongFormAlignmentEngine.alignDetailed(
            audio: Array(repeating: 0, count: 1_200), sampleRate: 100,
            spans: [.init(text: "one two", startTime: 0, endTime: 2),
                    .init(text: "three four", startTime: 2, endTime: 12)],
            language: "English", aligner: aligner, progress: { _, _ in }
        )

        #expect(aligner.requests.map(\.text) == ["one two three four", "one two", "three four"])
        #expect(aligner.requests.map(\.samples) == [1_200, 250, 1_050])
        #expect(result.retriedAlignmentChunkCount == 1)
        #expect(result.coarseTimedUnitCount == 0)
        #expect(result.words.count == 4)
    }

    @Test func outOfSliceTimestampsCannotBecomeSuccessfulClampedWords() throws {
        let aligner = Aligner { _, _ in [AlignedWord(text: "hello", startTime: 100, endTime: 101)] }
        let result = try LongFormAlignmentEngine.alignDetailed(
            audio: Array(repeating: 0, count: 800), sampleRate: 100,
            spans: [.init(text: "hello", startTime: 0, endTime: 8)],
            language: "English", aligner: aligner, progress: { _, _ in }
        )

        #expect(result.rejectedAlignmentChunkCount == 1)
        #expect(result.coarseTimedUnitCount == 1)
        #expect(result.words.first?.startTime == 0)
    }

    @Test func smallBoundaryDriftRemainsRecoverable() throws {
        let aligner = Aligner { _, _ in [AlignedWord(text: "hello", startTime: 7.8, endTime: 8.08)] }
        let result = try LongFormAlignmentEngine.alignDetailed(
            audio: Array(repeating: 0, count: 800), sampleRate: 100,
            spans: [.init(text: "hello", startTime: 0, endTime: 8)],
            language: "English", aligner: aligner, progress: { _, _ in }
        )

        #expect(result.rejectedAlignmentChunkCount == 0)
        #expect(result.coarseTimedUnitCount == 0)
        #expect(result.words.first?.endTime == 8)
    }

    @Test func cancellationDuringInferenceDoesNotCommitFallback() async throws {
        let cancelled = await Task {
            let aligner = Aligner { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
            do {
                _ = try LongFormAlignmentEngine.alignDetailed(
                    audio: Array(repeating: 0, count: 800), sampleRate: 100,
                    spans: [.init(text: "hello", startTime: 0, endTime: 8)],
                    language: "English", aligner: aligner, progress: { _, _ in }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled)
    }
}
#endif
