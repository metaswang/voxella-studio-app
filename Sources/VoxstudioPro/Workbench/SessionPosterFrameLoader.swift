import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Shared by Recent and the session player so both accept videos whose first
/// presentation timestamp is later than zero (common for trimmed MP4 files).
enum SessionPosterFrameLoader {
    static func load(url: URL, enabled: Bool) async -> Data? {
        guard enabled, !Task.isCancelled else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .positiveInfinity

            do {
                let (image, _) = try await generator.image(at: .zero)
                guard !Task.isCancelled else { return nil }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.png.identifier as CFString, 1, nil
                ) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                return CGImageDestinationFinalize(destination) ? output as Data : nil
            } catch {
                Log.project.warning("session poster extraction failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
}
