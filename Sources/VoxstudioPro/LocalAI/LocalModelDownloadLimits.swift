import Foundation

enum LocalModelDownloadLimits {
    static var maximumConcurrentModels: Int {
        numericEnvironment("VOXELLA_MODEL_DOWNLOAD_MAX_MODELS", fallback: 2, minimum: 1)
    }

    static var maximumConcurrentTransfers: Int {
        numericEnvironment("VOXELLA_MODEL_DOWNLOAD_MAX_TRANSFERS", fallback: 4, minimum: 1)
    }

    static let progressRefreshInterval: Duration = .milliseconds(200)
    static let cancelledStagingRetention = TimeInterval(7 * 24 * 60 * 60)
    static let maximumTransferRetries = 3

    private static func numericEnvironment(_ key: String, fallback: Int, minimum: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw) else {
            return fallback
        }
        return max(minimum, value)
    }
}

enum LocalModelDownloadDemand: Hashable, Sendable {
    case feature(LocalPreparationFeature)
    case explicit
}

struct LocalModelTransferProgress: Sendable, Equatable {
    var completedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double?

    var fraction: Double {
        guard totalBytes > 0 else { return completedBytes > 0 ? 1 : 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}
