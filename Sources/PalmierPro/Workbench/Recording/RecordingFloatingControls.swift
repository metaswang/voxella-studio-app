import AppKit
import SwiftUI

@MainActor
final class RecordingFloatingControlsController {
    private var panel: NSPanel?
    private nonisolated(unsafe) var zoomObserver: NSObjectProtocol?

    init() {
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .voxellaZoomScaleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyZoomScale()
            }
        }
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    func present(session: RecordingSessionController, displayID: UInt32? = nil) {
        guard panel == nil else { return }
        let scale = AppZoomScale.shared.scale
        let size = NSSize(
            width: AppTheme.Workbench.recordingControlsWidth * scale,
            height: AppTheme.Workbench.recordingControlsHeight * scale
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = L10n.string("Recording Controls")
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = RecordingControlsHostingView(
            rootView: RecordingFloatingControlsView(session: session)
                .appZoomEnvironment()
                .appLocalization()
        )
        let screen = NSScreen.screens.first { $0.displayID == displayID }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - AppTheme.Spacing.lg * scale
            ))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func update(session: RecordingSessionController) {
        if session.phase.isCapturing {
            present(session: session)
        } else if session.phase == .idle || session.phase == .finishing {
            close()
        }
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func applyZoomScale() {
        guard let panel else { return }
        let scale = AppZoomScale.shared.scale
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setContentSize(NSSize(
            width: AppTheme.Workbench.recordingControlsWidth * scale,
            height: AppTheme.Workbench.recordingControlsHeight * scale
        ))
        panel.setFrameOrigin(NSPoint(
            x: center.x - panel.frame.width / 2,
            y: center.y - panel.frame.height / 2
        ))
    }
}

private final class RecordingControlsHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct RecordingFloatingControlsView: View {
    let session: RecordingSessionController

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(session.isPaused ? AppTheme.Status.warningColor : AppTheme.Status.errorColor)
            RecordingFloatingTimer(session: session)
            RecordingLiveWaveformView(store: session.liveWaveform, isPaused: session.isPaused)
                .frame(width: AppTheme.Workbench.recordingControlsWaveformWidth)
            Divider().padding(.vertical, AppTheme.Spacing.sm)
            control(
                session.isPaused ? "play.fill" : "pause.fill",
                label: session.isPaused ? "Resume Recording" : "Pause Recording",
                action: session.togglePause
            )
            control(
                session.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                label: session.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
                action: session.toggleMicrophoneMuted
            )
            .disabled(!session.configuration.microphone.isEnabled)
            control("stop.fill", label: "Stop Recording", action: session.stop)
                .foregroundStyle(AppTheme.Status.errorColor)
        }
        .disabled(!session.phase.isCapturing)
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(
            width: AppTheme.Workbench.recordingControlsWidth,
            height: AppTheme.Workbench.recordingControlsHeight
        )
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .frame(
                    width: AppTheme.Workbench.recordingControlsButtonSize,
                    height: AppTheme.Workbench.recordingControlsButtonSize
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RecordingFloatingTimer: View {
    let session: RecordingSessionController

    var body: some View {
        Text(session.phase.isCapturing ? RecordingTimeFormat.clock(session.elapsed) : "Preparing…")
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(width: AppTheme.Workbench.recordingControlsTimerWidth, alignment: .leading)
            .accessibilityLabel(session.isPaused ? "Paused" : "Recording")
            .accessibilityValue(RecordingTimeFormat.clock(session.elapsed))
    }
}
