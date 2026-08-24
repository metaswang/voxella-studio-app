import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchSessionThumbnail: View {
    let session: WorkbenchSession

    @State private var oEmbedThumbnailURL: URL?
    @State private var localThumbnailData: Data?

    var body: some View {
        Group {
            if let oEmbedThumbnailURL {
                AsyncImage(url: oEmbedThumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else if let remotePosterURL = session.remoteSourcePosterURL {
                AsyncImage(url: remotePosterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else if let localThumbnailData, let image = NSImage(data: localThumbnailData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: AppTheme.Workbench.sessionIconSize, height: AppTheme.Workbench.sessionIconSize)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipped()
        .task(id: session.id) {
            await loadThumbnail()
        }
    }

    private var fallback: some View {
        Image(systemName: isVideoSession ? "play.square" : "square.and.arrow.down")
            .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Accent.link)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isVideoSession: Bool {
        session.netVideoSource != nil
            || session.remoteSourceHasVideo == true
            || session.remoteSourcePosterURL != nil
            || (session.sourceURL.map(Self.isVideoFile) ?? false)
            || (session.outputURL.map(Self.isVideoFile) ?? false)
    }

    private func loadThumbnail() async {
        oEmbedThumbnailURL = nil
        localThumbnailData = nil
        if let netVideo = session.netVideoSource, netVideo.platform == .youtube {
            oEmbedThumbnailURL = await YouTubeOEmbedClient.shared.metadata(for: netVideo.sourceURL)?.thumbnailURL
            return
        }
        guard session.remoteSourceHasVideo != true,
              let sourceURL = session.sourceURL ?? session.outputURL,
              Self.isVideoFile(sourceURL) else {
            return
        }
        localThumbnailData = await Self.firstFrameData(for: sourceURL)
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased())
    }

    private static func firstFrameData(for url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }.value
    }
}
