import Foundation

/// Listen-track-only enhance preferences. Never applied to the ASR/master path.
enum ListenEnhanceSettings {
    private static let enabledKey = "voxella.listenEnhance.enabled"
    private static let wetMixKey = "voxella.listenEnhance.wetMix"
    /// Optional ASR denoise — product requires default OFF and not wired into LocalSpeechPipeline.
    private static let asrAlsoDenoiseKey = "voxella.listenEnhance.asrAlsoDenoise"

    /// DeepFilterNet wet amount. Halls prefer more original (~0.4–0.5 wet).
    static var wetMix: Float {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: wetMixKey) == nil {
                return defaultWetMix
            }
            return min(1, max(0, defaults.float(forKey: wetMixKey)))
        }
        set {
            UserDefaults.standard.set(min(1, max(0, newValue)), forKey: wetMixKey)
        }
    }

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Must stay off by default; ASR path must not pick this up unless explicitly enabled later.
    static var asrAlsoDenoise: Bool {
        get { UserDefaults.standard.bool(forKey: asrAlsoDenoiseKey) }
        set { UserDefaults.standard.set(newValue, forKey: asrAlsoDenoiseKey) }
    }

    static let defaultWetMix: Float = 0.45
    static let highPassCutoffHz: Double = 80
    static let targetIntegratedLUFS: Double = -18
    static let truePeakCeilingDBTP: Double = -1.5
}
