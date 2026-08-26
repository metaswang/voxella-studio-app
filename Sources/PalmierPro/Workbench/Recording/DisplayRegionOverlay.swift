import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class DisplayRegionOverlayController {
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
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .popUpMenu
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let view = RegionSelectionView(screen: screen) { [weak self] result in
                self?.handle(result)
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ result: Result<RecordingRegionSelection, Error>) {
        closeOverlays()
        resume(result)
    }

    private func closeOverlays() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    private func resume(_ result: Result<RecordingRegionSelection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private final class RegionSelectionView: NSView {
    private let screen: NSScreen
    private let onComplete: (Result<RecordingRegionSelection, Error>) -> Void
    private var dragStart: CGPoint?
    private var currentRect: CGRect = .null
    private var didComplete = false

    init(screen: NSScreen, onComplete: @escaping (Result<RecordingRegionSelection, Error>) -> Void) {
        self.screen = screen
        self.onComplete = onComplete
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        currentRect = .null
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(dragStart.x, current.x),
            y: min(dragStart.y, current.y),
            width: abs(current.x - dragStart.x),
            height: abs(current.y - dragStart.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard currentRect.width >= AppTheme.Workbench.recordingRegionMinSize,
              currentRect.height >= AppTheme.Workbench.recordingRegionMinSize else {
            currentRect = .null
            needsDisplay = true
            return
        }
        complete(.success(selection(from: currentRect)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            complete(.failure(RecordingError.cancelled))
            return
        }
        if event.keyCode == 36 || event.keyCode == 76,
           currentRect.width >= AppTheme.Workbench.recordingRegionMinSize {
            complete(.success(selection(from: currentRect)))
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if !currentRect.isNull, !currentRect.isEmpty {
            dim.append(NSBezierPath(rect: currentRect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(AppTheme.Opacity.medium).setFill()
        dim.fill()
        guard !currentRect.isNull, !currentRect.isEmpty else { return }
        AppTheme.Status.info.setStroke()
        let border = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = AppTheme.BorderWidth.thick
        border.stroke()
    }

    private func selection(from rect: CGRect) -> RecordingRegionSelection {
        let windowRect = convert(rect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? rect
        let sourceRect = CGRect(
            x: screenRect.minX - screen.frame.minX,
            y: screen.frame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
        return RecordingRegionSelection(
            displayID: screen.displayID,
            sourceRect: sourceRect
        )
    }

    private func complete(_ result: Result<RecordingRegionSelection, Error>) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(result)
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
