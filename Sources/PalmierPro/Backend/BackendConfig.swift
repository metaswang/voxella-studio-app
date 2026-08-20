import Foundation

enum BackendConfig {
    static let googleClientID: String? = configuredString(
        infoKey: "GIDClientID",
        environmentKey: "GOOGLE_MAC_CLIENT_ID"
    )
    static let googleServerClientID: String? = configuredString(
        infoKey: "GIDServerClientID",
        environmentKey: "GOOGLE_SERVER_CLIENT_ID"
    )
    static let convexDeploymentURL: URL? = string("PalmierConvexDeploymentURL").flatMap { URL(string: $0) }
    static let convexHttpURL: URL? = string("PalmierConvexHttpURL").flatMap { URL(string: $0) }

    private static func configuredString(infoKey: String, environmentKey: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey],
           !value.isEmpty,
           !value.hasPrefix("CONFIGURE_") {
            return value
        }
        return string(infoKey)
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$("),
              !value.hasPrefix("CONFIGURE_")
        else { return nil }
        return value
    }
}
