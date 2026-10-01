import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppLocalization {
    static let shared = AppLocalization()

    let activeIdentifier: String
    let activeLocale: Locale
    let availableLanguages: [AppLanguage]

    var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.id, forKey: AppLanguage.defaultsKey)
        }
    }

    var requiresRestart: Bool {
        (selection.identifier ?? systemIdentifier) != activeIdentifier
    }

    private let defaults: UserDefaults
    private let localizedBundle: Bundle
    private let englishBundle: Bundle
    private let systemIdentifier: String

    init(
        defaults: UserDefaults = .standard,
        resourceBundle: Bundle = BundledResource.bundle,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        let resources = Self.localizationResources(in: resourceBundle)
        let identifiers = resources.map(\.identifier)
        availableLanguages = identifiers.map(AppLanguage.language)
        let resolvedSystemIdentifier = Self.preferredIdentifier(
            in: resources,
            preferredLanguages: preferredLanguages
        )
        systemIdentifier = resolvedSystemIdentifier

        let storedLanguage = AppLanguage.stored(in: defaults)
        let validLanguage: AppLanguage
        if let identifier = storedLanguage.identifier, identifiers.contains(identifier) {
            validLanguage = .language(identifier)
        } else {
            validLanguage = .system
        }
        if defaults.string(forKey: AppLanguage.defaultsKey).map({ $0 != validLanguage.id }) == true {
            defaults.set(validLanguage.id, forKey: AppLanguage.defaultsKey)
        }

        selection = validLanguage
        let resolvedActiveIdentifier = validLanguage.identifier ?? resolvedSystemIdentifier
        activeIdentifier = resolvedActiveIdentifier
        activeLocale = Locale(identifier: resolvedActiveIdentifier)
        localizedBundle = resources.first { $0.identifier == resolvedActiveIdentifier }?.bundle
            ?? resources.first { $0.identifier == "en" }?.bundle
            ?? resourceBundle
        englishBundle = resources.first { $0.identifier == "en" }?.bundle ?? resourceBundle
    }

    func string(key: String) -> String {
        let localized = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
        guard localized == key else { return localized }
        return englishBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func displayName(for language: AppLanguage) -> String {
        guard let identifier = language.identifier else {
            return string(key: L10n.key("System Language"))
        }
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    private struct LocalizationResource {
        let identifier: String
        let bundle: Bundle
    }

    private static func localizationResources(in bundle: Bundle) -> [LocalizationResource] {
        let rootURLs = bundle.localizations
            .filter { $0 != "Base" }
            .compactMap { identifier in
                bundle.url(forResource: identifier, withExtension: "lproj")
            }
        let nestedURLs = bundle.urls(forResourcesWithExtension: "lproj", subdirectory: "Localization") ?? []

        let resources = (rootURLs + nestedURLs).reduce(into: [String: LocalizationResource]()) { result, url in
            guard let localizationBundle = Bundle(url: url) else { return }
            let identifier = Locale(identifier: url.deletingPathExtension().lastPathComponent).identifier
            result[identifier] = LocalizationResource(identifier: identifier, bundle: localizationBundle)
        }

        return resources.values
            .sorted { lhs, rhs in
                let lhsName = Locale(identifier: lhs.identifier)
                    .localizedString(forIdentifier: lhs.identifier) ?? lhs.identifier
                let rhsName = Locale(identifier: rhs.identifier)
                    .localizedString(forIdentifier: rhs.identifier) ?? rhs.identifier
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
    }

    private static func preferredIdentifier(
        in resources: [LocalizationResource],
        preferredLanguages: [String]
    ) -> String {
        guard let primaryLanguage = preferredLanguages.first else { return "en" }
        return Bundle.preferredLocalizations(
            from: resources.map(\.identifier),
            forPreferences: [primaryLanguage]
        ).first.map { Locale(identifier: $0).identifier } ?? "en"
    }
}

extension View {
    func appLocalization() -> some View {
        environment(\.locale, AppLocalization.shared.activeLocale)
    }
}

private extension String {
    /// True when the format contains an Objective-C object placeholder such as
    /// `%@` (including positional/width variants).
    var containsObjectPlaceholder: Bool {
        range(of: #"%[0-9$.*+\-]*@"#, options: .regularExpression) != nil
    }

    /// True when the format contains a numeric or scalar conversion. These
    /// must retain their original CVarArg types for Foundation formatting.
    var containsNumericPlaceholder: Bool {
        range(of: #"%[0-9$.*+\-]*[diouxXfFeEgGaAcCsSp]"#, options: .regularExpression) != nil
    }
}

@MainActor
enum L10n {
    nonisolated static func key(_ value: StaticString) -> String {
        value.description
    }

    static func string(_ key: String) -> String {
        AppLocalization.shared.string(key: key)
    }

    static func string(key: String) -> String {
        AppLocalization.shared.string(key: key)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let localizedFormat = string(key)
        // `%@` is an Objective-C object placeholder. Swift numeric values also
        // conform to CVarArg, but passing an Int/Double directly to `%@` makes
        // CoreFoundation interpret the scalar as an object pointer and can
        // crash in objc_opt_respondsToSelector. Coerce object placeholders to
        // strings while preserving native numeric formatting (`%f`, `%d`, …).
        let values: [CVarArg]
        if localizedFormat.containsObjectPlaceholder && !localizedFormat.containsNumericPlaceholder {
            values = arguments.map { String(describing: $0) }
        } else {
            values = arguments
        }
        return String(
            format: localizedFormat,
            locale: AppLocalization.shared.activeLocale,
            arguments: values
        )
    }

    private static func format(_ key: String, arguments: [String]) -> String {
        let values: [CVarArg] = arguments.map { $0 }
        return String(
            format: string(key),
            locale: AppLocalization.shared.activeLocale,
            arguments: values
        )
    }

    /// Resolves an app-owned status string that may have been persisted before
    /// the user changed the application language. Unknown text is preserved so
    /// user content and service-provided diagnostics are never altered.
    static func display(_ value: String) -> String {
        let progressParts = value.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        if progressParts.count == 4,
           Int(progressParts[0]) != nil,
           progressParts[1] == "of",
           Int(progressParts[2]) != nil,
           progressParts[3] == "steps" || progressParts[3] == "batches" {
            return format(
                "%@ of %@ %@",
                String(progressParts[0]),
                String(progressParts[2]),
                string(String(progressParts[3]))
            )
        }
        if value.hasPrefix("Target ") {
            return format("Target %@", String(value.dropFirst("Target ".count)))
        }
        if value.hasPrefix("Transcript ready · ") {
            return format(
                "Transcript ready · %@",
                display(String(value.dropFirst("Transcript ready · ".count)))
            )
        }
        if value.hasPrefix("Generating summary with "), value.hasSuffix("…") {
            let name = value
                .dropFirst("Generating summary with ".count)
                .dropLast()
            return format("Generating summary with %@…", String(name))
        }
        if value.hasPrefix("Dub ready · "), value.hasSuffix(" word timings estimated") {
            let count = value
                .dropFirst("Dub ready · ".count)
                .dropLast(" word timings estimated".count)
            return format("Dub ready · %@ word timings estimated", String(count))
        }
        if value.hasPrefix("Dub ready · ") {
            return format(
                "Dub ready · %@",
                display(String(value.dropFirst("Dub ready · ".count)))
            )
        }
        if let (current, total) = capturedValues(
            in: value,
            prefix: "Transcribing in VoxStudio Cloud · ",
            separator: " of ",
            suffix: " segments"
        ) {
            return format("Transcribing in VoxStudio Cloud · %@ of %@ segments", current, total)
        }
        if let (current, total) = capturedValues(
            in: value,
            prefix: "Synthesizing ",
            separator: "/",
            suffix: ""
        ), Int(current) != nil, Int(total) != nil {
            return format("Synthesizing %@/%@", current, total)
        }
        if let (part, total) = capturedValues(
            in: value,
            prefix: "Saving result · part ",
            separator: "/",
            suffix: ""
        ), Int(part) != nil, Int(total) != nil {
            return format("Saving result · part %@/%@", part, total)
        }
        for prefix in [
            "Re-transcribing in VoxStudio Cloud… ",
            "Uploading to VoxStudio Cloud… ",
        ] {
            guard let identifier = capturedValue(in: value, prefix: prefix, suffix: ""),
                  !identifier.isEmpty
            else { continue }
            return format("\(prefix)%@", identifier)
        }
        if let detail = capturedValue(
            in: value,
            prefix: "Could not open the captioned project: ",
            suffix: ""
        ) {
            return format("Could not open the captioned project: %@", detail)
        }
        if let name = capturedValue(
            in: value,
            prefix: "Couldn’t move ",
            suffix: " to the Trash."
        ) {
            return format("Couldn’t move %@ to the Trash.", name)
        }
        if value.hasPrefix("“"), value.hasSuffix("” is no longer in Recent Projects.") {
            let name = value
                .dropFirst()
                .dropLast("” is no longer in Recent Projects.".count)
            return format("“%@” is no longer in Recent Projects.", String(name))
        }
        for key in [
            "Offline access could not be saved: %@",
            "Offline access could not be removed: %@",
            "Offline access is unavailable: %@",
            "Could not open the captioned project: %@",
        ] {
            let prefix = String(key.dropLast(2))
            if let detail = capturedValue(in: value, prefix: prefix, suffix: "") {
                return format(key, detail)
            }
        }
        if let (minimum, maximum) = capturedValues(
            in: value,
            prefix: "Amount must be $",
            separator: "–$",
            suffix: "."
        ) {
            return format("Amount must be $%@–$%@.", minimum, maximum)
        }
        if let title = capturedValue(
            in: value,
            prefix: "Downloading ",
            suffix: " resources…"
        ) {
            return format("Downloading %@ resources…", title)
        }
        if let (completed, total) = capturedValues(
            in: value,
            prefix: "Analyzing sound scenes ",
            separator: " of ",
            suffix: "…"
        ), Int(completed) != nil, Int(total) != nil {
            return format("Analyzing sound scenes %@ of %@…", completed, total)
        }
        if let (completed, total) = capturedValues(
            in: value,
            prefix: "Diarizing chunk ",
            separator: " of ",
            suffix: "…"
        ), Int(completed) != nil, Int(total) != nil {
            return format("Diarizing chunk %@ of %@…", completed, total)
        }
        if let count = capturedValue(
            in: value,
            prefix: "Prepared ",
            suffix: " dub segments"
        ), Int(count) != nil {
            return format("Prepared %@ dub segments", count)
        }
        if let (completed, total) = capturedValues(
            in: value,
            prefix: "Synthesized chunk ",
            separator: " of ",
            suffix: ""
        ), Int(completed) != nil, Int(total) != nil {
            return format("Synthesized chunk %@ of %@", completed, total)
        }
        if let warning = capturedValue(
            in: value,
            prefix: "Completed with warning: ",
            suffix: ""
        ) {
            return format("Completed with warning: %@", display(warning))
        }
        if value == "Media flow completed" {
            return string(value)
        }
        if let stage = capturedValue(in: value, prefix: "", suffix: " completed"),
           !stage.isEmpty {
            return format("%@ completed", display(stage))
        }
        if let (completed, total) = capturedValues(
            in: value,
            prefix: "",
            separator: " of ",
            suffix: ""
        ), isFormattedByteProgress(completed), isFormattedByteProgress(total) {
            return format("%@ of %@", completed, total)
        }
        for (prefix, key) in [
            ("Preparing ", "Preparing %@… %@"),
            ("Verifying ", "Verifying %@… %@"),
            ("Waiting to prepare ", "Waiting to prepare %@… %@"),
        ] {
            guard value.hasPrefix(prefix),
                  let separator = value.range(of: "… ", options: .backwards),
                  separator.lowerBound > value.index(value.startIndex, offsetBy: prefix.count)
            else { continue }
            let title = String(value[value.index(value.startIndex, offsetBy: prefix.count)..<separator.lowerBound])
            let detail = String(value[separator.upperBound...])
            guard !title.isEmpty, !detail.isEmpty else { continue }
            return format(key, title, display(detail))
        }
        if let title = capturedValue(
            in: value,
            prefix: "Couldn’t prepare ",
            suffix: ". Retry to continue."
        ) {
            return format("Couldn’t prepare %@. Retry to continue.", title)
        }
        for key in [
            "Could not write the recording: %@",
            "Recording failed: %@",
            "Upload failed: %@",
        ] {
            let prefix = String(key.dropLast(2))
            if let detail = capturedValue(in: value, prefix: prefix, suffix: "") {
                return format(key, display(detail))
            }
        }
        if let code = capturedValue(
            in: value,
            prefix: "VoxStudio request failed (",
            suffix: ")."
        ) {
            return format("VoxStudio request failed (%@).", code)
        }
        for (prefix, key) in [("Landscape ", "Landscape"), ("Portrait ", "Portrait")] {
            guard value.hasPrefix(prefix) else { continue }
            return format("%@ %@", string(key), String(value.dropFirst(prefix.count)))
        }
        if let (field, unsupported, allowed) = unsupportedValueParts(value) {
            return format(
                "This option does not support %@ '%@'. Valid: %@.",
                string(field),
                unsupported,
                allowed
            )
        }
        if let limit = capturedValue(
            in: value,
            prefix: "This video option supports source videos up to ",
            suffix: ". Trim the clip to continue."
        ) {
            return format(
                "This video option supports source videos up to %@. Trim the clip to continue.",
                localizedDurationLimit(limit)
            )
        }
        if let (minimum, selection) = capturedValues(
            in: value,
            prefix: "This audio option needs at least ",
            separator: "s of source media (selection is ",
            suffix: "s)."
        ) {
            return format(
                "This audio option needs at least %@s of source media (selection is %@s).",
                minimum,
                selection
            )
        }
        if let (maximum, selection) = capturedValues(
            in: value,
            prefix: "This audio option accepts at most ",
            separator: "s of source media (selection is ",
            suffix: "s)."
        ) {
            return format(
                "This audio option accepts at most %@s of source media (selection is %@s).",
                maximum,
                selection
            )
        }
        if let (minimum, actual) = capturedValues(
            in: value,
            prefix: "This audio option requires a prompt of at least ",
            separator: " characters (got ",
            suffix: ")."
        ) {
            return format(
                "This audio option requires a prompt of at least %@ characters (got %@).",
                minimum,
                actual
            )
        }
        if let (minimum, maximum) = capturedValues(
            in: value,
            prefix: "This audio option duration must be ",
            separator: "-",
            suffix: " seconds."
        ) {
            return format("This audio option duration must be %@-%@ seconds.", minimum, maximum)
        }
        if let (maximum, actual) = imageRequestParts(value) {
            return format("This image option supports 1…%@ images per request (got %@).", maximum, actual)
        }
        if let maximum = capturedValue(
            in: value,
            prefix: "This audio option accepts at most ",
            suffix: " image reference(s)."
        ) {
            return format("This audio option accepts at most %@ image reference(s).", maximum)
        }
        if let maximum = capturedValue(
            in: value,
            prefix: "This audio option accepts at most ",
            suffix: " audio references."
        ) {
            return format("This audio option accepts at most %@ audio references.", maximum)
        }
        if let (name, maximum) = capturedValues(
            in: value,
            prefix: "",
            separator: " must be valid audio no longer than ",
            suffix: " seconds."
        ) {
            return format("%@ must be valid audio no longer than %@ seconds.", name, maximum)
        }
        if let name = capturedValue(
            in: value,
            prefix: "",
            suffix: " must be a WAV or MP3 file."
        ) {
            return format("%@ must be a WAV or MP3 file.", name)
        }
        if let (actual, required) = capturedValues(
            in: value,
            prefix: "The edited transcript changed too much to preserve reliable timing (",
            separator: "% anchors; ",
            suffix: "% required)."
        ) {
            return format(
                "The edited transcript changed too much to preserve reliable timing (%@%% anchors; %@%% required).",
                actual,
                required
            )
        }
        if let trackList = capturedValue(
            in: value,
            prefix: "The recording level was low for ",
            suffix: ". Move closer to the microphone or raise the source volume before recording again."
        ) {
            let tracks = trackList
                .components(separatedBy: " and ")
                .map { string($0) }
            let localizedTracks = tracks.count == 2
                ? format("%@ and %@", tracks[0], tracks[1])
                : tracks.joined(separator: " ")
            return format(
                "The recording level was low for %@. Move closer to the microphone or raise the source volume before recording again.",
                localizedTracks
            )
        }
        if let localized = localizedDynamicFormat(value) {
            return localized
        }
        return string(key: value)
    }

    private static let dynamicFormatKeys = [
        "A project named “%@” already exists in that folder. Pick another name.",
        "“%@” isn't a valid project name. Use a plain name without slashes or path components.",
        "Wait for %@ to finish opening before deleting.",
        "“%@” is being moved to the Trash.",
        "No audio track in %@.",
        "Could not read audio: %@.",
        "No file at path: %@",
        "Not a valid .cube 3D LUT: %@",
        "Timeline frame %@ is outside 0..<%@.",
        "Media asset not found: %@",
        "Media asset %@ is not a video.",
        "An export to %@ is already waiting or in progress.",
        "HDR export failed: %@",
        "Could not convert reference image %@ to JPEG.",
        "Video compression failed: %@",
        "Trim extraction failed: %@",
        "Unknown tool: %@",
        "Missing required parameter: %@",
        "Invalid parameter: %@",
        "The provider prefix “%@” is already in use.",
        "Configure an API key and an available AI service for %@.",
        "The download service returned an error (HTTP %@).",
        "Local word alignment was incomplete (expected %@ units, received %@).",
        "The local word aligner returned invalid timestamps in chunk %@, unit %@ (start %@, end %@, previous %@, duration %@).",
        "The local word aligner returned a timestamp plateau in chunk %@ near %@s.",
        "The local word aligner returned an implausibly long word in chunk %@, unit %@ (%@s; local median %@s).",
        "The LLM response could not be used: %@",
        "Invalid timeline: %@",
        "Source time %@s is outside 0…%@s.",
        "Could not render the frame: %@",
        "could not append still frame at %@s",
        "could not append lottie frame %@",
        "Could not render selection: %@",
        "Server returned HTTP %@.",
        "Tokenizer is missing special token %@.",
        "Expected %@ visual placeholder(s), found %@.",
        "Embedding dimension %@ is unsupported; use one of %@.",
        "Missing required option %@.",
        "Unknown argument %@.",
        "Invalid SRT timestamp: %@",
        "Invalid SRT time range: %@",
        "On-device transcription is not available for %@.",
        "Audio extraction failed: %@",
        "Transcription failed: %@",
        "file exceeds max size (%@ > %@ bytes)",
        "Select at most %@ files at a time to keep local processing responsive.",
        "“%@” could not be opened.",
        "Clip extraction failed: %@",
        "YouTube refused the audio download (HTTP %@). The video may be private, region-locked, or age-restricted.",
        "Could not mix recorded audio: %@",
        "Expected %@ speakers; %@ were detected.",
        "Unreadable segment: %@",
    ]

    private static func localizedDynamicFormat(_ value: String) -> String? {
        for key in dynamicFormatKeys {
            guard let arguments = dynamicFormatArguments(in: value, matching: key) else { continue }
            return format(key, arguments: arguments)
        }
        return nil
    }

    private static func dynamicFormatArguments(
        in value: String,
        matching key: String
    ) -> [String]? {
        let parts = key.components(separatedBy: "%@")
        guard parts.count > 1, value.hasPrefix(parts[0]) else { return nil }

        var arguments: [String] = []
        var index = value.index(value.startIndex, offsetBy: parts[0].count)

        for partIndex in 1..<parts.count {
            let suffix = parts[partIndex]
            if partIndex == parts.count - 1 {
                guard value.hasSuffix(suffix) else { return nil }
                let end = value.index(value.endIndex, offsetBy: -suffix.count)
                guard index <= end else { return nil }
                arguments.append(String(value[index..<end]))
                continue
            }

            guard let range = value.range(of: suffix, range: index..<value.endIndex) else {
                return nil
            }
            arguments.append(String(value[index..<range.lowerBound]))
            index = range.upperBound
        }

        return arguments
    }

    private static func capturedValue(in value: String, prefix: String, suffix: String) -> String? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(value[start..<end])
    }

    private static func capturedValues(
        in value: String,
        prefix: String,
        separator: String,
        suffix: String
    ) -> (String, String)? {
        guard let body = capturedValue(in: value, prefix: prefix, suffix: suffix),
              let separatorRange = body.range(of: separator) else { return nil }
        return (
            String(body[..<separatorRange.lowerBound]),
            String(body[separatorRange.upperBound...])
        )
    }

    private static func isFormattedByteProgress(_ value: String) -> Bool {
        let measurement = value
            .split(separator: "·", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return measurement.hasPrefix("~")
            && [" B", " KB", " MB", " GB", " TB"].contains { measurement.hasSuffix($0) }
    }

    private static func unsupportedValueParts(_ value: String) -> (String, String, String)? {
        let prefix = "This option does not support "
        let marker = "'. Valid: "
        guard let body = capturedValue(in: value, prefix: prefix, suffix: "."),
              let quotedStart = body.range(of: " '") else { return nil }
        let field = String(body[..<quotedStart.lowerBound])
        let afterField = body[quotedStart.upperBound...]
        guard let markerRange = afterField.range(of: marker) else { return nil }
        return (
            field,
            String(afterField[..<markerRange.lowerBound]),
            String(afterField[markerRange.upperBound...])
        )
    }

    private static func imageRequestParts(_ value: String) -> (String, String)? {
        let prefix = "This image option supports 1…"
        let middle = " image"
        let suffix = " per request (got "
        guard value.hasPrefix(prefix), value.hasSuffix(").") else { return nil }
        let body = String(value.dropFirst(prefix.count).dropLast(2))
        guard let middleRange = body.range(of: middle) else { return nil }
        let maximum = String(body[..<middleRange.lowerBound])
        let afterMaximum = body[middleRange.upperBound...]
        guard let suffixRange = afterMaximum.range(of: suffix) else { return nil }
        return (
            maximum,
            String(afterMaximum[suffixRange.upperBound...])
        )
    }

    private static func localizedDurationLimit(_ value: String) -> String {
        let units = [(" minute", "minute"), (" minutes", "minutes"), (" second", "second"), (" seconds", "seconds")]
        for (suffix, key) in units where value.hasSuffix(suffix) {
            let amount = String(value.dropLast(suffix.count))
            guard Int(amount) != nil else { continue }
            return format("%@ %@", amount, string(key))
        }
        return value
    }

}
