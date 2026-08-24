import AppKit
import SwiftUI
import WebKit

struct NetVideoFloatingPlayer: View {
    let source: WorkbenchNetVideoSource

    @AppStorage("workbench.netVideoPlayer.collapsed") private var isCollapsed = false
    @AppStorage("workbench.netVideoPlayer.offsetX") private var storedOffsetX = 0.0
    @AppStorage("workbench.netVideoPlayer.offsetY") private var storedOffsetY = 0.0
    @AppStorage("workbench.netVideoPlayer.width") private var storedWidth = Double(AppTheme.Workbench.netVideoCardWidth)
    @AppStorage("workbench.netVideoPlayer.height") private var storedHeight = Double(AppTheme.Workbench.netVideoCardHeight)

    @State private var fullscreenController: NetVideoFullscreenWindowController?
    @State private var dragTranslation = CGSize.zero

    private let minimumWidth = 280.0
    private let minimumHeight = 180.0
    private let maximumWidth = 960.0
    private let maximumHeight = 720.0

    private var playerWidth: CGFloat { CGFloat(storedWidth) }
    private var playerHeight: CGFloat { CGFloat(storedHeight) }
    private var visibleHeight: CGFloat {
        isCollapsed ? AppTheme.Workbench.netVideoCardCollapsedHeight : playerHeight
    }
    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            if !isCollapsed {
                NetVideoPlaybackView(source: source)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
                .padding(AppTheme.Spacing.smMd)
            }
        }
        .frame(width: playerWidth, height: visibleHeight, alignment: .top)
        .overlay(alignment: .topLeading) { resizeHandle(.topLeading) }
        .overlay(alignment: .topTrailing) { resizeHandle(.topTrailing) }
        .overlay(alignment: .bottomLeading) { resizeHandle(.bottomLeading) }
        .overlay(alignment: .bottomTrailing) { resizeHandle(.bottomTrailing) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.md)
        .offset(
            x: storedOffsetX + dragTranslation.width,
            y: storedOffsetY + dragTranslation.height
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragTranslation = value.translation
                }
                .onEnded { value in
                    storedOffsetX += value.translation.width
                    storedOffsetY += value.translation.height
                    dragTranslation = .zero
                }
        )
        .onDisappear {
            NSCursor.arrow.set()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "play.square")
                .foregroundStyle(AppTheme.Status.warningColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(source.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? source.title ?? platformTitle
                    : platformTitle)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .lineLimit(1)
                Text("\(platformTitle) preview")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: openFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .help("Open full-screen player")
            Button {
                NSWorkspace.shared.open(source.sourceURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .help("Open source page")
            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "arrowtriangle.down" : "minus")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand preview" : "Collapse preview")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Workbench.netVideoCardCollapsedHeight)
        .background(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.faint))
        .contentShape(Rectangle())
    }

    private func resizeHandle(_ corner: ResizeCorner) -> some View {
        Color.clear
            .frame(width: 20, height: 20)
            .padding(AppTheme.Spacing.xs)
            .contentShape(Rectangle())
            .onHover { isHovering in
                guard !isCollapsed else { return }
                if isHovering {
                    corner.cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .allowsHitTesting(!isCollapsed)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        corner.cursor.set()
                        resize(corner: corner, translation: value.translation)
                    }
                    .onEnded { _ in
                        NSCursor.arrow.set()
                    }
            )
            .help("Resize player")
    }

    private func resize(corner: ResizeCorner, translation: CGSize) {
        let nextWidth = min(maximumWidth, max(minimumWidth, playerWidth + corner.horizontalSign * translation.width))
        let nextHeight = min(maximumHeight, max(minimumHeight, playerHeight + corner.verticalSign * translation.height))
        let widthDelta = nextWidth - playerWidth
        let heightDelta = nextHeight - playerHeight
        storedWidth = nextWidth
        storedHeight = nextHeight
        storedOffsetX += Double(corner.horizontalSign) * widthDelta / 2
        storedOffsetY += Double(corner.verticalSign) * heightDelta / 2
    }

    private func openFullscreen() {
        let controller = NetVideoFullscreenWindowController(source: source) {
            fullscreenController = nil
        }
        fullscreenController = controller
        controller.show()
    }

    private var platformTitle: String {
        switch source.platform {
        case .youtube: "YouTube"
        case .gettr: "Gettr"
        case .ganjingworld: "GanjingWorld"
        case .x: "X"
        case .unknown: "Net Video"
        }
    }
}

private enum ResizeCorner {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var horizontalSign: CGFloat {
        switch self {
        case .topLeading, .bottomLeading: -1
        case .topTrailing, .bottomTrailing: 1
        }
    }

    var verticalSign: CGFloat {
        switch self {
        case .topLeading, .topTrailing: -1
        case .bottomLeading, .bottomTrailing: 1
        }
    }

    var cursor: NSCursor {
        let symbolName: String
        switch self {
        case .topLeading, .bottomTrailing:
            symbolName = "arrow.up.left.and.arrow.down.right"
        case .topTrailing, .bottomLeading:
            symbolName = "arrow.up.right.and.arrow.down.left"
        }
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Resize player"
        ) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }
}

private final class NetVideoFullscreenWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var keyMonitor: Any?

    init(source: WorkbenchNetVideoSource, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        super.init(window: window)
        window.contentView = NSHostingView(rootView: NetVideoFullscreenView(source: source) { [weak self] in
            self?.closeFullscreen()
        })
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.setFrame(NSScreen.main?.frame ?? window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closeFullscreen()
            return nil
        }
    }

    private func closeFullscreen() {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        window?.close()
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        onClose()
    }
}

private struct NetVideoFullscreenView: View {
    let source: WorkbenchNetVideoSource
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NetVideoPlaybackView(source: source)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: AppTheme.Spacing.md) {
                Text(source.title ?? "Net Video")
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Exit full-screen player")
            }
            .padding(AppTheme.Spacing.lg)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(AppTheme.Spacing.xl)
        }
        .background(.black)
        .focusable()
        .onExitCommand(perform: onClose)
    }
}

private struct NetVideoPlaybackView: View {
    let source: WorkbenchNetVideoSource

    var body: some View {
        NetVideoWebView(url: source.embedURL ?? source.sourceURL)
    }
}

private struct NetVideoWebView: NSViewRepresentable {
    let url: URL

    /// YouTube requires a non-empty HTTP Referer that identifies the embedding app.
    /// Format: https://{bundleId} — see YouTube Required Minimum Functionality.
    private static var appReferer: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.voxella.studio"
        return "https://\(bundleID)".lowercased()
    }

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        loadPlayerDocument(in: webView, url: url, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL?.absoluteString != url.absoluteString else { return }
        loadPlayerDocument(in: webView, url: url, coordinator: context.coordinator)
    }

    private func loadPlayerDocument(in webView: WKWebView, url: URL, coordinator: Coordinator) {
        coordinator.loadedURL = url
        if let request = youtubeEmbedRequest(for: url) {
            webView.load(request)
            return
        }

        let escapedURL = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!doctype html>
        <html><head>
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <meta name=\"referrer\" content=\"strict-origin-when-cross-origin\">
        </head>
        <body style=\"margin:0;background:#000;overflow:hidden\">
        <iframe src=\"\(escapedURL)\" title=\"Video player\" style=\"border:0;width:100vw;height:100vh\"
          referrerpolicy=\"strict-origin-when-cross-origin\"
          allow=\"autoplay; encrypted-media; picture-in-picture; web-share\" allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: Self.appReferer))
    }

    /// Load YouTube embed as a top-level navigation with an explicit Referer.
    /// iframe + loadHTMLString often strips Referer on WKWebView (Error 152-4 / 153).
    private func youtubeEmbedRequest(for url: URL) -> URLRequest? {
        let embedURL: URL
        if Self.isYouTubeEmbedURL(url) {
            embedURL = Self.embedURLWithAppOrigin(url)
        } else if let videoID = YouTubeURL.videoID(from: url.absoluteString) {
            var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
            components?.queryItems = [
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
                URLQueryItem(name: "modestbranding", value: "1"),
                URLQueryItem(name: "origin", value: Self.appReferer),
            ]
            guard let built = components?.url else { return nil }
            embedURL = built
        } else {
            return nil
        }

        var request = URLRequest(url: embedURL)
        request.setValue(Self.appReferer, forHTTPHeaderField: "Referer")
        return request
    }

    private static func embedURLWithAppOrigin(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "origin" }
        items.append(URLQueryItem(name: "origin", value: appReferer))
        components.queryItems = items
        return components.url ?? url
    }

    private static func isYouTubeEmbedURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let youtubeHosts: Set<String> = [
            "youtube.com", "www.youtube.com", "m.youtube.com",
            "youtube-nocookie.com", "www.youtube-nocookie.com",
        ]
        return youtubeHosts.contains(host) && url.path.lowercased().hasPrefix("/embed/")
    }
}
