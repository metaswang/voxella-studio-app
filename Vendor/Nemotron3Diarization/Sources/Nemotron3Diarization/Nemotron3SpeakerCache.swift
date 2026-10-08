import Accelerate
import Foundation

/// Arrival-order speaker cache and FIFO carried between chunks of one recording.
/// All buffers are row-major: embeddings `[rows, modelDimension]`, predictions
/// `[rows, speakerCount]` at the 80 ms encoder rate.
struct Nemotron3SpeakerCacheState {
    var cache: [Float] = []
    var cacheLength = 0
    /// Predictions stored with a compressed cache. Before the first compression
    /// the cache holds plain chunk rows whose predictions each call re-estimates.
    var cachePredictions: [Float]?
    var fifo: [Float] = []
    var fifoLength = 0
    var fifoPredictions: [Float]?

    mutating func reset() {
        self = Nemotron3SpeakerCacheState()
    }
}

/// Port of the reference `Nemotron3DiarizationSpeakerCache.update` / `_compress`
/// (NeMo `streaming_update`), using the checkpoint's learned silence embedding.
struct Nemotron3SpeakerCacheUpdater {
    let geometry: Nemotron3Geometry
    let silenceEmbedding: [Float]

    /// Applies one call's core rows to the state.
    /// - Parameters:
    ///   - coreEmbeddings: `[coreRows, modelDimension]` of newly confirmed rows.
    ///   - predictions: 80 ms predictions over `[cache | fifo | chunk + right context]`.
    func update(
        state: inout Nemotron3SpeakerCacheState,
        coreEmbeddings: [Float],
        predictions: [Float]
    ) {
        let dimension = geometry.modelDimension
        let speakers = geometry.speakerCount
        let previousCacheLength = state.cacheLength
        let previousFifoLength = state.fifoLength
        let coreRows = coreEmbeddings.count / dimension

        let fifoStart = previousCacheLength * speakers
        let coreStart = (previousCacheLength + previousFifoLength) * speakers
        let coreEnd = coreStart + coreRows * speakers
        guard coreEnd <= predictions.count else { return }
        // This call re-estimates the FIFO rows; keep its view of them.
        state.fifoPredictions = Array(predictions[fifoStart..<coreEnd])
        state.fifo.append(contentsOf: coreEmbeddings)
        state.fifoLength += coreRows

        let queued = state.fifoLength
        guard queued > geometry.fifoLength else { return }
        let popped = min(queued, max(geometry.speakerCacheUpdatePeriod, queued - geometry.fifoLength))
        let poppedEmbeddings = Array(state.fifo.prefix(popped * dimension))
        let poppedPredictions = Array((state.fifoPredictions ?? []).prefix(popped * speakers))
        state.fifo.removeFirst(popped * dimension)
        state.fifoPredictions?.removeFirst(popped * speakers)
        state.fifoLength -= popped

        let storedPredictions = state.cachePredictions
            ?? Array(predictions.prefix(previousCacheLength * speakers))
        var cacheEmbeddings = state.cache
        cacheEmbeddings.append(contentsOf: poppedEmbeddings)
        var cachePredictions = storedPredictions
        cachePredictions.append(contentsOf: poppedPredictions)
        let rows = previousCacheLength + popped

        if rows > geometry.speakerCacheLength {
            let compressed = compress(
                embeddings: cacheEmbeddings, predictions: cachePredictions, rows: rows
            )
            state.cache = compressed.embeddings
            state.cachePredictions = compressed.predictions
            state.cacheLength = geometry.speakerCacheLength
        } else {
            state.cache = cacheEmbeddings
            state.cacheLength = rows
            // An uncompressed cache keeps re-estimated predictions.
            state.cachePredictions = state.cachePredictions == nil ? nil : cachePredictions
        }
    }

    // MARK: - Compression

    func compress(
        embeddings: [Float],
        predictions: [Float],
        rows: Int
    ) -> (embeddings: [Float], predictions: [Float]) {
        let dimension = geometry.modelDimension
        let speakers = geometry.speakerCount
        let capacity = geometry.speakerCacheLength
        let silenceRows = geometry.silenceFramesPerSpeaker
        let budget = capacity / speakers - silenceRows
        let minimumPositive = Int(floor(Float(budget) * geometry.minPositiveScoresRate))
        let strong = Int(floor(Float(budget) * geometry.strongBoostRate))
        let weak = Int(floor(Float(budget) * geometry.weakBoostRate))

        var scores = frameScores(predictions: predictions, rows: rows, minimumPositive: minimumPositive)
        if rows > capacity {
            for row in capacity..<rows {
                for speaker in 0..<speakers {
                    scores[row * speakers + speaker] += geometry.latestFramesScoreBoost
                }
            }
        }
        boost(&scores, rows: rows, count: strong, amount: -2 * logf(0.5))
        boost(&scores, rows: rows, count: weak, amount: -logf(0.5))

        // Reserved silence rows always win selection and point at the learned silence embedding.
        let scoredRows = rows + silenceRows
        scores.append(contentsOf: repeatElement(Float.infinity, count: silenceRows * speakers))
        let selected = topRows(scores: scores, rows: scoredRows, count: capacity)

        var nextEmbeddings = [Float](repeating: 0, count: capacity * dimension)
        var nextPredictions = [Float](repeating: 0, count: capacity * speakers)
        for (slot, row) in selected.enumerated() {
            if let row, row < rows {
                nextEmbeddings.replaceSubrange(
                    slot * dimension..<(slot + 1) * dimension,
                    with: embeddings[row * dimension..<(row + 1) * dimension]
                )
                nextPredictions.replaceSubrange(
                    slot * speakers..<(slot + 1) * speakers,
                    with: predictions[row * speakers..<(row + 1) * speakers]
                )
            } else {
                nextEmbeddings.replaceSubrange(slot * dimension..<(slot + 1) * dimension, with: silenceEmbedding)
            }
        }
        return (nextEmbeddings, nextPredictions)
    }

    /// `log(p) - log(1-p) + Σ log(1-p_j) - log(0.5)`, with non-speech rows and
    /// surplus non-positive rows disabled.
    func frameScores(predictions: [Float], rows: Int, minimumPositive: Int) -> [Float] {
        let speakers = geometry.speakerCount
        let threshold = geometry.predictionScoreThreshold
        var scores = [Float](repeating: 0, count: rows * speakers)
        var positiveCounts = [Int](repeating: 0, count: speakers)
        for row in 0..<rows {
            var complementSum: Float = 0
            for speaker in 0..<speakers {
                complementSum += logf(max(1 - predictions[row * speakers + speaker], threshold))
            }
            for speaker in 0..<speakers {
                let probability = predictions[row * speakers + speaker]
                var score = logf(max(probability, threshold)) - logf(max(1 - probability, threshold))
                    + complementSum - logf(0.5)
                if probability <= 0.5 { score = -.infinity }
                scores[row * speakers + speaker] = score
                if score > 0 { positiveCounts[speaker] += 1 }
            }
        }
        for row in 0..<rows {
            for speaker in 0..<speakers where positiveCounts[speaker] >= minimumPositive {
                let index = row * speakers + speaker
                if scores[index] <= 0, scores[index] != -.infinity { scores[index] = -.infinity }
            }
        }
        return scores
    }

    /// Adds `amount` to each speaker's `count` best finite scores.
    func boost(_ scores: inout [Float], rows: Int, count: Int, amount: Float) {
        let speakers = geometry.speakerCount
        guard count > 0 else { return }
        for speaker in 0..<speakers {
            let best = (0..<rows)
                .filter { scores[$0 * speakers + speaker] != -.infinity }
                .sorted { scores[$0 * speakers + speaker] > scores[$1 * speakers + speaker] }
                .prefix(count)
            for row in best { scores[row * speakers + speaker] += amount }
        }
    }

    /// Top `count` (speaker, row) pairs over `[speaker, row]`-ordered scores,
    /// sorted by that flattened index; nil marks a disabled slot.
    func topRows(scores: [Float], rows: Int, count: Int) -> [Int?] {
        let speakers = geometry.speakerCount
        var candidates: [(flat: Int, score: Float)] = []
        candidates.reserveCapacity(rows * speakers)
        for speaker in 0..<speakers {
            for row in 0..<rows {
                candidates.append((speaker * rows + row, scores[row * speakers + speaker]))
            }
        }
        candidates.sort { $0.score == $1.score ? $0.flat < $1.flat : $0.score > $1.score }
        let sentinel = rows * speakers
        let chosen = candidates.prefix(count).map { $0.score == -.infinity ? sentinel : $0.flat }.sorted()
        return chosen.map { $0 == sentinel ? nil : $0 % rows }
    }
}
