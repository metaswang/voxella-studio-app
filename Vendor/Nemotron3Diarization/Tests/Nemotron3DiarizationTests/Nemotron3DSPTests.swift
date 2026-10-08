import Foundation
import Testing
@testable import Nemotron3Diarization

@Suite struct Nemotron3MelExtractorTests {
    let geometry = Nemotron3Geometry.offline

    private func tone(frequency: Double, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 16_000)) }
    }

    @Test func frameCountDropsFinalCenteredFrame() {
        #expect(geometry.frameCount(sampleCount: 0) == 0)
        #expect(geometry.frameCount(sampleCount: 159) == 0)
        #expect(geometry.frameCount(sampleCount: 16_000) == 100)
        #expect(geometry.chunkCount(sampleCount: 16_000 * 27) == 1)
        #expect(geometry.chunkCount(sampleCount: 16_000 * 28) == 2)
    }

    @Test func chunkedExtractionMatchesWholeExtraction() {
        let audio = tone(frequency: 440, amplitude: 0.3, count: 16_000 * 2)
            .enumerated().map { $0.element + 0.01 * Float(($0.offset * 7919) % 101) / 101 }
        let extractor = Nemotron3MelExtractor(geometry: geometry)
        let frames = geometry.frameCount(sampleCount: audio.count)
        let whole = extractor.extract(audio: audio, frames: 0..<frames)
        let split = extractor.extract(audio: audio, frames: 0..<37)
            + extractor.extract(audio: audio, frames: 37..<frames)
        #expect(whole.count == frames * geometry.melBins)
        #expect(zip(whole, split).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func silenceHitsLogZeroGuard() {
        let extractor = Nemotron3MelExtractor(geometry: geometry)
        let mel = extractor.extract(audio: [Float](repeating: 0, count: 3_200), frames: 0..<20)
        let expected = logf(Nemotron3MelExtractor.logZeroGuard)
        #expect(mel.allSatisfy { abs($0 - expected) < 1e-4 })
    }

    @Test func powerSpectrumIsUnscaled() {
        // An interior frame of a bin-centered tone: |X_k| = A/2 · Σw, before pre-emphasis gain.
        let frequency = 31.25 * 32 // FFT bin 32 of 512 at 16 kHz
        let amplitude: Float = 0.5
        let audio = tone(frequency: frequency, amplitude: amplitude, count: 16_000)
        let extractor = Nemotron3MelExtractor(geometry: geometry)
        let mel = extractor.extract(audio: audio, frames: 50..<51)
        let windowSum = (0..<400).reduce(0.0) { $0 + 0.5 - 0.5 * cos(2 * .pi * Double($1) / 399) }
        let omega = 2 * Double.pi * frequency / 16_000
        let emphasisGain = sqrt(1 + 0.97 * 0.97 - 2 * 0.97 * cos(omega))
        let expectedPower = pow(Double(amplitude) / 2 * windowSum * emphasisGain, 2)
        let filters = Nemotron3MelExtractor.slaneyFilters(geometry: geometry)
        // Best responding mel band carries the bin's power times its filter weight.
        let band = (0..<128).max { filters[32 * 128 + $0] < filters[32 * 128 + $1] }!
        let predicted = log(expectedPower * Double(filters[32 * 128 + band]))
        #expect(abs(Double(mel[band]) - predicted) < 0.1)
    }

    @Test func slaneyFiltersAreAreaNormalized() {
        let filters = Nemotron3MelExtractor.slaneyFilters(geometry: geometry)
        #expect(filters.count == 257 * 128)
        #expect(filters.allSatisfy { $0 >= 0 && $0.isFinite })
        for mel in [0, 40, 127] {
            #expect((0..<257).contains { filters[$0 * 128 + mel] > 0 })
        }
    }
}

@Suite struct Nemotron3SpeakerCacheTests {
    let geometry = Nemotron3Geometry.offline

    private func updater() -> Nemotron3SpeakerCacheUpdater {
        Nemotron3SpeakerCacheUpdater(
            geometry: geometry,
            silenceEmbedding: [Float](repeating: -1, count: geometry.modelDimension)
        )
    }

    private func rows(_ count: Int, value: (Int) -> Float) -> [Float] {
        (0..<count).flatMap { row in [Float](repeating: value(row), count: geometry.modelDimension) }
    }

    private func predictions(_ count: Int, speaker: (Int) -> Int?) -> [Float] {
        (0..<count).flatMap { row -> [Float] in
            (0..<geometry.speakerCount).map { speaker(row) == $0 ? 0.95 : 0.02 }
        }
    }

    @Test func coreRowsQueueInFifoUntilItOverflows() {
        var state = Nemotron3SpeakerCacheState()
        updater().update(
            state: &state,
            coreEmbeddings: rows(30) { Float($0) },
            predictions: predictions(30 + 10) { _ in 0 }
        )
        #expect(state.fifoLength == 30)
        #expect(state.cacheLength == 0)
    }

    @Test func overflowMovesOldestRowsAndCompressesToCapacity() {
        var state = Nemotron3SpeakerCacheState()
        let update = updater()
        // First call: 340 rows → 300 popped into the cache, 40 stay queued.
        update.update(
            state: &state,
            coreEmbeddings: rows(340) { Float($0) },
            predictions: predictions(380) { $0 % 4 }
        )
        #expect(state.fifoLength == 40)
        #expect(state.cacheLength == geometry.speakerCacheLength)
        #expect(state.cachePredictions?.count == geometry.speakerCacheLength * geometry.speakerCount)
        // Reserved silence slots are filled with the learned silence embedding.
        let silenceRows = stride(from: 0, to: state.cache.count, by: geometry.modelDimension)
            .filter { state.cache[$0] == -1 }.count
        #expect(silenceRows >= geometry.silenceFramesPerSpeaker * geometry.speakerCount)
        // Kept rows stay in arrival order within a speaker group.
        #expect(state.fifo.first == 300)
    }

    @Test func frameScoresDisableNonSpeech() {
        let scores = updater().frameScores(
            predictions: predictions(4) { $0 == 0 ? 1 : nil }, rows: 4, minimumPositive: 1
        )
        #expect(scores[0 * 8 + 1].isFinite)
        #expect(scores[1 * 8 + 1] == -.infinity)
        #expect(scores[0 * 8 + 0] == -.infinity)
    }
}

/// Parity with the source checkpoint's feature extractor recipe
/// (fixture from tools/speaker_reference/make_nemotron_mel_fixture.py).
@Suite struct Nemotron3MelParityTests {
    struct Fixture: Decodable {
        let audio: [Float]
        let frames: Int
        let features: [Float]
    }

    @Test func matchesReferenceFeatureExtractor() throws {
        let url = try #require(Bundle.module.url(
            forResource: "nemotron_mel_reference", withExtension: "json", subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let geometry = Nemotron3Geometry.offline
        #expect(geometry.frameCount(sampleCount: fixture.audio.count) == fixture.frames)
        let mel = Nemotron3MelExtractor(geometry: geometry).extract(audio: fixture.audio, frames: 0..<fixture.frames)
        #expect(mel.count == fixture.features.count)
        let errors = zip(mel, fixture.features).map { abs($0 - $1) }
        let maxError = errors.max() ?? .infinity
        let meanError = errors.reduce(0, +) / Float(max(1, errors.count))
        #expect(maxError < 5e-3, "max abs error \(maxError)")
        #expect(meanError < 2e-4, "mean abs error \(meanError)")
    }
}
