import Foundation

/// Listen-track-only enhance preferences. Never applied to the ASR/master path.
enum ListenEnhanceSettings {
    private static let enabledKey = "voxella.listenEnhance.enabled"
    /// Optional ASR denoise — product requires default OFF and not wired into LocalSpeechPipeline.
    private static let asrAlsoDenoiseKey = "voxella.listenEnhance.asrAlsoDenoise"

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
