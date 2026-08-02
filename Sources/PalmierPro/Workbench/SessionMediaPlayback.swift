import AppKit
import AVFoundation
import Observation
import SwiftUI

enum SessionSubtitleDisplayMode: Equatable, Sendable {
    case off
    case original
    case translation(String)
}

@Observable
@MainActor
final class SessionPlaybackController {
    var player: AVPlayer?
    var peaks: [Float] = []
    var isPlaying = false
    var duration = 0.0
    var playbackRate = 1.0
    var subtitleMode: SessionSubtitleDisplayMode = .original
    var playerViewRef: SessionPlayerView?
    var fullscreenController: SessionFullscreenWindowController?

    private(set) var subtitleTrack: SubtitleTrack?
    private(set) var translationTracks: [WorkbenchTranslationTrack] = []

    func configureSubtitles(
        subtitleTrack: SubtitleTrack?,
        translationTracks: [WorkbenchTranslationTrack]
    ) {
        self.subtitleTrack = subtitleTrack
        self.translationTracks = translationTracks
    }

    var activeSubtitleCues: [SubtitleCue] {
        switch subtitleMode {
        case .off:
            return []
        case .original:
            return subtitleTrack?.cues ?? []
        case .translation(let code):
            return translationTracks.first(where: {
                $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
            })?.track.cues ?? []
        }
    }

    func activeSubtitleText(at time: Double) -> String? {
        guard !activeSubtitleCues.isEmpty else { return nil }
        return activeSubtitleCues.first(where: { time >= $0.start && time < $0.end })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func applyPlaybackRate() {
        player?.rate = isPlaying ? Float(playbackRate) : 0
        player?.defaultRate = Float(playbackRate)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        applyPlaybackRate()
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, player.currentTime().seconds >= duration - AppTheme.Workbench.playerEndTolerance {
                player.seek(to: .zero)
            }
            player.play()
            player.rate = Float(playbackRate)
        }
        isPlaying.toggle()
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        seekAbsolute(to: progress * duration)
    }

    func seekAbsolute(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: AppTheme.Workbench.playerTimescale),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    func seekBy(_ delta: Double) {
        let current = player?.currentTime().seconds.finiteOrZero ?? 0
        seekAbsolute(to: current + delta)
    }

    func dismissFullscreen() {
        fullscreenController?.dismiss()
        fullscreenController = nil
    }

    func toggleFullscreen() {
        guard let view = playerViewRef, let player else { return }
        if let fullscreenController {
            if fullscreenController.isPresented {
                dismissFullscreen()
                return
            }
            self.fullscreenController = nil
        }
        guard let screen = view.window?.screen ?? NSScreen.main else { return }

        view.isHidden = true
        let controller = SessionFullscreenWindowController(
            player: player,
            sourceView: view,
            screen: screen,
            playback: self
        )
        fullscreenController = controller
        controller.present()
    }

    @MainActor
    func load(url: URL?, showsVideoCanvas: Bool) async {
        dismissFullscreen()
        player?.pause()
        isPlaying = false
        peaks = []
        duration = 0
        playerViewRef = nil
        guard let url else {
            player = nil
            return
        }
        let nextPlayer = AVPlayer(url: url)
        nextPlayer.defaultRate = Float(playbackRate)
        player = nextPlayer
        duration = (try? await nextPlayer.currentItem?.asset.load(.duration).seconds)?.finiteOrZero ?? 0
        if !showsVideoCanvas {
            peaks = (try? await WaveformExtractor.peakEnvelope(from: url)) ?? []
        }
        if subtitleTrack != nil {
            subtitleMode = .original
        } else if let first = translationTracks.first {
            subtitleMode = .translation(first.languageCode)
        } else {
            subtitleMode = .off
        }
    }

    func tearDown() {
        dismissFullscreen()
        player?.pause()
    }
}

@Observable
@MainActor
final class SessionFullscreenChromeState {
    var controlsVisible = true
    private var hideTask: Task<Void, Never>?

    func revealControls(autoHide: Bool = true) {
        controlsVisible = true
        NSCursor.unhide()
        hideTask?.cancel()
        guard autoHide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: AppTheme.Workbench.fullscreenChromeIdle)
            guard !Task.isCancelled else { return }
            self?.hideControls()
        }
    }

    func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}

struct SessionFullscreenChrome: View {
    @Bindable var playback: SessionPlaybackController
    @Bindable var chrome: SessionFullscreenChromeState

    var body: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = playback.player?.currentTime().seconds.finiteOrZero ?? 0
            let cueText = playback.activeSubtitleText(at: currentTime)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if chrome.controlsVisible {
                            chrome.hideControls()
                        } else {
                            chrome.revealControls()
                        }
                    }

                if let cueText {
                    VStack {
                        Spacer()
                        Text(cueText)
                            .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.vertical, AppTheme.Spacing.md)
                            .background(
                                Color.black.opacity(AppTheme.Opacity.medium),
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            )
                            .padding(.horizontal, AppTheme.Spacing.xxl)
                            .padding(.bottom, chrome.controlsVisible ? 120 : AppTheme.Spacing.xxl)
                    }
                    .allowsHitTesting(false)
                }

                if chrome.controlsVisible {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                playback.dismissFullscreen()
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                    .frame(
                                        width: AppTheme.Workbench.fullscreenControlSize,
                                        height: AppTheme.Workbench.fullscreenControlSize
                                    )
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                                            .strokeBorder(
                                                AppTheme.Border.primaryColor,
                                                lineWidth: AppTheme.BorderWidth.thin
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("Exit Full Screen")
                        }
                        .padding(AppTheme.Spacing.xl)

                        Spacer()

                        bottomChrome(currentTime: currentTime)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.bottom, AppTheme.Spacing.xl)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: AppTheme.Anim.transition), value: chrome.controlsVisible)
        }
    }

    private func bottomChrome(currentTime: Double) -> some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            Slider(
                value: Binding(
                    get: {
                        playback.duration > 0
                            ? min(1, max(0, currentTime / playback.duration))
                            : 0
                    },
                    set: { progress in
                        chrome.revealControls()
                        playback.seek(to: progress)
                    }
                ),
                in: 0...1
            )
            .disabled(playback.player == nil || playback.duration <= 0)

            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    chrome.revealControls()
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(playback.player == nil)

                Text("\(formatTime(currentTime)) / \(formatTime(playback.duration))")
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Spacer(minLength: AppTheme.Spacing.sm)

                fullscreenSubtitleMenu
                fullscreenSpeedMenu

                Button {
                    playback.dismissFullscreen()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.bordered)
                .help("Exit Full Screen")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var fullscreenSubtitleMenu: some View {
        Menu {
            Button {
                chrome.revealControls()
                playback.subtitleMode = .off
            } label: {
                labelWithCheck("Off", selected: playback.subtitleMode == .off)
            }
            Button {
                chrome.revealControls()
                playback.subtitleMode = .original
            } label: {
                labelWithCheck("Original", selected: playback.subtitleMode == .original)
            }
            if !playback.translationTracks.isEmpty {
                Divider()
                ForEach(playback.translationTracks) { track in
                    Button {
                        chrome.revealControls()
                        playback.subtitleMode = .translation(track.languageCode)
                    } label: {
                        labelWithCheck(
                            track.displayLanguageLabel,
                            selected: {
                                if case .translation(let code) = playback.subtitleMode {
                                    return code.caseInsensitiveCompare(track.languageCode) == .orderedSame
                                }
                                return false
                            }()
                        )
                    }
                }
            }
        } label: {
            Text("CC")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    playback.subtitleMode == .off
                        ? AppTheme.Background.raisedColor
                        : AppTheme.Text.primaryColor,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                )
                .foregroundStyle(
                    playback.subtitleMode == .off
                        ? AppTheme.Text.primaryColor
                        : AppTheme.Background.baseColor
                )
        }
        .menuStyle(.borderlessButton)
        .disabled(playback.subtitleTrack == nil && playback.translationTracks.isEmpty)
        .help("Subtitles")
    }

    private var fullscreenSpeedMenu: some View {
        Menu {
            ForEach(AppTheme.Workbench.playbackRates, id: \.self) { rate in
                Button {
                    chrome.revealControls()
                    playback.setPlaybackRate(rate)
                } label: {
                    labelWithCheck(speedLabel(rate), selected: abs(playback.playbackRate - rate) < 0.001)
                }
            }
        } label: {
            Text("Speed \(speedLabel(playback.playbackRate))")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .menuStyle(.borderlessButton)
        .help("Playback speed")
    }

    @ViewBuilder
    private func labelWithCheck(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func speedLabel(_ rate: Double) -> String {
        if abs(rate - 1) < 0.001 { return "1x" }
        if rate == Double(Int(rate)) { return "\(Int(rate))x" }
        return String(format: "%gx", rate)
    }
}

struct SessionAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var onViewReady: ((SessionPlayerView) -> Void)?

    func makeNSView(context: Context) -> SessionPlayerView {
        let view = SessionPlayerView()
        view.player = player
        DispatchQueue.main.async { onViewReady?(view) }
        return view
    }

    func updateNSView(_ nsView: SessionPlayerView, context: Context) {
        nsView.player = player
        DispatchQueue.main.async { onViewReady?(nsView) }
    }

    static func dismantleNSView(_ nsView: SessionPlayerView, coordinator: ()) {
        nsView.stopPlayback()
    }
}

@MainActor
final class SessionFullscreenWindowController: NSWindowController, NSWindowDelegate {
    private let screen: NSScreen
    private weak var sourceView: SessionPlayerView?
    private let playback: SessionPlaybackController
    private let chromeState = SessionFullscreenChromeState()
    private let playerView = SessionPlayerView(frame: .zero)
    private let containerView = SessionFullscreenContainerView()
    private var hostingView: NSHostingView<SessionFullscreenChrome>?
    private let previousPresentationOptions: NSApplication.PresentationOptions
    private var didRestorePresentationOptions = false
    private var keyMonitor: Any?
    private(set) var isPresented = false

    init(
        player: AVPlayer,
        sourceView: SessionPlayerView,
        screen: NSScreen,
        playback: SessionPlaybackController
    ) {
        self.screen = screen
        self.sourceView = sourceView
        self.playback = playback
        self.previousPresentationOptions = NSApp.presentationOptions

        let window = SessionFullscreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = AppTheme.Background.base
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces]
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        playerView.player = player
        playerView.autoresizingMask = [.width, .height]
        playerView.frame = screen.frame

        let chrome = SessionFullscreenChrome(playback: playback, chrome: chromeState)
        let hosting = NSHostingView(rootView: chrome)
        hosting.frame = screen.frame
        hosting.autoresizingMask = [.width, .height]
        hostingView = hosting

        containerView.frame = screen.frame
        containerView.autoresizingMask = [.width, .height]
        containerView.onMouseActivity = { [weak self] in
            self?.chromeState.revealControls()
        }
        containerView.addSubview(playerView)
        containerView.addSubview(hosting)
        window.contentView = containerView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard !isPresented, let window else { return }
        isPresented = true
        sourceView?.isHidden = true
        NSApp.presentationOptions = previousPresentationOptions.union([
            .autoHideDock,
            .autoHideMenuBar,
        ])
        window.setFrame(screen.frame, display: true)
        playerView.frame = window.contentView?.bounds ?? screen.frame
        hostingView?.frame = window.contentView?.bounds ?? screen.frame
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(containerView)
        chromeState.revealControls()
        installKeyMonitor()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        removeKeyMonitor()
        chromeState.cancelAutoHide()
        NSCursor.unhide()
        playerView.player = nil
        window?.orderOut(nil)
        sourceView?.isHidden = false
        playback.fullscreenController = nil
        restorePresentationOptions()
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    private func restorePresentationOptions() {
        guard !didRestorePresentationOptions else { return }
        didRestorePresentationOptions = true
        NSApp.presentationOptions = previousPresentationOptions
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.isPresented,
                  self.window?.isKeyWindow == true else {
                return event
            }
            switch event.keyCode {
            case 53: // Escape
                self.playback.dismissFullscreen()
                return nil
            case 49: // Space
                self.chromeState.revealControls()
                self.playback.togglePlayback()
                return nil
            case 123: // Left arrow
                self.chromeState.revealControls()
                self.playback.seekBy(-AppTheme.Workbench.fullscreenSeekStepSeconds)
                return nil
            case 124: // Right arrow
                self.chromeState.revealControls()
                self.playback.seekBy(AppTheme.Workbench.fullscreenSeekStepSeconds)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

private final class SessionFullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SessionFullscreenContainerView: NSView {
    var onMouseActivity: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseActivity?()
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseActivity?()
        super.mouseEntered(with: event)
    }
}

final class SessionPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.Background.base.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func stopPlayback() {
        player?.pause()
        player = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
