import Foundation

enum ASREngineLanguagePolicy {
    static let qwenLanguages: Set<String> = [
        "zh", "yue", "ja", "ko", "th", "vi", "id", "ms", "hi", "ar", "tr",
    ]

    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static let parakeetQualityWatchLanguages: Set<String> = [
        "et", "da", "mt", "lt", "el", "lv", "sl",
    ]

    static let forcedAlignerLanguages: Set<String> = [
        "zh", "en", "yue", "fr", "de", "it", "ja", "ko", "pt", "ru", "es",
    ]

    static let voxLingua107Languages: Set<String> = [
        "ab", "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs",
        "ca", "ceb", "cs", "cy", "da", "de", "el", "en", "eo", "es", "et", "eu",
        "fa", "fi", "fo", "fr", "gl", "gn", "gu", "gv", "ha", "haw", "hi", "hr",
        "ht", "hu", "hy", "ia", "id", "is", "it", "iw", "ja", "jw", "ka", "kk",
        "km", "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv", "mg", "mi", "mk",
        "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa",
        "pl", "ps", "pt", "ro", "ru", "sa", "sco", "sd", "si", "sk", "sl", "sn",
        "so", "sq", "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "war", "yi", "yo", "zh",
    ]

    private static let qwenPromptNames: [String: String] = [
        "zh": "Chinese",
        "yue": "Cantonese",
        "ja": "Japanese",
        "ko": "Korean",
        "th": "Thai",
        "vi": "Vietnamese",
        "id": "Indonesian",
        "ms": "Malay",
        "hi": "Hindi",
        "ar": "Arabic",
        "tr": "Turkish",
        "en": "English",
        "de": "German",
        "es": "Spanish",
        "fr": "French",
        "it": "Italian",
        "pt": "Portuguese",
        "ru": "Russian",
    ]

    private static let qwenNameToISO: [String: String] = [
        "chinese": "zh",
        "mandarin": "zh",
        "cantonese": "yue",
        "japanese": "ja",
        "korean": "ko",
        "thai": "th",
        "vietnamese": "vi",
        "indonesian": "id",
        "malay": "ms",
        "hindi": "hi",
        "arabic": "ar",
        "turkish": "tr",
        "english": "en",
        "german": "de",
        "spanish": "es",
        "french": "fr",
        "italian": "it",
        "portuguese": "pt",
        "russian": "ru",
    ]

    static var whisperLanguages: Set<String> {
        voxLingua107Languages.subtracting(qwenLanguages).subtracting(parakeetLanguages)
    }

    static func normalizedISO(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized == "yue" || normalized.hasPrefix("yue-") { return "yue" }
        if normalized == "zh" || normalized.hasPrefix("zh-") { return "zh" }
        if normalized == "fil" || normalized.hasPrefix("fil-") { return "tl" }
        if normalized == "he" || normalized.hasPrefix("he-") { return "iw" }
        return normalized.split(separator: "-").first.map(String.init)
    }

    static func engine(forLanguageCode code: String?) -> ASREngine {
        guard let iso = normalizedISO(code) else { return .whisper }
        if qwenLanguages.contains(iso) { return .qwen }
        if parakeetLanguages.contains(iso) { return .parakeet }
        return .whisper
    }

    static func ecapaRoutingCode(_ language: String) -> String {
        normalizedISO(language) ?? language.lowercased()
    }

    static func whisperLanguageCode(from code: String?) -> String? {
        guard let iso = normalizedISO(code) else { return nil }
        switch iso {
        case "iw": return "he"
        case "yue": return "zh"
        default: return iso
        }
    }

    static func qwenPromptLanguage(from code: String?) -> String? {
        guard let iso = normalizedISO(code) else { return nil }
        return qwenPromptNames[iso]
    }

    static func isoCode(fromQwenLanguage name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let mapped = qwenNameToISO[trimmed.lowercased()] { return mapped }
        return normalizedISO(trimmed)
    }

    static func qwenLockLanguage(fromDetected name: String?) -> String? {
        guard let iso = isoCode(fromQwenLanguage: name) else { return nil }
        return qwenPromptNames[iso] ?? name?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func supportsForcedAlignment(_ code: String?) -> Bool {
        guard let iso = normalizedISO(code) else { return false }
        return forcedAlignerLanguages.contains(iso)
    }

    static func modelID(for engine: ASREngine, whisperFallback: LocalModelID) -> LocalModelID {
        switch engine {
        case .qwen: .qwen3ASR17B8Bit
        case .parakeet: .parakeetTDT06Bv3
        case .whisper: whisperFallback
        }
    }
}
