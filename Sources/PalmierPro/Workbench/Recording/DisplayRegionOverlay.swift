import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class DisplayRegionOverlayController: NSObject {
    static let shared = DisplayRegionOverlayController()

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<RecordingRegionSelection, Error>?

    func selectRegion() async throws -> RecordingRegionSelection {
        cancelSelection()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            presentOverlays()
        }
    }

    func cancelSelection() {
        closeOverlays()
        resume(.failure(RecordingError.cancelled))
    }

    private func presentOverlays() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            resume(.failure(RecordingError.noDisplay))
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        windows = screens.map { screen in
            let window = RegionSelectionWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let view = RegionSelectionView(
                screen: screen,
                onBegin: { [weak self] in self?.clearSelections() },
                onComplete: { [weak self] result in self?.handle(result) }
            )
            window.contentView = view
            window.orderFrontRegardless()
            window.makeKey()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ result: Result<RecordingRegionSelection, Error>) {
        closeOverlays()
        resume(result)
    }

    private func closeOverlays() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    @objc private func environmentChanged() {
        cancelSelection()
    }

    private func clearSelections() {
        for window in windows {
            (window.contentView as? RegionSelectionView)?.clearSelection()
        }
    }

    private func resume(_ result: Result<RecordingRegionSelection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    private let screen: NSScreen
    private let onBegin: () -> Void
    private let onComplete: (Result<RecordingRegionSelection, Error>) -> Void
    private var dragStart: CGPoint?
    private var currentRect: CGRect = .null
    private var didComplete = false
    private lazy var startButton = NSButton(title: "Start Recording", target: self, action: #selector(startRecording))

    init(
        screen: NSScreen,
        onBegin: @escaping () -> Void,
        onComplete: @escaping (Result<RecordingRegionSelection, Error>) -> Void
    ) {
        self.screen = screen
        self.onBegin = onBegin
        self.onComplete = onComplete
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        startButton.bezelStyle = .rounded
        startButton.isHidden = true
        startButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(startButton)
        NSLayoutConstraint.activate([
            startButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            startButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AppTheme.Spacing.xxl)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        onBegin()
        window?.makeKey()
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        currentRect = .null
        startButton.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = RecordingRegionGeometry.dragRect(from: dragStart, to: current, bounds: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        mouseDragged(with: event)
        dragStart = nil
        guard currentRect.width >= AppTheme.Workbench.recordingRegionMinSize,
              currentRect.height >= AppTheme.Workbench.recordingRegionMinSize else {
            currentRect = .null
            needsDisplay = true
            return
        }
        startButton.isHidden = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            complete(.failure(RecordingError.cancelled))
            return
        }
        if event.keyCode == 36 || event.keyCode == 76,
           !startButton.isHidden {
            startRecording()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        complete(.failure(RecordingError.cancelled))
    }

    func clearSelection() {
        dragStart = nil
        currentRect = .null
        startButton.isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if !currentRect.isNull, !currentRect.isEmpty {
            dim.append(NSBezierPath(rect: currentRect))
            dim.windingRule = .evenOdd
        }
        AppTheme.MediaOverlay.background.withAlphaComponent(AppTheme.Opacity.medium).setFill()
        dim.fill()
        let message = startButton.isHidden
            ? "Drag to select a recording area. Esc to cancel."
            : "Click Start Recording or press Return. Drag again to reselect. Esc to cancel."
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.lg),
            .foregroundColor: AppTheme.MediaOverlay.primary
        ])
        text.draw(at: CGPoint(
            x: max(AppTheme.Spacing.md, (bounds.width - text.size().width) / 2),
            y: bounds.height - AppTheme.Spacing.xxl - text.size().height
        ))
        guard !currentRect.isNull, !currentRect.isEmpty else { return }
        AppTheme.Status.info.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = AppTheme.BorderWidth.thick
        border.stroke()
    }

    private func selection(from rect: CGRect) -> RecordingRegionSelection {
        return RecordingRegionSelection(
            displayID: screen.displayID,
            sourceRect: RecordingRegionGeometry.sourceRect(from: rect, bounds: bounds)
        )
    }

    @objc private func startRecording() {
        guard !startButton.isHidden, dragStart == nil else { return }
        guard NSScreen.screens.contains(where: { $0.displayID == screen.displayID && $0.frame == screen.frame }) else {
            complete(.failure(RecordingError.noDisplay))
            return
        }
        complete(.success(selection(from: currentRect)))
    }

    private func complete(_ result: Result<RecordingRegionSelection, Error>) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(result)
    }
}

enum RecordingRegionGeometry {
    static func dragRect(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(bounds)
    }

    static func sourceRect(from rect: CGRect, bounds: CGRect) -> CGRect {
        CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}
