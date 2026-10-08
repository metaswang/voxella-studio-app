import Foundation
import Testing
@testable import WeSpeakerEmbedding

@Suite struct KaldiFbankTests {
    @Test func frameCountUsesSnipEdges() {
        let options = KaldiFbankOptions.weSpeaker
        #expect(options.frameCount(sampleCount: 399) == 0)
        #expect(options.frameCount(sampleCount: 400) == 1)
        #expect(options.frameCount(sampleCount: 16_000) == 98)
    }

    @Test func featuresAreMeanNormalizedPerBin() {
        let audio = (0..<16_000).map { Float(sin(Double($0) * 0.07)) * 0.3 + Float(($0 * 7_919) % 97) / 9_700 }
        let result = KaldiFbank().features(audio)
        #expect(result.frames == 98)
        for bin in [0, 20, 79] {
            let mean = (0..<result.frames).reduce(Float(0)) { $0 + result.values[$1 * 80 + bin] } / Float(result.frames)
            #expect(abs(mean) < 1e-3)
        }
    }

    @Test func melBanksFollowKaldiLayout() {
        let banks = KaldiFbank.melBanks(options: .weSpeaker)
        #expect(banks.count == 257 * 80)
        // DC (0 Hz < 20 Hz low cut) and Nyquist rows are zero.
        #expect((0..<80).allSatisfy { banks[$0] == 0 })
        #expect((0..<80).allSatisfy { banks[256 * 80 + $0] == 0 })
        // Kaldi banks are unnormalized triangles with unit peak at most.
        #expect(banks.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func constantInputIsRemovedByDCOffset() {
        // DC removal makes a constant signal hit the log floor in every bin.
        let result = KaldiFbank().features([Float](repeating: 0.25, count: 4_000))
        #expect(result.values.allSatisfy { abs($0) < 1e-4 })
    }

    @Test func validationRejectsDegenerateVectors() {
        #expect(throws: WeSpeakerEmbeddingError.invalidEmbedding) {
            _ = try WeSpeakerEmbedder.validated([Float](repeating: 0, count: 256))
        }
        #expect(throws: WeSpeakerEmbeddingError.invalidEmbedding) {
            _ = try WeSpeakerEmbedder.validated([Float](repeating: .nan, count: 256))
        }
        #expect(throws: WeSpeakerEmbeddingError.invalidEmbedding) {
            _ = try WeSpeakerEmbedder.validated([1, 2, 3])
        }
        let unit = try? WeSpeakerEmbedder.validated([Float](repeating: 2, count: 256))
        #expect(abs((unit ?? []).reduce(0) { $0 + $1 * $1 } - 1) < 1e-4)
    }
}

/// Parity with `torchaudio.compliance.kaldi.fbank` as configured by pyannote
/// (fixture from tools/speaker_reference/make_fbank_fixture.py).
@Suite struct KaldiFbankParityTests {
    struct Fixture: Decodable {
        let audio: [Float]
        let frames: Int
        let features: [Float]
    }

    @Test func matchesTorchaudioKaldiFbank() throws {
        let url = try #require(Bundle.module.url(
            forResource: "kaldi_fbank_reference", withExtension: "json", subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let result = KaldiFbank().features(fixture.audio)
        #expect(result.frames == fixture.frames)
        #expect(result.values.count == fixture.features.count)
        let maxError = zip(result.values, fixture.features).map { abs($0 - $1) }.max() ?? .infinity
        let meanError = zip(result.values, fixture.features).map { abs($0 - $1) }.reduce(0, +)
            / Float(max(1, fixture.features.count))
        #expect(maxError < 2e-3, "max abs error \(maxError)")
        #expect(meanError < 2e-4, "mean abs error \(meanError)")
    }
}
