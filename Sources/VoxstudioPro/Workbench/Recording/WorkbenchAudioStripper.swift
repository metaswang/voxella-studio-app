import AVFoundation
import Foundation

enum WorkbenchAudioStripper {
    struct StripError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Audio extraction failed: \(reason)" }
    }

    @concurrent
    static func extractM4A(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw StripError(reason: "no audio track")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StripError(reason: "export preset unsupported")
        }
        try await session.export(to: destinationURL, as: .m4a)
    }

    @concurrent
    static func assetHasVideoTrack(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }
}
