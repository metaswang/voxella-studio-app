import Foundation
import Testing
@testable import PalmierPro

@Suite("App localization")
@MainActor
struct AppLocalizationTests {
    @Test func systemLanguageUsesOnlyTheFirstPreferredLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["it-IT", "zh-Hans"]
        )

        #expect(localization.activeIdentifier == "en")
    }

    @Test func systemLanguageMatchesRegionalVariants() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["zh-CN"]
        )

        #expect(localization.activeIdentifier == "zh-Hans")
    }

    @Test func explicitSupportedLanguageOverridesTheSystemLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ja", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["en"]
        )

        #expect(localization.selection == .language("ja"))
        #expect(localization.activeIdentifier == "ja")
    }

    @Test func unsupportedSavedLanguageResetsToSystemLanguage() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ko", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["en"]
        )

        #expect(localization.selection == .system)
        #expect(defaults.string(forKey: AppLanguage.defaultsKey) == "system")
    }

    @Test func missingLocalizedKeyFallsBackToEnglishResource() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("fr", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["fr"]
        )

        #expect(localization.string(key: "AI access") == "AI access")
    }

    @Test func simplifiedChineseLooksUpNewlyAddedKeys() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("zh-Hans", forKey: AppLanguage.defaultsKey)

        let localization = AppLocalization(
            defaults: defaults,
            resourceBundle: BundledResource.bundle,
            preferredLanguages: ["en"]
        )

        #expect(localization.string(key: "Capture audio or screen") == "录制音频或屏幕")
        #expect(localization.string(key: "Recent") == "最近")
        #expect(localization.string(key: "AI Service") == "AI 服务")
        #expect(localization.string(key: "Detected %@ beats.") == "检测到 %@ 个节拍。")
    }

    @Test func simplifiedChineseHasEveryEnglishResourceKey() throws {
        let english = try localizedKeys(for: "en")
        let simplifiedChinese = try localizedKeys(for: "zh-Hans")

        #expect(simplifiedChinese == english)
    }

    @Test func simplifiedChineseDoesNotAccidentallyReuseEnglishUIValues() throws {
        let english = try localizedValues(for: "en")
        let simplifiedChinese = try localizedValues(for: "zh-Hans")
        let allowedUnchangedProductOrFormatKeys: Set<String> = [
            "CC",
            "Google Calendar",
            "Google Meet",
            "MCP",
            "Meet Bot",
            "RTF %@",
            "VoxStudio",
            "VoxStudio Cloud",
            "YouTube",
            "your@email.com",
        ]
        let untranslated = english.compactMap { key, value -> String? in
            guard simplifiedChinese[key] == value,
                  value.count > 1,
                  value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil,
                  !allowedUnchangedProductOrFormatKeys.contains(key)
            else { return nil }
            return key
        }.sorted()

        #expect(untranslated.isEmpty)
    }

    @Test func simplifiedChineseCoversEveryStaticL10nKeyInSource() throws {
        let simplifiedChinese = try localizedKeys(for: "zh-Hans")
        let missing = try staticL10nKeysInSource().subtracting(simplifiedChinese)

        #expect(missing.isEmpty)
    }

    @Test func simplifiedChineseCoversEveryStaticSwiftUIKeyInSource() throws {
        let simplifiedChinese = try localizedKeys(for: "zh-Hans")
        let missing = try staticSwiftUIKeysInSource().subtracting(simplifiedChinese)

        #expect(missing.isEmpty)
    }

    @Test func simplifiedChineseCoversEveryStaticRuntimeStatusKeyInSource() throws {
        let simplifiedChinese = try localizedKeys(for: "zh-Hans")
        let missing = try staticRuntimeStatusKeysInSource().subtracting(simplifiedChinese)

        #expect(missing.isEmpty)
    }

    @Test func formatSafelyCoercesScalarArgumentsForObjectPlaceholders() {
        let formatted = L10n.format("%@ recent projects", 28)

        #expect(formatted.contains("28"))
    }

    @Test func formatPreservesNativeNumericPlaceholders() {
        let formatted = L10n.format("%+.2fs · %.0f%%", 1.25, 75.0)

        #expect(formatted.contains("1.25"))
        #expect(formatted.contains("75"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppLocalizationTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func localizedKeys(for identifier: String) throws -> Set<String> {
        Set(try localizedValues(for: identifier).keys)
    }

    private func localizedValues(for identifier: String) throws -> [String: String] {
        enum ResourceError: Error {
            case localizationNotFound
            case stringsNotReadable
        }

        guard let localizationURL = BundledResource.bundle.url(
            forResource: identifier,
            withExtension: "lproj",
            subdirectory: "Localization"
        ) else {
            throw ResourceError.localizationNotFound
        }
        let stringsURL = localizationURL.appending(path: "Localizable.strings")
        guard let strings = NSDictionary(contentsOf: stringsURL) as? [String: String] else {
            throw ResourceError.stringsNotReadable
        }
        return strings
    }

    private func staticL10nKeysInSource() throws -> Set<String> {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repository.appending(path: "Sources/PalmierPro")
        let expression = try NSRegularExpression(pattern: #"L10n\.(key|string|format)\("#)
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        var keys = Set<String>()
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let kindRange = Range(match.range(at: 1), in: source),
                      let invocationRange = Range(match.range, in: source) else { continue }
                let kind = String(source[kindRange])
                let argumentStart = invocationRange.upperBound
                guard let argumentEnd = closingParenthesis(in: source, after: argumentStart) else { continue }
                let keyRange: Range<String.Index>
                switch kind {
                case "string":
                    // Dynamic labels routinely use a ternary inside `L10n.string`, e.g.
                    // `isRunning ? "Pause" : "Play"`. Check every literal in that argument.
                    keyRange = argumentStart..<argumentEnd
                case "key", "format":
                    // Only the first argument is a localization key; later arguments may be
                    // user content or number-format templates that must not be treated as keys.
                    keyRange = argumentStart..<firstTopLevelArgumentEnd(
                        in: source,
                        start: argumentStart,
                        end: argumentEnd
                    )
                default:
                    continue
                }
                keys.formUnion(swiftStringLiterals(in: source, range: keyRange))
            }
        }
        return keys
    }

    private func staticSwiftUIKeysInSource() throws -> Set<String> {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repository.appending(path: "Sources/PalmierPro")
        let expression = try NSRegularExpression(
            pattern: #"(?:\b(?:Text|Button|Label|Toggle|Picker|TextField|SecureField|Menu)|\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog))\s*\(\s*""#
        )
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        var keys = Set<String>()
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let invocationRange = Range(match.range, in: source),
                      let quote = source[invocationRange].lastIndex(of: "\"")
                else { continue }
                let end = endOfSwiftString(in: source, from: quote)
                let contentStart = source.index(after: quote)
                guard end > contentStart else { continue }
                let contentEnd = source.index(before: end)
                let value = unescapeSwiftStringLiteral(String(source[contentStart..<contentEnd]))
                guard value.count > 1,
                      !value.contains("\\("),
                      value.rangeOfCharacter(from: .letters) != nil,
                      !value.hasPrefix("https://"),
                      !value.hasPrefix("http://"),
                      !value.hasPrefix("VoxStudio. "),
                      value != "provider/model",
                      value != "provider/model, provider/model"
                else { continue }
                keys.insert(value)
            }
        }
        return keys
    }

    private func staticRuntimeStatusKeysInSource() throws -> Set<String> {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repository.appending(path: "Sources/PalmierPro")
        let expressions = try [
            #"(?m)^(?!\s*case\b).*?\b(?:message|errorMessage|lastError|currentMessage|progressMessage|warning)\s*[:=]\s*\""#,
            #"\b(?:warnings|errors)\.append\(\s*\""#,
            #"\.failed\(\s*\""#,
        ].map { try NSRegularExpression(pattern: $0) }
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        var keys = Set<String>()
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for expression in expressions {
                for match in expression.matches(in: source, range: range) {
                    guard let invocationRange = Range(match.range, in: source),
                          let quote = source[invocationRange].lastIndex(of: "\"")
                    else { continue }
                    let end = endOfSwiftString(in: source, from: quote)
                    let contentStart = source.index(after: quote)
                    guard end > contentStart else { continue }
                    let contentEnd = source.index(before: end)
                    let value = unescapeSwiftStringLiteral(String(source[contentStart..<contentEnd]))
                    guard value.count > 1,
                          !value.contains("\\("),
                          !value.contains("\n"),
                          !value.contains("\r"),
                          value.rangeOfCharacter(from: .letters) != nil
                    else { continue }
                    keys.insert(value)
                }
            }
        }
        return keys
    }

    private func closingParenthesis(in source: String, after start: String.Index) -> String.Index? {
        var index = start
        var depth = 1
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                index = endOfSwiftString(in: source, from: index)
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func firstTopLevelArgumentEnd(
        in source: String,
        start: String.Index,
        end: String.Index
    ) -> String.Index {
        var index = start
        var depth = 0
        while index < end {
            let character = source[index]
            if character == "\"" {
                index = endOfSwiftString(in: source, from: index)
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            } else if character == ",", depth == 0 {
                return index
            }
            index = source.index(after: index)
        }
        return end
    }

    private func swiftStringLiterals(
        in source: String,
        range: Range<String.Index>
    ) -> Set<String> {
        var values = Set<String>()
        var index = range.lowerBound
        while index < range.upperBound {
            guard source[index] == "\"" else {
                index = source.index(after: index)
                continue
            }
            let contentStart = source.index(after: index)
            let end = endOfSwiftString(in: source, from: index)
            guard end > contentStart else { break }
            let contentEnd = source.index(before: end)
            values.insert(unescapeSwiftStringLiteral(String(source[contentStart..<contentEnd])))
            index = end
        }
        return values
    }

    private func endOfSwiftString(in source: String, from openingQuote: String.Index) -> String.Index {
        var index = source.index(after: openingQuote)
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return source.index(after: index)
            }
            index = source.index(after: index)
        }
        return source.endIndex
    }

    private func unescapeSwiftStringLiteral(_ value: String) -> String {
        var result = ""
        var escaping = false

        for character in value {
            guard escaping else {
                if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
                continue
            }

            switch character {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(character)
            }
            escaping = false
        }
        if escaping { result.append("\\") }
        return result
    }
}
