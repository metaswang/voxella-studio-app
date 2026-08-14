import Foundation
import MLX

/// Official Whisper timestamp protocol (decoding.py ApplyTimestampRules + transcribe seek).
///
/// mlx-audio-swift previously forced `<|notimestamps|>` and suppressed all timestamp
/// logits, so a window could emit EOS early while still claiming the full 30 s span.
enum WhisperTimestampDecode {
    static let timePrecision = 0.02
    static let maxInitialTimestamp = 1.0
    static let minSeekAdvance = 1.0
    static let windowCompleteSlack = 0.5

    static var maxInitialTimestampIndex: Int {
        Int((maxInitialTimestamp / timePrecision).rounded())
    }

    struct Segment: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
        var tokens: [Int]
    }

    struct WindowResult: Equatable, Sendable {
        var segments: [Segment]
        /// Seconds to advance from this window's start. Always > 0 when remaining audio exists.
        var seekAdvance: Double
    }

    static func applyTimestampRules(
        logits: MLXArray,
        generated: [Int],
        timestampBeginId: Int,
        noTimestampsId: Int,
        endOfTextId: Int
    ) -> MLXArray {
        let length = logits.dim(-1)
        guard timestampBeginId >= 0, timestampBeginId < length else { return logits }

        var mask = [Float](repeating: 0, count: length)
        if noTimestampsId >= 0, noTimestampsId < length {
            mask[noTimestampsId] = -1e9
        }

        let lastWasTimestamp = generated.last.map { $0 >= timestampBeginId } ?? false
        let penultimateWasTimestamp = generated.count < 2
            || generated[generated.count - 2] >= timestampBeginId

        if lastWasTimestamp {
            if penultimateWasTimestamp {
                for index in timestampBeginId..<length { mask[index] = -1e9 }
            } else if endOfTextId >= 0 {
                for index in 0..<min(endOfTextId, length) { mask[index] = -1e9 }
            }
        }

        let timestamps = generated.filter { $0 >= timestampBeginId }
        if let last = timestamps.last {
            let timestampLast = (lastWasTimestamp && !penultimateWasTimestamp) ? last : last + 1
            let until = min(max(timestampLast, timestampBeginId), length)
            if timestampBeginId < until {
                for index in timestampBeginId..<until { mask[index] = -1e9 }
            }
        }

        if generated.isEmpty {
            for index in 0..<timestampBeginId { mask[index] = -1e9 }
            let lastAllowed = timestampBeginId + maxInitialTimestampIndex
            if lastAllowed + 1 < length {
                for index in (lastAllowed + 1)..<length { mask[index] = -1e9 }
            }
        }

        var stepLogits = logits + MLXArray(mask).asType(logits.dtype)
        let logits1D = stepLogits.ndim > 1 ? stepLogits.squeezed() : stepLogits
        eval(logits1D)
        let values = logits1D.asArray(Float.self)
        guard values.count > timestampBeginId else { return stepLogits }

        let timestampMass = logSumExp(values[timestampBeginId..<values.count])
        let maxText = values[0..<timestampBeginId].max() ?? -.infinity
        if timestampMass > maxText {
            for index in 0..<timestampBeginId { mask[index] = -1e9 }
            stepLogits = logits + MLXArray(mask).asType(logits.dtype)
        }
        return stepLogits
    }

    static func decodeWindow(
        tokens: [Int],
        timestampBeginId: Int,
        remainingDuration: Double,
        decodeText: ([Int]) -> String
    ) -> WindowResult {
        let window = max(0, remainingDuration)
        let clippedWindow = min(Double(WhisperAudioConfig.chunkLengthSeconds), window)
        let textTokens = tokens.filter { $0 < timestampBeginId }
        let timestampTokens = tokens.filter { $0 >= timestampBeginId }

        if timestampTokens.isEmpty {
            let text = decodeText(textTokens).trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = text.isEmpty
                ? []
                : [Segment(start: 0, end: clippedWindow, text: text, tokens: tokens)]
            return WindowResult(segments: segments, seekAdvance: clippedWindow)
        }

        var segments = segmentsFromConsecutiveTimestamps(
            tokens: tokens,
            timestampBeginId: timestampBeginId,
            remainingDuration: clippedWindow,
            decodeText: decodeText
        )
        if segments.isEmpty {
            let last = timestampTokens.last ?? timestampBeginId
            let duration: Double
            if last <= timestampBeginId {
                duration = min(minSeekAdvance, clippedWindow)
            } else {
                duration = Double(last - timestampBeginId) * timePrecision
            }
            let text = decodeText(textTokens).trimmingCharacters(in: .whitespacesAndNewlines)
            let end = min(clippedWindow, max(0, duration))
            if !text.isEmpty, end > 0 {
                segments = [Segment(start: 0, end: end, text: text, tokens: tokens)]
            }
        }

        let lastEnd = segments.map(\.end).max() ?? 0
        let seek: Double
        if lastEnd >= clippedWindow - windowCompleteSlack {
            seek = clippedWindow
        } else {
            seek = max(lastEnd, min(minSeekAdvance, clippedWindow))
        }
        return WindowResult(segments: segments, seekAdvance: min(seek, window))
    }

    private static func segmentsFromConsecutiveTimestamps(
        tokens: [Int],
        timestampBeginId: Int,
        remainingDuration: Double,
        decodeText: ([Int]) -> String
    ) -> [Segment] {
        guard tokens.count >= 2 else { return [] }
        var consecutive: [Int] = []
        for index in 1..<tokens.count where tokens[index] >= timestampBeginId && tokens[index - 1] >= timestampBeginId {
            consecutive.append(index)
        }
        let singleTimestampEnding = tokens[tokens.count - 1] >= timestampBeginId
            && tokens[tokens.count - 2] < timestampBeginId
        if consecutive.isEmpty { return [] }

        var slices = consecutive
        if singleTimestampEnding { slices.append(tokens.count) }

        var segments: [Segment] = []
        var lastSlice = 0
        for current in slices {
            let sliced = Array(tokens[lastSlice..<current])
            lastSlice = current
            guard let first = sliced.first, let last = sliced.last,
                  first >= timestampBeginId, last >= timestampBeginId else { continue }
            let start = max(0, Double(first - timestampBeginId) * timePrecision)
            let end = min(remainingDuration, max(start, Double(last - timestampBeginId) * timePrecision))
            let text = decodeText(sliced).trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !text.isEmpty else { continue }
            segments.append(Segment(start: start, end: end, text: text, tokens: sliced))
        }
        return segments
    }

    private static func logSumExp(_ values: ArraySlice<Float>) -> Float {
        guard let peak = values.max() else { return -.infinity }
        if !peak.isFinite { return peak }
        var sum: Float = 0
        for value in values {
            sum += exp(value - peak)
        }
        return log(sum) + peak
    }
}
