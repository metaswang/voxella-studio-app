import Foundation

private final class BundledResourceToken {}

enum BundledResource {
    static let bundle: Bundle = {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return .main }
        let buildDirectory = Bundle(for: BundledResourceToken.self).bundleURL.deletingLastPathComponent()
        let resourceBundleURL = buildDirectory.appendingPathComponent("VoxstudioPro_VoxstudioPro.bundle")
        return Bundle(url: resourceBundleURL) ?? .main
    }()

    static func url(_ path: String) -> URL? {
        let buildDirectory = Bundle(for: BundledResourceToken.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(path),
            Bundle.main.resourceURL?.appendingPathComponent("VoxstudioPro_VoxstudioPro.bundle/\(path)"),
            buildDirectory.appendingPathComponent("VoxstudioPro_VoxstudioPro.bundle/\(path)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
