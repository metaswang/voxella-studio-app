import Foundation

enum BackendConfig {
    static let convexDeploymentURL: URL? = string("PalmierConvexDeploymentURL").flatMap { URL(string: $0) }
    static let convexHttpURL: URL? = string("PalmierConvexHttpURL").flatMap { URL(string: $0) }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$("),
              !value.hasPrefix("CONFIGURE_")
        else { return nil }
        return value
    }
}
