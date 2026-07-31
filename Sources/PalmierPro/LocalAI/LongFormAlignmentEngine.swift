import Foundation

#if BUNDLED_SPEECH
import AudioCommon
import Qwen3ASR
#endif

struct RecognizedSpan: Equatable, Sendable {
    let text: String
    let startTime: Double
    let endTime: Double

    var duration: Double { endTime - startTime }
}

#if BUNDLED_SPEECH
struct LongFormAlignmentResult: Sendable {
    let words: [AlignedWord]
    let coarseTimedUnitCount: Int
}
#endif

enum LongFormAlignmentError: LocalizedError, Equatable {
    case invalidSpan
    case missingTokenizer
    case emptyAlignmentUnits
    case incompleteAlignment(expected: Int, actual: Int)
    case invalidTimestamps(chunk: Int, unit: Int, start: Double, end: Double, previousStart: Double, duration: Double)
    case timestampPlateau(chunk: Int, start: Double)
    case insufficientAnchorCoverage(actual: Double, required: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSpan:
            "The transcript contains an invalid audio time range."
        case .missingTokenizer:
            "The local forced aligner tokenizer is unavailable."
        case .emptyAlignmentUnits:
            "The transcript does not contain alignable text."
        case .incompleteAlignment(let expected, let actual):
            "Local word alignment was incomplete (expected \(expected) units, received \(actual))."
        case .invalidTimestamps(let chunk, let unit, let start, let end, let previousStart, let duration):
            "The local word aligner returned invalid timestamps in chunk \(chunk + 1), unit \(unit + 1) "
                + "(start \(start), end \(end), previous \(previousStart), duration \(duration))."
        case .timestampPlateau(let chunk, let start):
            "The local word aligner returned a timestamp plateau in chunk \(chunk + 1) near \(start)s."
        case .insufficientAnchorCoverage(let actual, let required):
            "The edited transcript changed too much to preserve reliable timing (\(Int(actual * 100))% anchors; \(Int(required * 100))% required)."
        }
    }
}

/// Language-neutral helpers used to preserve monotonic anchors when an edited
/// transcript is aligned again. Text splitting remains the aligner's job; this
/// type only compares the units emitted by that tokenizer.
enum AlignmentAnchorMatcher {
    static func normalized(_ unit: String) -> String {
        String(unit.lowercased().unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .decimalNumber,
                 .letterNumber, .otherNumber, .nonspacingMark,
                 .spacingMark, .enclosingMark:
                true
            default:
                false
            }
        })
    }

    /// Hirschberg LCS: Myers-like monotonic anchors without allocating an
    /// O(n*m) matrix for long transcripts. Returns old/new index pairs.
    static func matchingPairs(old: [String], new: [String]) -> [(old: Int, new: Int)] {
        let lhs = old.map(normalized)
        let rhs = new.map(normalized)
        return hirschberg(
            lhs,
            lhsRange: 0..<lhs.count,
            rhs,
            rhsRange: 0..<rhs.count
        )
    }

    private static func hirschberg(
        _ lhs: [String],
        lhsRange: Range<Int>,
        _ rhs: [String],
        rhsRange: Range<Int>
    ) -> [(old: Int, new: Int)] {
        guard !lhsRange.isEmpty, !rhsRange.isEmpty else { return [] }
        if lhsRange.count == 1 {
            let index = lhsRange.lowerBound
            guard !lhs[index].isEmpty,
                  let match = rhsRange.first(where: { rhs[$0] == lhs[index] }) else { return [] }
            return [(index, match)]
        }

        let midpoint = lhsRange.lowerBound + lhsRange.count / 2
        let leftScores = lcsLengths(
            Array(lhs[lhsRange.lowerBound..<midpoint]),
            Array(rhs[rhsRange])
        )
        let rightScores = lcsLengths(
            Array(lhs[midpoint..<lhsRange.upperBound].reversed()),
            Array(rhs[rhsRange].reversed())
        )
        let rhsCount = rhsRange.count
        var bestOffset = 0
        var bestScore = -1
        for offset in 0...rhsCount {
            let score = leftScores[offset] + rightScores[rhsCount - offset]
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        let rhsSplit = rhsRange.lowerBound + bestOffset
        return hirschberg(
            lhs,
            lhsRange: lhsRange.lowerBound..<midpoint,
            rhs,
            rhsRange: rhsRange.lowerBound..<rhsSplit
        ) + hirschberg(
            lhs,
            lhsRange: midpoint..<lhsRange.upperBound,
            rhs,
            rhsRange: rhsSplit..<rhsRange.upperBound
        )
    }

    private static func lcsLengths(_ lhs: [String], _ rhs: [String]) -> [Int] {
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        for left in lhs {
            current[0] = 0
            for index in rhs.indices {
                current[index + 1] = left == rhs[index] && !left.isEmpty
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous
    }
}

#if BUNDLED_SPEECH
struct AlignmentModelCapabilities: Sendable {
    var targetChunkDuration: Double = 120
    var maximumChunkDuration: Double = 180
    var contextDuration: Double = 0.5
    var editedTranscriptMinimumAnchorCoverage: Double = 0.65
    var timestampTolerance: Double = 0.16
    var plateauMinimumUnitCount = 5
    var maximumRetryDepth = 3
    var minimumRetryUnitCount = 4

    static let qwen3ForcedAligner = AlignmentModelCapabilities()
}

enum LongFormAlignmentEngine {
    private struct SpanAlignmentResult {
        let words: [AlignedWord]
        let coarseTimedUnitCount: Int
    }

    private struct AlignmentWorkChunk {
        let sourceSpans: [RecognizedSpan]

        var mergedSpan: RecognizedSpan {
            RecognizedSpan(
                text: sourceSpans.map(\.text).joined(separator: " "),
                startTime: sourceSpans.first!.startTime,
                endTime: sourceSpans.map(\.endTime).max()!
            )
        }
    }

    /// Coalesce fine-grained ASR/VAD spans into model-sized alignment chunks.
    /// Whisper often emits many short segments; aligning each one independently
    /// is both slow and unstable because a dense transcript can leave the
    /// timestamp classifier too little acoustic context. Chunking is based only
    /// on time and model capabilities, not language or script.
    static func alignmentChunks(
        from spans: [RecognizedSpan],
        capabilities: AlignmentModelCapabilities = .qwen3ForcedAligner
    ) throws -> [RecognizedSpan] {
        try alignmentWorkChunks(from: spans, capabilities: capabilities).map(\.mergedSpan)
    }

    private static func alignmentWorkChunks(
        from spans: [RecognizedSpan],
        capabilities: AlignmentModelCapabilities
    ) throws -> [AlignmentWorkChunk] {
        guard capabilities.targetChunkDuration > 0,
              capabilities.targetChunkDuration <= capabilities.maximumChunkDuration else {
            throw LongFormAlignmentError.invalidSpan
        }

        var chunks: [AlignmentWorkChunk] = []
        var pending: [RecognizedSpan] = []
        var previousStart = -Double.infinity
        for span in spans {
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  span.startTime.isFinite, span.endTime.isFinite,
                  span.startTime >= 0, span.endTime > span.startTime,
                  span.startTime + capabilities.timestampTolerance >= previousStart else {
                throw LongFormAlignmentError.invalidSpan
            }
            previousStart = span.startTime
            let normalized = RecognizedSpan(
                text: text,
                startTime: span.startTime,
                endTime: span.endTime
            )
            guard let first = pending.first else {
                pending = [normalized]
                continue
            }

            let candidateEnd = max(pending.map(\.endTime).max()!, normalized.endTime)
            if candidateEnd - first.startTime <= capabilities.targetChunkDuration {
                pending.append(normalized)
            } else {
                chunks.append(AlignmentWorkChunk(sourceSpans: pending))
                pending = [normalized]
            }
        }
        if !pending.isEmpty { chunks.append(AlignmentWorkChunk(sourceSpans: pending)) }
        return chunks
    }

    static func align(
        audio: [Float],
        sampleRate: Int,
        spans: [RecognizedSpan],
        language: String,
        aligner: Qwen3ForcedAligner,
        capabilities: AlignmentModelCapabilities = .qwen3ForcedAligner,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> [AlignedWord] {
        try alignDetailed(
            audio: audio,
            sampleRate: sampleRate,
            spans: spans,
            language: language,
            aligner: aligner,
            capabilities: capabilities,
            progress: progress
        ).words
    }

    static func alignDetailed(
        audio: [Float],
        sampleRate: Int,
        spans: [RecognizedSpan],
        language: String,
        aligner: Qwen3ForcedAligner,
        capabilities: AlignmentModelCapabilities = .qwen3ForcedAligner,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> LongFormAlignmentResult {
        guard sampleRate > 0, !audio.isEmpty, !spans.isEmpty else {
            throw LongFormAlignmentError.invalidSpan
        }
        let chunks = try alignmentWorkChunks(from: spans, capabilities: capabilities)
        let audioDuration = Double(audio.count) / Double(sampleRate)
        var result: [AlignedWord] = []
        var coarseTimedUnitCount = 0
        var previousStart: Float = 0

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let span = chunk.mergedSpan
            guard span.startTime.isFinite, span.endTime.isFinite,
                  span.startTime >= 0, span.endTime > span.startTime,
                  span.startTime < audioDuration + capabilities.timestampTolerance else {
                throw LongFormAlignmentError.invalidSpan
            }
            let boundedEnd = min(span.endTime, audioDuration)
            guard boundedEnd > span.startTime else { throw LongFormAlignmentError.invalidSpan }
            progress(
                Double(index) / Double(chunks.count),
                "Aligning chunk \(index + 1) of \(chunks.count)…"
            )
            let alignedChunk = try alignSpan(
                audio: audio,
                audioDuration: audioDuration,
                sampleRate: sampleRate,
                chunk: chunk,
                language: language,
                aligner: aligner,
                capabilities: capabilities,
                chunkIndex: index,
                retryDepth: 0,
                progressFraction: Double(index) / Double(chunks.count),
                progress: progress
            )

            coarseTimedUnitCount += alignedChunk.coarseTimedUnitCount
            for word in alignedChunk.words {
                let start = max(previousStart, min(Float(boundedEnd), max(Float(span.startTime), word.startTime)))
                let end = min(Float(boundedEnd), max(start, word.endTime))
                result.append(AlignedWord(text: word.text, startTime: start, endTime: end))
                previousStart = start
            }
            progress(
                Double(index + 1) / Double(chunks.count),
                "Aligned chunk \(index + 1) of \(chunks.count)"
            )
        }
        guard !result.isEmpty else { throw LongFormAlignmentError.emptyAlignmentUnits }
        return LongFormAlignmentResult(
            words: result,
            coarseTimedUnitCount: coarseTimedUnitCount
        )
    }

    private static func alignSpan(
        audio: [Float],
        audioDuration: Double,
        sampleRate: Int,
        chunk: AlignmentWorkChunk,
        language: String,
        aligner: Qwen3ForcedAligner,
        capabilities: AlignmentModelCapabilities,
        chunkIndex: Int,
        retryDepth: Int,
        progressFraction: Double,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> SpanAlignmentResult {
        try Task.checkCancellation()
        let span = chunk.mergedSpan
        let boundedEnd = min(span.endTime, audioDuration)
        let sliceStartTime = max(0, span.startTime - capabilities.contextDuration)
        let sliceEndTime = min(audioDuration, boundedEnd + capabilities.contextDuration)
        guard span.startTime >= 0, boundedEnd > span.startTime,
              sliceEndTime - sliceStartTime <= capabilities.maximumChunkDuration + capabilities.timestampTolerance else {
            throw LongFormAlignmentError.invalidSpan
        }
        let startSample = max(0, Int((sliceStartTime * Double(sampleRate)).rounded(.down)))
        let endSample = min(audio.count, Int((sliceEndTime * Double(sampleRate)).rounded(.up)))
        guard endSample > startSample else { throw LongFormAlignmentError.invalidSpan }

        let units = try alignmentUnits(for: span.text, language: language, aligner: aligner)
        let local = aligner.align(
            audio: Array(audio[startSample..<endSample]),
            text: span.text,
            sampleRate: sampleRate,
            language: language
        )

        do {
            guard local.count == units.count else {
                throw LongFormAlignmentError.incompleteAlignment(expected: units.count, actual: local.count)
            }
            try validateRaw(
                local,
                chunkIndex: chunkIndex,
                sliceDuration: sliceEndTime - sliceStartTime,
                capabilities: capabilities
            )
            let normalized = local.map {
                let absoluteStart = Float(sliceStartTime) + $0.startTime
                let absoluteEnd = Float(sliceStartTime) + $0.endTime
                let start = min(Float(boundedEnd), max(Float(span.startTime), absoluteStart))
                let end = min(Float(boundedEnd), max(start, absoluteEnd))
                return AlignedWord(
                    text: $0.text,
                    startTime: start,
                    endTime: end
                )
            }
            try validateNormalized(
                normalized,
                chunkIndex: chunkIndex,
                span: span,
                capabilities: capabilities
            )
            return SpanAlignmentResult(words: normalized, coarseTimedUnitCount: 0)
        } catch let error as LongFormAlignmentError {
            guard retryDepth < capabilities.maximumRetryDepth,
                  units.count >= capabilities.minimumRetryUnitCount,
                  span.duration > max(1, capabilities.contextDuration * 2) else {
                let fallback = try coarseTiming(
                    for: chunk.sourceSpans,
                    language: language,
                    aligner: aligner
                )
                guard !fallback.isEmpty else { throw error }
                progress(
                    progressFraction,
                    "Using coarse timing for \(fallback.count) unstable alignment units…"
                )
                return SpanAlignmentResult(
                    words: fallback,
                    coarseTimedUnitCount: fallback.count
                )
            }

            progress(
                progressFraction,
                "Retrying alignment chunk \(chunkIndex + 1) with smaller audio ranges…"
            )
            let splitChunks: (left: AlignmentWorkChunk, right: AlignmentWorkChunk)
            if chunk.sourceSpans.count > 1 {
                let splitIndex = coarseBoundarySplitIndex(for: chunk.sourceSpans)
                splitChunks = (
                    AlignmentWorkChunk(sourceSpans: Array(chunk.sourceSpans[..<splitIndex])),
                    AlignmentWorkChunk(sourceSpans: Array(chunk.sourceSpans[splitIndex...]))
                )
            } else {
                let splitUnit = units.count / 2
                guard splitUnit > 0, splitUnit < units.count else { throw error }
                let splitFraction = Double(splitUnit) / Double(units.count)
                let splitTime = span.startTime + span.duration * splitFraction
                guard splitTime > span.startTime, splitTime < span.endTime else { throw error }
                splitChunks = (
                    AlignmentWorkChunk(sourceSpans: [RecognizedSpan(
                        text: units[..<splitUnit].joined(separator: " "),
                        startTime: span.startTime,
                        endTime: splitTime
                    )]),
                    AlignmentWorkChunk(sourceSpans: [RecognizedSpan(
                        text: units[splitUnit...].joined(separator: " "),
                        startTime: splitTime,
                        endTime: span.endTime
                    )])
                )
            }
            let left = try alignSpan(
                audio: audio,
                audioDuration: audioDuration,
                sampleRate: sampleRate,
                chunk: splitChunks.left,
                language: language,
                aligner: aligner,
                capabilities: capabilities,
                chunkIndex: chunkIndex,
                retryDepth: retryDepth + 1,
                progressFraction: progressFraction,
                progress: progress
            )
            let right = try alignSpan(
                audio: audio,
                audioDuration: audioDuration,
                sampleRate: sampleRate,
                chunk: splitChunks.right,
                language: language,
                aligner: aligner,
                capabilities: capabilities,
                chunkIndex: chunkIndex,
                retryDepth: retryDepth + 1,
                progressFraction: progressFraction,
                progress: progress
            )
            return SpanAlignmentResult(
                words: left.words + right.words,
                coarseTimedUnitCount: left.coarseTimedUnitCount + right.coarseTimedUnitCount
            )
        }
    }

    private static func coarseTiming(
        for spans: [RecognizedSpan],
        language: String,
        aligner: Qwen3ForcedAligner
    ) throws -> [AlignedWord] {
        var result: [AlignedWord] = []
        for span in spans {
            let units = try alignmentUnits(for: span.text, language: language, aligner: aligner)
            result.append(contentsOf: evenlyTimed(units: units, within: span))
        }
        return result
    }

    /// Coarse-anchor fallback used only after the neural aligner and bounded
    /// retries fail. The same tokenizer units are retained, and the output is
    /// explicitly surfaced as estimated timing in diagnostics.
    static func evenlyTimed(units: [String], within span: RecognizedSpan) -> [AlignedWord] {
        guard !units.isEmpty, span.duration > 0 else { return [] }
        let step = span.duration / Double(units.count)
        return units.enumerated().map { index, unit in
            AlignedWord(
                text: unit,
                startTime: Float(span.startTime + Double(index) * step),
                endTime: Float(span.startTime + Double(index + 1) * step)
            )
        }
    }

    /// Pick the original ASR boundary nearest the chunk's temporal midpoint.
    /// This keeps each transcript fragment attached to the waveform interval
    /// that produced it and avoids language-dependent text heuristics.
    private static func coarseBoundarySplitIndex(for spans: [RecognizedSpan]) -> Int {
        precondition(spans.count > 1)
        let start = spans.first!.startTime
        let end = spans.map(\.endTime).max()!
        let midpoint = start + (end - start) / 2
        return (1..<spans.count).min { lhs, rhs in
            let lhsBoundary = (spans[lhs - 1].endTime + spans[lhs].startTime) / 2
            let rhsBoundary = (spans[rhs - 1].endTime + spans[rhs].startTime) / 2
            let lhsDistance = abs(lhsBoundary - midpoint)
            let rhsDistance = abs(rhsBoundary - midpoint)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }!
    }

    static func spansForEditedTranscript(
        text: String,
        original: TranscriptionResult,
        audioDuration: Double,
        language: String,
        aligner: Qwen3ForcedAligner,
        capabilities: AlignmentModelCapabilities = .qwen3ForcedAligner
    ) throws -> [RecognizedSpan] {
        let newUnits = try alignmentUnits(for: text, language: language, aligner: aligner)
        let timedOriginal = original.words.compactMap { word -> (text: String, start: Double, end: Double)? in
            guard let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, end >= start else { return nil }
            return (word.text, start, end)
        }
        guard !timedOriginal.isEmpty else { throw LongFormAlignmentError.invalidSpan }
        let matches = AlignmentAnchorMatcher.matchingPairs(
            old: timedOriginal.map(\.text),
            new: newUnits
        )
        let coverage = Double(matches.count) / Double(max(newUnits.count, 1))
        guard coverage >= capabilities.editedTranscriptMinimumAnchorCoverage else {
            throw LongFormAlignmentError.insufficientAnchorCoverage(
                actual: coverage,
                required: capabilities.editedTranscriptMinimumAnchorCoverage
            )
        }

        var estimates = [Double](repeating: 0, count: newUnits.count)
        var anchorsByNewIndex: [Int: Double] = [:]
        for match in matches {
            let word = timedOriginal[match.old]
            anchorsByNewIndex[match.new] = (word.start + word.end) / 2
        }
        let sortedAnchors = anchorsByNewIndex.sorted { $0.key < $1.key }
        for index in newUnits.indices {
            if let exact = anchorsByNewIndex[index] {
                estimates[index] = exact
                continue
            }
            let previous = sortedAnchors.last { $0.key < index }
            let next = sortedAnchors.first { $0.key > index }
            switch (previous, next) {
            case let (.some(left), .some(right)):
                let fraction = Double(index - left.key) / Double(right.key - left.key)
                estimates[index] = left.value + fraction * (right.value - left.value)
            case let (.some(left), .none):
                let averageUnitDuration = max(audioDuration / Double(max(newUnits.count, 1)), 0.08)
                estimates[index] = left.value + Double(index - left.key) * averageUnitDuration
            case let (.none, .some(right)):
                let averageUnitDuration = max(audioDuration / Double(max(newUnits.count, 1)), 0.08)
                estimates[index] = right.value - Double(right.key - index) * averageUnitDuration
            case (.none, .none):
                estimates[index] = audioDuration * Double(index) / Double(max(newUnits.count - 1, 1))
            }
            estimates[index] = min(audioDuration, max(0, estimates[index]))
        }

        var spans: [RecognizedSpan] = []
        var lower = 0
        while lower < newUnits.count {
            var upper = lower + 1
            while upper < newUnits.count,
                  estimates[upper] - estimates[lower] <= capabilities.targetChunkDuration {
                upper += 1
            }
            let firstTime = estimates[lower]
            let lastTime = estimates[upper - 1]
            let padding = max(capabilities.contextDuration, 1)
            var start = max(0, firstTime - padding)
            var end = min(audioDuration, lastTime + padding)
            if end <= start {
                end = min(audioDuration, start + 1)
                start = max(0, end - 1)
            }
            if end - start > capabilities.maximumChunkDuration {
                end = start + capabilities.maximumChunkDuration
            }
            spans.append(RecognizedSpan(
                text: newUnits[lower..<upper].joined(separator: " "),
                startTime: start,
                endTime: end
            ))
            lower = upper
        }
        return spans
    }

    private static func alignmentUnits(
        for text: String,
        language: String,
        aligner: Qwen3ForcedAligner
    ) throws -> [String] {
        guard let tokenizer = aligner.tokenizer else { throw LongFormAlignmentError.missingTokenizer }
        let units = TextPreprocessor.prepareForAlignment(
            text: text,
            tokenizer: tokenizer,
            language: language
        ).words
        guard !units.isEmpty else { throw LongFormAlignmentError.emptyAlignmentUnits }
        return units
    }

    private static func validateRaw(
        _ words: [AlignedWord],
        chunkIndex: Int,
        sliceDuration: Double,
        capabilities: AlignmentModelCapabilities
    ) throws {
        var previousStart = -Double.infinity
        for (unitIndex, word) in words.enumerated() {
            let start = Double(word.startTime)
            let end = Double(word.endTime)
            guard start.isFinite, end.isFinite,
                  end >= start,
                  start + capabilities.timestampTolerance >= previousStart else {
                throw LongFormAlignmentError.invalidTimestamps(
                    chunk: chunkIndex,
                    unit: unitIndex,
                    start: start,
                    end: end,
                    previousStart: previousStart,
                    duration: sliceDuration
                )
            }
            previousStart = start
        }
    }

    /// Validate after timestamps have been clamped to their own coarse ASR
    /// span. A small boundary drift is recoverable; a collapsed suffix is not.
    private static func validateNormalized(
        _ words: [AlignedWord],
        chunkIndex: Int,
        span: RecognizedSpan,
        capabilities: AlignmentModelCapabilities
    ) throws {
        var previousStart = -Double.infinity
        for (unitIndex, word) in words.enumerated() {
            let start = Double(word.startTime)
            let end = Double(word.endTime)
            guard start.isFinite, end.isFinite,
                  start >= span.startTime - capabilities.timestampTolerance,
                  end <= span.endTime + capabilities.timestampTolerance,
                  end >= start,
                  start + capabilities.timestampTolerance >= previousStart else {
                throw LongFormAlignmentError.invalidTimestamps(
                    chunk: chunkIndex,
                    unit: unitIndex,
                    start: start,
                    end: end,
                    previousStart: previousStart,
                    duration: span.duration
                )
            }
            previousStart = start
        }
        let minimum = capabilities.plateauMinimumUnitCount
        guard words.count >= minimum * 2 else { return }
        let suffix = words.suffix(minimum)
        guard let first = suffix.first else { return }
        if suffix.allSatisfy({ abs($0.startTime - first.startTime) < 0.1 }) {
            throw LongFormAlignmentError.timestampPlateau(
                chunk: chunkIndex,
                start: Double(first.startTime)
            )
        }
    }
}
#endif
