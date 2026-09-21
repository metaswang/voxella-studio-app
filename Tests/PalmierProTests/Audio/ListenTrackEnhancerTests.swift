import Foundation
import Testing
@testable import PalmierPro

@Suite("Listen track dual-path audio", .serialized)
struct ListenTrackEnhancerTests {
    @Test func sidecarPathSitsBesideMaster() {
        let master = URL(fileURLWithPath: "/tmp/Recordings/Recording-20260904-120000.m4a")
        let listen = ListenTrackLocator.sidecarURL(forMaster: master)
        #expect(listen.lastPathComponent == "Recording-20260904-120000.listen-moss2.m4a")
        #expect(listen.deletingLastPathComponent() == master.deletingLastPathComponent())
    }

    @Test func playbackPathsPreferListenWhenReady() {
        var paths = ListenTrackPaths(
            masterURL: URL(fileURLWithPath: "/tmp/master.m4a"),
            listenURL: URL(fileURLWithPath: "/tmp/master.listen.m4a")
        )
        #expect(paths.asrURL.path.hasSuffix("master.m4a"))
        #expect(paths.playbackURL.path.hasSuffix("master.listen.m4a"))
        paths.listenURL = nil
        #expect(paths.playbackURL == paths.masterURL)
    }

    @Test func highPassRemovesDCBias() {
        let sampleRate = 48_000.0
        let samples = Array(repeating: Float(0.25), count: 4_800)
        let filtered = LinearLoudnessNormalizer.highPass(
            samples,
            sampleRate: sampleRate,
            cutoffHz: 80
        )
        let tail = filtered.suffix(1_000)
        let mean = tail.reduce(0, +) / Float(tail.count)
        #expect(abs(mean) < 0.02)
    }

    @Test func linearLoudnessRaisesQuietSpeechWithoutClippingCeiling() {
        let amplitude = Float(pow(10, -40.0 / 20.0))
        let samples = Array(repeating: amplitude, count: 16_000)
        let normalized = LinearLoudnessNormalizer.normalizeLinear(
            samples,
            targetLUFS: -18,
            truePeakCeilingDBTP: -1.5
        )
        let peak = normalized.map { abs($0) }.max() ?? 0
        let ceiling = Float(pow(10, -1.5 / 20.0))
        #expect(peak <= ceiling + 1e-4)
        #expect(peak > amplitude)
        let loudness = LinearLoudnessNormalizer.approximateIntegratedLUFS(samples: normalized)
        #expect(loudness != nil)
        #expect(abs((loudness ?? 0) + 18) < 1.5)
    }

    @Test func oaBlendKeepsDryWhenWetMixIsZero() {
        let dry: [Float] = [0.1, -0.2, 0.3]
        let wet: [Float] = [0.9, 0.9, 0.9]
        let mixed = VoiceReferenceSpeechGate.mix(dry: dry, wet: wet, wetMix: 0)
        #expect(mixed == dry)
    }

    @Test func asrPreprocessorStillBoostsQuietSpeechWithoutDenoise() {
        let amplitude = Float(pow(10, -45.0 / 20.0))
        let result = ASRAudioPreprocessor.prepare(samples: Array(repeating: amplitude, count: 16_000))
        #expect(result.didApplyGain)
        #expect(result.processed.peakDBFS <= ASRAudioPreprocessor.truePeakCeilingDBTP + 0.15)
        #expect(result.samples.allSatisfy { abs($0) <= 1 })
    }

    @Test func listenEnhanceSettingsDefaultAsrDenoiseOff() {
        #expect(ListenEnhanceSettings.asrAlsoDenoise == false)
        #expect(ListenEnhanceSettings.defaultWetMix > 0.3)
        #expect(ListenEnhanceSettings.defaultWetMix < 0.6)
    }

    @Test func listenEnhanceSettingsDefaultsEnabledWhenUnset() {
        let key = "voxella.listenEnhance.enabled"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        #expect(ListenEnhanceSettings.isEnabled == true)
    }

    @Test func listenEnhanceSettingsRoundTripGlobalToggle() {
        let key = "voxella.listenEnhance.enabled"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        ListenEnhanceSettings.isEnabled = false
        #expect(ListenEnhanceSettings.isEnabled == false)
        #expect(defaults.bool(forKey: key) == false)

        ListenEnhanceSettings.isEnabled = true
        #expect(ListenEnhanceSettings.isEnabled == true)
        #expect(defaults.bool(forKey: key) == true)
    }
}
