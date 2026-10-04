import AppKit
import SwiftUI

struct WorkbenchSessionThumbnail: View {
    let session: WorkbenchSession
    var size: CGSize = CGSize(
        width: AppTheme.Workbench.sessionIconSize,
        height: AppTheme.Workbench.sessionIconSize
    )
    /// Corner type badge only when a real video/poster image is shown (never on the glyph fallback).
    var showsTypeBadge: Bool = false
    var placeholderSize: CGFloat = AppTheme.IconSize.md

    @State private var oEmbedThumbnailURL: URL?
    @State private var localThumbnailData: Data?
    @State private var remoteImageLoaded = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailContent
                .frame(width: size.width, height: size.height)
                .clipped()
            if showsTypeBadge, showsLoadedImage {
                typeBadge
            }
        }
        .frame(width: size.width, height: size.height)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipped()
        .task(id: thumbnailSourceID) {
            await loadThumbnail()
        }
    }

    private var thumbnailSourceID: [String] {
        [
            session.id.uuidString,
            session.sourceURL?.absoluteString ?? "",
            session.outputURL?.absoluteString ?? "",
            session.remoteSourcePosterURL?.absoluteString ?? "",
            session.netVideoSource?.sourceURL.absoluteString ?? "",
            String(describing: session.remoteSourceHasVideo),
        ]
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let oEmbedThumbnailURL {
            remoteAsyncImage(url: oEmbedThumbnailURL)
        } else if let remotePosterURL = session.remoteSourcePosterURL {
            remoteAsyncImage(url: remotePosterURL)
        } else if let localThumbnailData, let image = NSImage(data: localThumbnailData) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            fallback
        }
    }

    private func remoteAsyncImage(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .onAppear { remoteImageLoaded = true }
            case .failure:
                fallback
                    .onAppear { remoteImageLoaded = false }
            case .empty:
                fallback
            @unknown default:
                fallback
            }
        }
    }

    private var fallback: some View {
        session.sessionType.navGlyph.view(size: placeholderSize)
            .foregroundStyle(AppTheme.Accent.link)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var typeBadge: some View {
        session.sessionType.navGlyph.view(size: AppTheme.IconSize.xs)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }
            .padding(AppTheme.Spacing.xs)
    }

    private var showsLoadedImage: Bool {
        if localThumbnailData != nil { return true }
        return remoteImageLoaded
    }

    private func loadThumbnail() async {
        oEmbedThumbnailURL = nil
        localThumbnailData = nil
        remoteImageLoaded = false
        if let netVideo = session.netVideoSource, netVideo.platform == .youtube {
            let url = await YouTubeOEmbedClient.shared.metadata(for: netVideo.sourceURL)?.thumbnailURL
            guard !Task.isCancelled else { return }
            oEmbedThumbnailURL = url
            if url != nil { return }
        }
        guard session.remoteSourceHasVideo != true,
              let sourceURL = session.sourceURL ?? session.outputURL,
              Self.isVideoFile(sourceURL) else {
            return
        }
        let data = await SessionPosterFrameLoader.load(url: sourceURL, enabled: true)
        guard !Task.isCancelled else { return }
        localThumbnailData = data
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased())
    }
}
