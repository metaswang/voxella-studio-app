import AppKit
import AVKit
import SwiftUI

enum ExportVideoPreviewError: LocalizedError {
    case missing, unreadable, unplayable, noVideo

    var errorDescription: String? {
        switch self {
        case .missing: "The exported file was moved or deleted."
        case .unreadable: "VoxStudio cannot read this file. Check its permissions."
        case .unplayable: "This video cannot be played. It may be damaged or use an unsupported format."
        case .noVideo: "This file does not contain a video track. Export a video to preview it here."
        }
    }
}

@MainActor @Observable
final class ExportVideoPlayback {
    enum Phase { case idle, loading, ready, failed }
    typealias Loader = @MainActor (URL) async throws -> AVPlayerItem

    let player = AVPlayer()
    private(set) var url: URL?
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?

    init(loader: @escaping Loader = ExportVideoPlayback.loadItem) {
        self.loader = loader
    }

    func open(_ url: URL) {
        stop()
        self.url = url
        error = nil
        phase = .loading
        let request = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await loader(url)
                guard !Task.isCancelled, generation == request else { return }
                statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == request else { return }
                        switch status {
                        case .readyToPlay:
                            self.phase = .ready
                            self.player.play()
                        case .failed:
                            self.fail(ExportVideoPreviewError.unplayable)
                        default: break
                        }
                    }
                }
                failureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == request else { return }
                        self.fail(ExportVideoPreviewError.unplayable)
                    }
                }
                player.replaceCurrentItem(with: item)
            } catch is CancellationError {
                // Dismissal and switching files are normal, silent cancellation paths.
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                fail(error)
            }
        }
    }

    func retry() {
        if let url { open(url) }
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        phase = .idle
        error = nil
        url = nil
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }

    private func fail(_ error: Error) {
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.error = (error as? ExportVideoPreviewError)?.errorDescription
            ?? ExportVideoPreviewError.unplayable.errorDescription
        phase = .failed
    }

    static func loadItem(at url: URL) async throws -> AVPlayerItem {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExportVideoPreviewError.missing }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ExportVideoPreviewError.unreadable }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw ExportVideoPreviewError.unplayable }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ExportVideoPreviewError.noVideo }
        try Task.checkCancellation()
        return AVPlayerItem(asset: asset)
    }
}

/// Owned by the export view; one reusable window plays only exported files.
@MainActor
final class ExportVideoPreviewController: NSWindowController, NSWindowDelegate {
    let playback = ExportVideoPlayback()

    init() {
        let panel = ExportPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 440, height: 340)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ExportVideoPreviewView(playback: playback)
            .appZoomEnvironment().appLocalization())
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(url: URL) {
        playback.open(url)
        window?.title = L10n.string("Exported video") + " — " + url.lastPathComponent
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        playback.stop()
        super.close()
    }

    func windowWillClose(_ notification: Notification) { playback.stop() }
}

private final class ExportPreviewPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct ExportVideoPreviewView: View {
    let playback: ExportVideoPlayback

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                ExportNativePlayerView(player: playback.player)
                    .opacity(playback.phase == .ready ? 1 : 0)
                if playback.phase == .loading {
                    ProgressView(L10n.string("Loading video…"))
                        .tint(.white).foregroundStyle(.white)
                } else if let error = playback.error {
                    VStack(spacing: AppTheme.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(L10n.string(key: error)).multilineTextAlignment(.center)
                        Button(L10n.string("Retry")) { playback.retry() }
                    }.foregroundStyle(.white).padding(AppTheme.Spacing.xl)
                }
            }
            HStack {
                Text(playback.url?.lastPathComponent ?? "")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.string("Show in Finder")) {
                    if let url = playback.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.disabled(playback.url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .padding(AppTheme.Spacing.md)
        }
        .background(AppTheme.Background.raisedColor)
    }
}

private struct ExportNativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
