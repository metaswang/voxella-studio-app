import Testing
@testable import PalmierPro

@Suite("ASR language clip sampling")
struct ASRLanguageClipSamplerTests {
    @Test func longAudioCollectsSevenStratifiedClipsWithoutFullVAD() {
        let sampleRate = 100
        let duration = 1_801
        let result = ASRLanguageClipSampler.windows(
            samples: activeSamples(seconds: duration, sampleRate: sampleRate),
            sampleRate: sampleRate
        )

        #expect(result.targetCount == 7)
        #expect(result.windows.count == 7)
        #expect(result.attemptedCount == 7)
        #expect(result.isComplete)
        #expect(result.windows.allSatisfy { abs($0.duration - 5) < 0.001 })
        #expect(result.windows.first?.start == 0)
        #expect(abs((result.windows.last?.slices.last?.end ?? 0) - Double(duration)) < 0.001)
        #expect(nonOverlapping(result.windows))
    }

    @Test func boundarySilenceIsTrimmedBeforeTheClipIsAccepted() {
        let sampleRate = 100
        var samples = [Float](repeating: 0, count: 60 * sampleRate)
        for origin in [0.0, 12.5, 25.0, 37.5, 50.0] {
            fillActive(&samples, from: origin + 2, to: origin + 8, sampleRate: sampleRate)
        }

        let result = ASRLanguageClipSampler.windows(samples: samples, sampleRate: sampleRate)

        #expect(result.isComplete)
        #expect(result.attemptedCount == 5)
        #expect(result.windows.allSatisfy { $0.duration >= 4.9 && $0.duration <= 5.001 })
        #expect((result.windows.first?.start ?? 0) > 1.8)
        #expect((result.windows.last?.slices.last?.end ?? 60) < 58.2)
    }

    @Test func insufficientPrimaryClipUsesTheNextCandidate() {
        let sampleRate = 100
        var samples = activeSamples(seconds: 60, sampleRate: sampleRate)
        replaceWithSilence(&samples, from: 25, to: 35, sampleRate: sampleRate)

        let result = ASRLanguageClipSampler.windows(samples: samples, sampleRate: sampleRate)

        #expect(result.isComplete)
        #expect(result.attemptedCount == 6)
        #expect(result.windows.count == 5)
        #expect(result.windows.contains { $0.start > 20 && $0.start < 25 })
        #expect(nonOverlapping(result.windows))
    }

    @Test func silentAudioExhaustsTheBoundedCandidateSet() {
        let sampleRate = 100
        let result = ASRLanguageClipSampler.windows(
            samples: [Float](repeating: 0, count: 60 * sampleRate),
            sampleRate: sampleRate
        )

        #expect(result.targetCount == 5)
        #expect(result.windows.isEmpty)
        #expect(result.attemptedCount == 13)
        #expect(!result.isComplete)
    }

    @Test func shortAudioUsesOneAvailableAudibleClip() {
        let sampleRate = 100
        var samples = [Float](repeating: 0, count: 2 * sampleRate)
        fillActive(&samples, from: 0.5, to: 1.5, sampleRate: sampleRate)
        let result = ASRLanguageClipSampler.windows(samples: samples, sampleRate: sampleRate)

        #expect(result.targetCount == 1)
        #expect(result.windows.count == 1)
        #expect(result.windows[0].duration > 1 && result.windows[0].duration < 1.3)
    }

    @Test func invalidInputCannotReportCompleteSampling() {
        let result = ASRLanguageClipSampler.windows(samples: [], sampleRate: 100)

        #expect(result.targetCount == 0)
        #expect(result.windows.isEmpty)
        #expect(!result.isComplete)
    }

    private func activeSamples(seconds: Int, sampleRate: Int) -> [Float] {
        (0..<(seconds * sampleRate)).map { $0.isMultiple(of: 2) ? 0.2 : -0.2 }
    }

    private func fillActive(
        _ samples: inout [Float],
        from start: Double,
        to end: Double,
        sampleRate: Int
    ) {
        let range = Int((start * Double(sampleRate)).rounded())..<Int((end * Double(sampleRate)).rounded())
        for index in range where samples.indices.contains(index) {
            samples[index] = index.isMultiple(of: 2) ? 0.2 : -0.2
        }
    }

    private func replaceWithSilence(
        _ samples: inout [Float],
        from start: Double,
        to end: Double,
        sampleRate: Int
    ) {
        let range = Int((start * Double(sampleRate)).rounded())..<Int((end * Double(sampleRate)).rounded())
        for index in range where samples.indices.contains(index) {
            samples[index] = 0
        }
    }

    private func nonOverlapping(_ windows: [ASRLanguageIdentificationWindow]) -> Bool {
        let ranges = windows.compactMap { window -> ASRSpeechRange? in
            guard let first = window.slices.first, let last = window.slices.last else { return nil }
            return .init(start: first.start, end: last.end)
        }.sorted { $0.start < $1.start }
        return zip(ranges, ranges.dropFirst()).allSatisfy { $0.end <= $1.start }
    }
}
