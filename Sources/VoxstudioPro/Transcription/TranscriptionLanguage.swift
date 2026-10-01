import Foundation

enum WorkbenchTranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case english = "en"
    case simplifiedChinese = "zh-CN"
    case traditionalChineseTaiwan = "zh-TW"
    case cantoneseSimplified = "yue-CN"
    case cantoneseTraditional = "yue-TW"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"

    var id: String { rawValue }

    var languageCode: String? {
        self == .automatic ? nil : rawValue
    }

    var label: String {
        switch self {
        case .automatic: "Auto detect"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChineseTaiwan: "台湾正体中文"
        case .cantoneseSimplified: "粤语（简体）"
        case .cantoneseTraditional: "粤语（正体）"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        }
    }
}

enum ChineseTranscriptScript: Sendable {
    case simplified
    case traditional

    func applying(to text: String) -> String {
        let transform = switch self {
        case .simplified: StringTransform(rawValue: "Hant-Hans")
        case .traditional: StringTransform(rawValue: "Hans-Hant")
        }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}

struct TranscriptionLanguage: Equatable, Sendable {
    let requestedCode: String?
    let asrLanguageCode: String?
    let outputLanguageCode: String?
    let chineseScript: ChineseTranscriptScript?

    init(code: String?) {
        let normalized = Self.normalizedCode(code)
        requestedCode = normalized

        switch normalized {
        case "zh-CN":
            asrLanguageCode = "zh"
            outputLanguageCode = "zh-CN"
            chineseScript = .simplified
        case "zh-TW":
            asrLanguageCode = "zh"
            outputLanguageCode = "zh-TW"
            chineseScript = .traditional
        case "yue-CN":
            asrLanguageCode = "yue"
            outputLanguageCode = "yue-CN"
            chineseScript = .simplified
        case "yue-TW":
            asrLanguageCode = "yue"
            outputLanguageCode = "yue-TW"
            chineseScript = .traditional
        case "yue":
            asrLanguageCode = "yue"
            outputLanguageCode = "yue"
            chineseScript = nil
        case let value?:
            asrLanguageCode = value.split(separator: "-").first.map(String.init)
            outputLanguageCode = value
            chineseScript = nil
        case nil:
            asrLanguageCode = nil
            outputLanguageCode = nil
            chineseScript = nil
        }
    }

    static func identifier(for locale: Locale?) -> String? {
        guard let locale else { return nil }
        return normalizedCode(locale.identifier(.bcp47))
    }

    private static func normalizedCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        return switch normalized {
        case "zh-cn", "zh-hans", "zh-hans-cn": "zh-CN"
        case "zh-tw", "zh-hant", "zh-hant-tw": "zh-TW"
        case "yue-cn", "yue-hans", "yue-hans-cn": "yue-CN"
        case "yue-tw", "yue-hant", "yue-hant-tw": "yue-TW"
        default: normalized
        }
    }
}
