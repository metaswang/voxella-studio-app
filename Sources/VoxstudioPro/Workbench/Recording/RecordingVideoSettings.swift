import CoreGraphics
import Foundation

enum RecordingResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, fullHD, hd
    var id: String { rawValue }
    var title: String { switch self { case .automatic: "Automatic"; case .fullHD: "1080p"; case .hd: "720p" } }
    var longEdge: CGFloat { switch self { case .automatic: 3840; case .fullHD: 1920; case .hd: 1280 } }
    var shortEdge: CGFloat { longEdge * 9 / 16 }
}

enum RecordingQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var multiplier: Double { switch self { case .low: 0.4; case .medium: 0.7; case .high: 1 } }
}

struct RecordingVideoSettings: Equatable, Codable, Sendable {
    var resolution: RecordingResolution = .automatic
    var frameRate = 30
    var quality: RecordingQuality = .high
    var showsCursor = true
    static let frameRates = [15, 30, 60]
    static let defaultsKey = "recording.videoSettings.v1"

    var effectiveFrameRate: Int { Self.frameRates.contains(frameRate) ? frameRate : 30 }

    func outputSize(for source: CGSize) -> (width: Int, height: Int) {
        let sourceWidth = max(2, source.width.isFinite ? source.width : 2)
        let sourceHeight = max(2, source.height.isFinite ? source.height : 2)
        let landscape = sourceWidth >= sourceHeight
        let maxWidth = landscape ? resolution.longEdge : resolution.shortEdge
        let maxHeight = landscape ? resolution.shortEdge : resolution.longEdge
        let ratio = min(1, min(maxWidth / sourceWidth, maxHeight / sourceHeight))
        func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded(.down)) / 2 * 2) }
        return (even(sourceWidth * ratio), even(sourceHeight * ratio))
    }

    func bitRate(width: Int, height: Int) -> Int {
        let rate = Double(width) * Double(height) * 2 * Double(effectiveFrameRate) / 30 * quality.multiplier
        return Int(min(40_000_000, max(500_000, rate)))
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
