import AppKit
import SwiftUI

@MainActor
final class VoiceInputPanelController: NSObject, NSWindowDelegate {
    private static let savedOriginDefaultsKey = "VoxStudioVoiceInputPanelOrigin-v1"

    private weak var coordinator: VoiceInputCoordinator?
    private var panel: VoiceInputPanel?
    private var focusRetryScheduled = false
    private var unscaledPanelHeight = AppTheme.SpeechInput.quickInputMinimumHeight
    private nonisolated(unsafe) var zoomObserver: NSObjectProtocol?

    init(coordinator: VoiceInputCoordinator) {
        self.coordinator = coordinator
        super.init()
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

    func present() {
        let panel = makePanelIfNeeded()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? .zero
        let maximumHeight = unscaledMaximumHeight(in: visibleFrame)
        coordinator?.updateEditorMaximumHeight(maximumHeight - AppTheme.SpeechInput.quickInputMinimumHeight)
        unscaledPanelHeight = AppTheme.SpeechInput.quickInputMinimumHeight
        setPanelContentSize(
            width: AppTheme.SpeechInput.quickInputWidth,
            height: unscaledPanelHeight,
            keepingCenterOf: panel
        )
        restoreSavedOriginOrCenter(panel, on: visibleFrame)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        restoreEditorFocus()
    }

    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
    }

    func resize(to requestedHeight: CGFloat) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let maximum = unscaledMaximumHeight(in: screen.visibleFrame)
        let height = min(maximum, max(AppTheme.SpeechInput.quickInputMinimumHeight, requestedHeight))
        unscaledPanelHeight = height
        coordinator?.updateEditorMaximumHeight(maximum - AppTheme.SpeechInput.quickInputMinimumHeight)
        let scaledHeight = height * AppZoomScale.shared.scale
        guard abs(panel.frame.height - scaledHeight) > AppTheme.BorderWidth.thin else { return }
        setPanelContentSize(
            width: AppTheme.SpeechInput.quickInputWidth,
            height: height,
            keepingCenterOf: panel
        )
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.dismiss()
    }

    func windowDidMove(_ notification: Notification) {
        savePanelOrigin()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        restoreEditorFocus()
    }

    func restoreEditorFocus() {
        guard let panel, panel.isVisible, let contentView = panel.contentView else { return }
        if let editor = focusTarget(in: contentView) {
            editor.requestFocus()
            return
        }

        guard !focusRetryScheduled else { return }
        focusRetryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusRetryScheduled = false
            self.restoreEditorFocus()
        }
    }

    private func makePanelIfNeeded() -> VoiceInputPanel {
        if let panel { return panel }
        let panel = VoiceInputPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: AppTheme.SpeechInput.quickInputWidth, height: AppTheme.SpeechInput.quickInputMinimumHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + AppTheme.SpeechInput.quickInputPanelLevelOffset)
        panel.title = L10n.string("Voice Input")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native panel shadows follow the rectangular window bounds.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let contentView = NSHostingView(
            rootView: VoiceInputPanelView(coordinator: coordinator!)
                .appZoomEnvironment()
                .appLocalization()
        )
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = AppTheme.Radius.xl
        contentView.layer?.masksToBounds = true
        panel.contentView = contentView
        self.panel = panel
        return panel
    }

    private func applyZoomScale() {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let maximum = unscaledMaximumHeight(in: visibleFrame)
        unscaledPanelHeight = min(maximum, max(AppTheme.SpeechInput.quickInputMinimumHeight, unscaledPanelHeight))
        coordinator?.updateEditorMaximumHeight(maximum - AppTheme.SpeechInput.quickInputMinimumHeight)
        setPanelContentSize(
            width: AppTheme.SpeechInput.quickInputWidth,
            height: unscaledPanelHeight,
            keepingCenterOf: panel
        )
    }

    private func unscaledMaximumHeight(in visibleFrame: NSRect) -> CGFloat {
        visibleFrame.height
            * AppTheme.SpeechInput.quickInputMaximumHeightRatio
            / AppZoomScale.shared.scale
    }

    private func setPanelContentSize(width: CGFloat, height: CGFloat, keepingCenterOf panel: NSPanel) {
        let scale = AppZoomScale.shared.scale
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setContentSize(NSSize(width: width * scale, height: height * scale))
        panel.setFrameOrigin(NSPoint(
            x: center.x - panel.frame.width / 2,
            y: center.y - panel.frame.height / 2
        ))
    }

    private func restoreSavedOriginOrCenter(_ panel: NSPanel, on visibleFrame: NSRect) {
        if let savedOrigin = savedPanelOrigin {
            let savedFrame = panel.frame.offsetBy(
                dx: savedOrigin.x - panel.frame.origin.x,
                dy: savedOrigin.y - panel.frame.origin.y
            )
            guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) else {
                centerPanel(panel, in: visibleFrame)
                return
            }
            panel.setFrameOrigin(savedOrigin)
            return
        }

        centerPanel(panel, in: visibleFrame)
    }

    private func centerPanel(_ panel: NSPanel, in visibleFrame: NSRect) {
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        ))
    }

    private var savedPanelOrigin: NSPoint? {
        guard let values = UserDefaults.standard.dictionary(forKey: Self.savedOriginDefaultsKey),
              let x = (values["x"] as? NSNumber)?.doubleValue,
              let y = (values["y"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    private func savePanelOrigin() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set(
            ["x": Double(origin.x), "y": Double(origin.y)],
            forKey: Self.savedOriginDefaultsKey
        )
    }

    private func focusTarget(in view: NSView) -> VoiceInputFocusTarget? {
        if let target = view as? VoiceInputFocusTarget {
            return target
        }
        for subview in view.subviews {
            if let target = focusTarget(in: subview) {
                return target
            }
        }
        return nil
    }
}

private final class VoiceInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct VoiceInputPanelView: View {
    @Bindable var coordinator: VoiceInputCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            inputArea
            status
            footer
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.top, AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.md)
        .frame(width: AppTheme.SpeechInput.quickInputWidth)
        .background(.ultraThinMaterial, in: panelShape)
        .clipShape(panelShape)
        .overlay {
            panelShape
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.lg)
        .onAppear { resizeForDraft() }
        .onChange(of: coordinator.draft) { _, _ in resizeForDraft() }
    }

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: AppTheme.Spacing.md) {
            ZStack(alignment: .topLeading) {
                NativePlaceholderTextEditor(
                    text: $coordinator.draft,
                    placeholder: L10n.string("Speak or type…"),
                    fontSize: AppTheme.FontSize.mdLg,
                    textInset: NSSize(width: AppTheme.Spacing.xs, height: AppTheme.Spacing.xs),
                    showsVerticalScroller: false,
                    onReturn: { coordinator.submit() },
                    onEscape: { coordinator.dismiss() }
                )
                    .frame(height: editorHeight)

                if coordinator.recorder.isRecording {
                    VStack(spacing: AppTheme.Spacing.smMd) {
                        Spacer(minLength: AppTheme.Spacing.zero)
                        HStack(spacing: AppTheme.Spacing.smMd) {
                            RecordingLiveWaveformView(
                                store: coordinator.recorder.waveform,
                                isPaused: coordinator.recorder.isTransitioning
                            )
                            .frame(width: AppTheme.SpeechInput.quickInputRecordingWaveformWidth)
                            Text(Duration.seconds(coordinator.recorder.duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .monospacedDigit()
                        }
                    }
                    .padding(.bottom, AppTheme.Spacing.xs)
                    .allowsHitTesting(false)
                }
            }

            Button(action: coordinator.toggleRecording) {
                Image(systemName: coordinator.recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .frame(width: AppTheme.IconSize.xl, height: AppTheme.IconSize.xl)
                    .padding(AppTheme.Spacing.sm)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .background(
                        coordinator.recorder.isRecording ? AppTheme.Status.errorColor : AppTheme.Background.raisedColor,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isBusy)
            .accessibilityLabel(L10n.string(coordinator.recorder.isRecording ? "Stop recording" : "Start recording"))
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = coordinator.recorder.errorMessage ?? coordinator.errorMessage {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Label(L10n.display(error), systemImage: "exclamationmark.triangle.fill")
                if coordinator.recorder.needsMicrophoneSettings {
                    Button("Open System Settings", action: coordinator.recorder.openMicrophoneSettings)
                        .buttonStyle(.link)
                }
            }
            .foregroundStyle(AppTheme.Status.errorColor)
        } else {
            switch coordinator.recognition.state {
            case .recognizing(_, let message):
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.display(message))
                    Button("Cancel") { coordinator.dismiss() }
                        .buttonStyle(.link)
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            case .recognized:
                Label("Transcription complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Status.successColor)
            case .failed(let message):
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Label(L10n.display(message), systemImage: "exclamationmark.triangle.fill")
                    Button("Retry", action: coordinator.retryRecognition)
                        .buttonStyle(.link)
                }
                .foregroundStyle(AppTheme.Status.errorColor)
            case .idle:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        Text(L10n.string(
            coordinator.insertsIntoField
                ? "Return: Insert & Close   ⇧Return: New Line   Esc: Close"
                : "Return: Copy & Close   ⇧Return: New Line   Esc: Close"
        ))
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
    }

    private var editorHeight: CGFloat {
        let lines = max(1, coordinator.draft.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
            $0 + max(1, Int(ceil(Double($1.count) / Double(AppTheme.SpeechInput.quickInputEstimatedLineWidth))))
        })
        return min(
            coordinator.editorMaximumHeight,
            max(AppTheme.SpeechInput.quickInputEditorMinimumHeight, CGFloat(lines) * AppTheme.SpeechInput.quickInputEditorLineHeight)
        )
    }

    private var panelHeight: CGFloat {
        AppTheme.SpeechInput.quickInputMinimumHeight + max(
            AppTheme.Spacing.zero,
            editorHeight - AppTheme.SpeechInput.quickInputEditorMinimumHeight
        )
    }

    private func resizeForDraft() {
        coordinator.resizePanel(to: panelHeight)
    }
}
