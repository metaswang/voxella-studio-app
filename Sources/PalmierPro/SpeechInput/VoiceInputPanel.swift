import AppKit
import SwiftUI

@MainActor
final class VoiceInputPanelController: NSObject, NSWindowDelegate {
    private weak var coordinator: VoiceInputCoordinator?
    private var panel: VoiceInputPanel?

    init(coordinator: VoiceInputCoordinator) {
        self.coordinator = coordinator
    }

    func present() {
        let panel = makePanelIfNeeded()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? .zero
        let maximumHeight = visibleFrame.height * AppTheme.SpeechInput.quickInputMaximumHeightRatio
        coordinator?.updateEditorMaximumHeight(maximumHeight - AppTheme.SpeechInput.quickInputMinimumHeight)
        panel.setContentSize(NSSize(
            width: AppTheme.SpeechInput.quickInputWidth,
            height: AppTheme.SpeechInput.quickInputMinimumHeight
        ))
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        ))
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
    }

    func resize(to requestedHeight: CGFloat) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let maximum = screen.visibleFrame.height * AppTheme.SpeechInput.quickInputMaximumHeightRatio
        let height = min(maximum, max(AppTheme.SpeechInput.quickInputMinimumHeight, requestedHeight))
        guard abs(panel.frame.height - height) > AppTheme.BorderWidth.thin else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setContentSize(NSSize(width: AppTheme.SpeechInput.quickInputWidth, height: height))
        panel.setFrameOrigin(NSPoint(x: center.x - panel.frame.width / 2, y: center.y - panel.frame.height / 2))
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.dismiss()
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
        panel.title = "Voice Input"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native panel shadows follow the rectangular window bounds.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let contentView = NSHostingView(rootView: VoiceInputPanelView(coordinator: coordinator!))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = AppTheme.Radius.xl
        contentView.layer?.masksToBounds = true
        panel.contentView = contentView
        self.panel = panel
        return panel
    }
}

private final class VoiceInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct VoiceInputPanelView: View {
    @Bindable var coordinator: VoiceInputCoordinator
    @FocusState private var isEditorFocused: Bool

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
        .onAppear { focusAndResize() }
        .onChange(of: coordinator.focusGeneration) { _, _ in focusAndResize() }
        .onChange(of: coordinator.draft) { _, _ in resizeForDraft() }
        .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift), coordinator.canSubmit else { return .ignored }
            return coordinator.submit() ? .handled : .ignored
        }
        .onKeyPress(.escape, phases: .down) { _ in
            coordinator.dismiss()
            return .handled
        }
    }

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: AppTheme.Spacing.md) {
            ZStack(alignment: .topLeading) {
                NativePlaceholderTextEditor(
                    text: $coordinator.draft,
                    placeholder: "Speak or type…",
                    fontSize: AppTheme.FontSize.mdLg,
                    textInset: NSSize(width: AppTheme.Spacing.xs, height: AppTheme.Spacing.xs),
                    showsVerticalScroller: false,
                    autofocus: isEditorFocused
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
            .accessibilityLabel(coordinator.recorder.isRecording ? "Stop recording" : "Start recording")
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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                if coordinator.recorder.needsMicrophoneSettings {
                    Button("Open System Settings", action: coordinator.recorder.openMicrophoneSettings)
                        .buttonStyle(.link)
                }
            }
            .foregroundStyle(AppTheme.Status.errorColor)
        } else {
            switch coordinator.recognition.state {
            case .recognizing:
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            case .recognized:
                Label("Transcription complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Status.successColor)
            case .failed(let message):
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
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
        Text(coordinator.insertsIntoField ? "Return: Insert & Close   ⇧Return: New Line   Esc: Close" : "Return: Copy & Close   ⇧Return: New Line   Esc: Close")
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

    private func focusAndResize() {
        isEditorFocused = true
        resizeForDraft()
    }

    private func resizeForDraft() {
        coordinator.resizePanel(to: panelHeight)
    }
}
