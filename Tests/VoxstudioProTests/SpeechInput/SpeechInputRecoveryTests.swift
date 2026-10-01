import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Speech input limit recovery")
struct SpeechInputRecoveryTests {
    @Test func limitRetriesShorterSectionsInOrder() async throws {
        let attempts = Attempts()
        let result = try await SpeechInputRecovery.recognize(range: 0...8) { range in
            await attempts.record(range)
            if range.upperBound - range.lowerBound > 4 { throw SpeechInputError.recognitionLimit }
            return SpeechInputResult(text: range.lowerBound == 0 ? "First" : "second", languageCode: "en", engine: .qwen)
        }
        #expect(result?.text == "First second")
        #expect(await attempts.ranges == [0...8, 0...4, 4...8])
    }

    @Test func persistentLimitStopsRetrying() async {
        let attempts = Attempts()
        await #expect(throws: SpeechInputError.self) {
            try await SpeechInputRecovery.recognize(range: 0...8) { range in
                await attempts.record(range)
                throw SpeechInputError.recognitionLimit
            }
        }
        #expect(await attempts.ranges == [0...8, 0...4, 0...2])
    }

    @Test func silentSectionDoesNotDiscardRecognizedSpeech() async throws {
        let result = try await SpeechInputRecovery.recognize(range: 0...8) { range in
            if range == 0...8 { throw SpeechInputError.recognitionLimit }
            if range.lowerBound == 0 { throw LocalAIError.vadNoSpeech }
            return SpeechInputResult(text: "Speech", languageCode: "en", engine: .qwen)
        }
        #expect(result?.text == "Speech")
    }

    @Test func cancellationAfterRecognitionRejectsResult() async {
        let task = Task {
            try await SpeechInputRecovery.recognize(range: 0...8) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return SpeechInputResult(text: "Stale", languageCode: "en", engine: .qwen)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func otherFailuresAreNotRetried() async {
        let attempts = Attempts()
        await #expect(throws: SpeechInputError.self) {
            try await SpeechInputRecovery.recognize(range: 0...8) { range in
                await attempts.record(range)
                throw SpeechInputError.invalidAudioFormat
            }
        }
        #expect(await attempts.ranges.count == 1)
    }
}

private actor Attempts {
    private(set) var ranges: [ClosedRange<Double>] = []
    func record(_ range: ClosedRange<Double>) { ranges.append(range) }
}
