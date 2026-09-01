import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

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
}
