import Foundation

enum LLMModelLifecycle {
    // Compatibility only: never offer or send the retired ID to a provider.
    private static let retiredNano = "gpt-5.4-nano"
    static let replacementNano = "gpt-5-nano"

    static func isRetired(_ reference: String) -> Bool {
        let leaf = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(separator: "/").last.map(String.init) ?? ""
        let model = leaf.split(separator: ":").first.map(String.init) ?? ""
        return model == retiredNano || model.hasPrefix(retiredNano + "-")
    }

    static func replacingRetiredModel(in reference: String) -> String {
        guard isRetired(reference) else { return reference }
        var components = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").map(String.init)
        components[components.count - 1] = replacementNano
        return components.joined(separator: "/")
    }
}
