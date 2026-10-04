import AVFoundation
import Foundation
import Testing
@testable import VoxstudioPro

@Suite("VoiceActivity")
struct VoiceActivityTests {
    @Test func reportsOnlyDamagedMedia() {
        let damagedMedia = NSError(domain: AVFoundationErrorDomain, code: -11829)
        let wrappedDamage = AudioTrackReader.ReadError.readFailed(
            damagedMedia.localizedDescription,
            underlying: damagedMedia
        )

        #expect(VoiceActivity.isDamagedMedia(damagedMedia))
        #expect(VoiceActivity.isDamagedMedia(wrappedDamage))
        #expect(!VoiceActivity.isDamagedMedia(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!VoiceActivity.isDamagedMedia(CancellationError()))
    }

    @Test func returnsEmptyAnalysisForNoAudio() {
        let analysis = VoiceActivity.noAudioAnalysis()

        #expect(analysis.chunkCount == 0)
        #expect(analysis.segments.isEmpty)
    }

    @Test func silenceRepairUsesSecondsAndRetainsSpeechAfterLargeGaps() {
        let rate = 24_000
        let speech = Array(repeating: Float(0.25), count: rate)
        let silence = Array(repeating: Float.zero, count: rate * 80)
        let samples = silence + speech + silence + speech + silence
        let repaired = VoiceActivity.repairingLongSilence(
            in: samples, sampleRate: rate,
            speechSpans: [.init(start: 80, end: 81), .init(start: 161, end: 162)]
        )
        #expect(repaired.count < rate * 3)
        #expect(repaired.filter { $0 == 0.25 }.count == rate * 2)
        // 350 ms between padded spans, plus 40 ms around each speech edge
        // and 80 ms at each recording boundary.
        #expect(repaired.count == rate * 2 + 8_400 + 7_680)
    }

    @Test func silenceRepairMergesOverlappingSpansAndPreservesShortPauses() {
        let samples: [Float] = Array(repeating: 0.1, count: 1_000)
            + Array(repeating: 0, count: 200) + Array(repeating: 0.2, count: 1_000)
        let repaired = VoiceActivity.repairingLongSilence(
            in: samples, sampleRate: 1_000,
            speechSpans: [.init(start: 1.2, end: 2.2), .init(start: 0.4, end: 1), .init(start: 0, end: 0.5)]
        )
        #expect(repaired == samples)
    }

    @Test func silenceRepairKeepsSpeechMissedByVADAndIgnoresInvalidSpans() {
        let samples = Array(repeating: Float(0.1), count: 3_000)
        #expect(VoiceActivity.repairingLongSilence(
            in: samples, sampleRate: 1_000, speechSpans: [.init(start: 0, end: 1)]
        ) == samples)
        #expect(VoiceActivity.repairingLongSilence(
            in: samples, sampleRate: 1_000,
            speechSpans: [.init(start: .nan, end: 1), .init(start: 3, end: 2), .init(start: 5, end: 6)]
        ) == samples)
    }
}
