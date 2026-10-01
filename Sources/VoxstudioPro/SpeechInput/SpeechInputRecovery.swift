import Foundation

enum SpeechInputRecovery {
    static let minimumRetryDuration: Double = 2

    static func recognize(
        range: ClosedRange<Double>,
        operation: @Sendable (ClosedRange<Double>) async throws -> SpeechInputResult
    ) async throws -> SpeechInputResult? {
        try Task.checkCancellation()
        do {
            let result = try await operation(range)
            try Task.checkCancellation()
            return result
        } catch SpeechInputError.recognitionLimit {
            let duration = range.upperBound - range.lowerBound
            guard duration > minimumRetryDuration else { throw SpeechInputError.recognitionLimit }
            let midpoint = range.lowerBound + duration / 2
            let first = try await recognize(range: range.lowerBound...midpoint, operation: operation)
            let second = try await recognize(range: midpoint...range.upperBound, operation: operation)
            try Task.checkCancellation()
            guard let first else { return second }
            guard let second else { return first }
            return SpeechInputResult(
                text: TranscriptSegmenter.joinedText([first.text, second.text]),
                languageCode: first.languageCode ?? second.languageCode,
                engine: first.engine
            )
        } catch LocalAIError.vadNoSpeech {
            try Task.checkCancellation()
            return nil
        } catch LocalAIError.audioTooQuiet {
            try Task.checkCancellation()
            return nil
        }
    }
}
