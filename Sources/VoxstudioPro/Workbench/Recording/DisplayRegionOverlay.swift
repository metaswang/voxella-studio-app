import SwiftUI
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DisplayRegionOverlayController: NSObject {
    static let shared = DisplayRegionOverlayController()

    private var windows: [NSWindow] = []
    private var setupPanel: NSPanel?
    private var setup: RecordingRegionSetupState?
    private weak var activeView: RegionSelectionView?
    private var continuation: CheckedContinuation<RecordingRegionSetupResult, Error>?

    func selectRegion(configuration: RecordingCaptureConfiguration, devices: [RecordingAudioDevice]) async throws -> RecordingRegionSetupResult {
        cancelSelection()
        setup = RecordingRegionSetupState(configuration: configuration, devices: devices)
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
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen = screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? screens[0]
        let minimumSize = AppTheme.Workbench.recordingRegionMinSize
        let handleSize = AppTheme.Workbench.recordingRegionHandleSize
        let drawHint = L10n.string("Drag to draw a recording area. Esc to cancel.")
        let editHint = L10n.string(
            "Drag to move · Handles to resize · Return to record · Esc to cancel"
        )
        let startTitle = L10n.string("Start recording")
        var currentWindow: NSWindow?
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
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let initialRect: CGRect?
            if screen.displayID == currentScreen.displayID {
                let saved = RecordingRegionStore.rect(for: RecordingRegionStore.screenKey(for: screen))
                initialRect = saved.flatMap {
                    RecordingRegionGeometry.placed($0, in: bounds, minimum: minimumSize)
                } ?? RecordingRegionGeometry.defaultRect(in: bounds, minimum: minimumSize)
            } else {
                initialRect = nil
            }
            let view = RegionSelectionView(
                screen: screen,
                initialRect: initialRect,
                minimumSize: minimumSize,
                handleSize: handleSize,
                drawHint: drawHint,
                editHint: editHint,
                startTitle: startTitle,
                onBegin: { [weak self] active in
                    self?.activeView = active
                    self?.clearSelections(except: active)
                },
                onChange: { [weak self] active, rect in
                    guard self?.activeView === active else { return }
                    self?.setup?.rect = rect
                    self?.positionSetupPanel(screen: screen, rect: rect)
                },
                onComplete: { [weak self] result in self?.handle(result) }
            )
            window.contentView = view
            window.orderFrontRegardless()
            if screen.displayID == currentScreen.displayID {
                currentWindow = window
                activeView = view
                setup?.rect = initialRect ?? .null
            }
            return window
        }
        presentSetupPanel(screen: currentScreen)
        currentWindow?.orderFrontRegardless()
        currentWindow?.makeKey()
        setupPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ result: Result<RecordingRegionSelection, Error>) {
        let configuration = setup?.configuration ?? RecordingCaptureConfiguration()
        closeOverlays()
        resume(result.map { RecordingRegionSetupResult(selection: $0, configuration: configuration) })
    }

    private func presentSetupPanel(screen: NSScreen) {
        guard let setup else { return }
        setup.resize = { [weak self] size in self?.activeView?.resizeSelection(to: size) }
        setup.redraw = { [weak self] in self?.activeView?.redrawSelection() }
        setup.start = { [weak self] in self?.activeView?.startRecording() }
        setup.cancel = { [weak self] in self?.cancelSelection() }
        let width = min(680 * AppZoomScale.shared.scale, screen.visibleFrame.width - 24)
        let panel = RegionSetupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = L10n.string("Recording area")
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingRegionSetupView(state: setup)
            .frame(width: width).fixedSize(horizontal: false, vertical: true).appLocalization().appZoomEnvironment())
        setupPanel = panel
        positionSetupPanel(screen: screen, rect: setup.rect)
        panel.orderFrontRegardless()
    }

    private func positionSetupPanel(screen: NSScreen, rect: CGRect) {
        guard let panel = setupPanel else { return }
        let visible = screen.visibleFrame
        let width = min(680 * AppZoomScale.shared.scale, visible.width - 24)
        if abs(panel.frame.width - width) > 1, let setup {
            panel.contentView = NSHostingView(rootView: RecordingRegionSetupView(state: setup)
                .frame(width: width).fixedSize(horizontal: false, vertical: true).appLocalization().appZoomEnvironment())
        }
        if let content = panel.contentView {
            panel.setContentSize(NSSize(width: width, height: max(100, content.fittingSize.height)))
        }
        let selected = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let below = selected.minY - panel.frame.height - 12
        let above = selected.maxY + 12
        let y: CGFloat
        if !rect.isNull, below >= visible.minY { y = below }
        else if !rect.isNull, above + panel.frame.height <= visible.maxY { y = above }
        else { y = visible.minY + 12 }
        let centerX = rect.isNull ? visible.midX : selected.midX
        let x = min(max(visible.minX + 12, centerX - panel.frame.width / 2), visible.maxX - panel.frame.width - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closeOverlays() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        setupPanel?.orderOut(nil)
        setupPanel?.contentView = nil
        setupPanel?.close()
        setupPanel = nil
        setup = nil
        activeView = nil
    }

    @objc private func environmentChanged() {
        cancelSelection()
    }

    private func clearSelections(except active: RegionSelectionView?) {
        for window in windows {
            guard let view = window.contentView as? RegionSelectionView, view !== active else { continue }
            view.clearSelection()
        }
    }

    private func resume(_ result: Result<RecordingRegionSetupResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private final class RegionSetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? RegionSelectionView)?.cancelFromKeyboard()
    }
}

private final class RegionSelectionView: NSView {
    private enum Interaction {
        case move(startPoint: CGPoint, startRect: CGRect)
        case resize(handle: RecordingRegionHandle, startRect: CGRect)
        case redraw(startPoint: CGPoint, previousRect: CGRect)
    }

    private let screen: NSScreen
    private let minimumSize: CGFloat
    private let handleSize: CGFloat
    private let drawHint: String
    private let editHint: String
    private let onChange: (RegionSelectionView, CGRect) -> Void
    private let onBegin: (RegionSelectionView) -> Void
    private let onComplete: (Result<RecordingRegionSelection, Error>) -> Void
    private var interaction: Interaction?
    private var claimedSelection = false
    private var currentRect: CGRect = .null
    private var didComplete = false
    private var tracking: NSTrackingArea?
    private lazy var startButton = NSButton(title: "", target: self, action: #selector(startRecording))

    init(
        screen: NSScreen,
        initialRect: CGRect?,
        minimumSize: CGFloat,
        handleSize: CGFloat,
        drawHint: String,
        editHint: String,
        startTitle: String,
        onBegin: @escaping (RegionSelectionView) -> Void,
        onChange: @escaping (RegionSelectionView, CGRect) -> Void,
        onComplete: @escaping (Result<RecordingRegionSelection, Error>) -> Void
    ) {
        self.screen = screen
        self.minimumSize = minimumSize
        self.handleSize = handleSize
        self.drawHint = drawHint
        self.editHint = editHint
        self.onChange = onChange
        self.onBegin = onBegin
        self.onComplete = onComplete
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        startButton.bezelStyle = .rounded
        startButton.title = startTitle
        startButton.keyEquivalent = "\r"
        startButton.translatesAutoresizingMaskIntoConstraints = false
        // The start action lives in the excluded setup panel. Keep its validity
        // state here for keyboard handling without placing it over the content.
        startButton.isEnabled = false
        startButton.setAccessibilityElement(false)
        startButton.isHidden = true
        addSubview(startButton)
        startButton.alphaValue = 0
        NSLayoutConstraint.activate([
            startButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            startButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AppTheme.Spacing.xxl)
        ])
        if let initialRect {
            currentRect = initialRect
        }
        startButton.isHidden = !isValid(currentRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        window?.makeKey()
        window?.makeFirstResponder(self)
        if let handle = RecordingRegionGeometry.handle(
            at: location, in: currentRect, diameter: handleSize, hitOutset: RecordingRegionGeometry.handleHitOutset
        ) {
            claimSelection()
            interaction = .resize(handle: handle, startRect: currentRect)
        } else if isValid(currentRect), currentRect.contains(location) {
            claimSelection()
            interaction = .move(startPoint: location, startRect: currentRect)
        } else {
            interaction = .redraw(startPoint: location, previousRect: currentRect)
        }
        updateCursor(at: location)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .move(let startPoint, let startRect):
            currentRect = RecordingRegionGeometry.moved(startRect, from: startPoint, to: current, in: bounds)
        case .resize(let handle, let startRect):
            currentRect = RecordingRegionGeometry.resized(
                startRect, handle: handle, to: current, minimum: minimumSize, in: bounds
            )
        case .redraw(let startPoint, _):
            currentRect = RecordingRegionGeometry.dragRect(from: startPoint, to: current, bounds: bounds)
            startButton.isHidden = true
        case nil:
            return
        }
        updateCursor(at: current)
        onChange(self, currentRect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard interaction != nil else { return }
        mouseDragged(with: event)
        if case .redraw(_, let previous) = interaction {
            if isValid(currentRect) {
                claimSelection()
            } else {
                currentRect = previous
            }
        }
        interaction = nil
        startButton.isHidden = !isValid(currentRect)
        updateCursor(at: convert(event.locationInWindow, from: nil))
        onChange(self, currentRect)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            complete(.failure(RecordingError.cancelled))
            return
        }
        if event.keyCode == 36 || event.keyCode == 76, !startButton.isHidden {
            startRecording()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        complete(.failure(RecordingError.cancelled))
    }

    func cancelFromKeyboard() {
        complete(.failure(RecordingError.cancelled))
    }

    func clearSelection() {
        interaction = nil
        claimedSelection = false
        currentRect = .null
        startButton.isHidden = true
        needsDisplay = true
    }

    private func claimSelection() {
        guard !claimedSelection else { return }
        claimedSelection = true
        onBegin(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let showsRect = !currentRect.isNull && !currentRect.isEmpty
        if showsRect {
            dim.append(NSBezierPath(rect: currentRect))
            dim.windingRule = .evenOdd
        }
        AppTheme.MediaOverlay.background.withAlphaComponent(0.38).setFill()
        dim.fill()

        let hint = isValid(currentRect) ? editHint : drawHint
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        let text = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.lg, weight: .medium),
            .foregroundColor: AppTheme.MediaOverlay.primary,
            .shadow: shadow
        ])
        let textSize = text.size()
        text.draw(at: CGPoint(
            x: max(AppTheme.Spacing.md, (bounds.width - textSize.width) / 2),
            y: bounds.height - AppTheme.Spacing.xxl - textSize.height
        ))

        guard showsRect, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(RecordingRegionGeometry.selectionLineWidth)
        context.setLineDash(phase: 0, lengths: RecordingRegionGeometry.dashLengths)
        context.stroke(currentRect)
        context.restoreGState()

        NSColor.white.setFill()
        for handle in RecordingRegionHandle.allCases {
            let center = RecordingRegionGeometry.center(for: handle, in: currentRect)
            NSBezierPath(ovalIn: CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )).fill()
        }
    }

    private func selection(from rect: CGRect) -> RecordingRegionSelection {
        RecordingRegionSelection(
            displayID: screen.displayID,
            sourceRect: RecordingRegionGeometry.sourceRect(from: rect, bounds: bounds)
        )
    }

    func resizeSelection(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, !currentRect.isNull else { return }
        let proposed = CGRect(origin: currentRect.origin, size: CGSize(
            width: min(bounds.width, max(minimumSize, size.width)),
            height: min(bounds.height, max(minimumSize, size.height))))
        guard let placed = RecordingRegionGeometry.placed(proposed, in: bounds, minimum: minimumSize) else { return }
        claimSelection()
        currentRect = placed
        startButton.isHidden = false
        onChange(self, currentRect)
        needsDisplay = true
    }

    func redrawSelection() {
        clearSelection()
        onChange(self, currentRect)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    @objc func startRecording() {
        guard !startButton.isHidden, interaction == nil, isValid(currentRect) else { return }
        guard NSScreen.screens.contains(where: { $0.displayID == screen.displayID && $0.frame == screen.frame }) else {
            complete(.failure(RecordingError.noDisplay))
            return
        }
        RecordingRegionStore.save(currentRect, for: RecordingRegionStore.screenKey(for: screen))
        complete(.success(selection(from: currentRect)))
    }

    private func complete(_ result: Result<RecordingRegionSelection, Error>) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(result)
    }

    private func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.width >= minimumSize && rect.height >= minimumSize
    }

    private func updateCursor(at point: CGPoint) {
        let cursor: NSCursor
        switch interaction {
        case .move:
            cursor = .closedHand
        case .resize(let handle, _):
            cursor = handle.cursor
        case .redraw:
            cursor = .crosshair
        case nil:
            if let handle = RecordingRegionGeometry.handle(
                at: point, in: currentRect, diameter: handleSize, hitOutset: RecordingRegionGeometry.handleHitOutset
            ) {
                cursor = handle.cursor
            } else if isValid(currentRect), currentRect.contains(point) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        }
        cursor.set()
    }
}

enum RecordingRegionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Corners are tested before edges so a grab near a corner resizes both axes.
    static let hitOrder: [RecordingRegionHandle] = [
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .top, .right, .bottom, .left
    ]

    var adjustsMinX: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var adjustsMaxX: Bool { self == .right || self == .topRight || self == .bottomRight }
    var adjustsMinY: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var adjustsMaxY: Bool { self == .top || self == .topLeft || self == .topRight }

    var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .crosshair
        }
    }
}

enum RecordingRegionGeometry {
    static let defaultSize = CGSize(width: 600, height: 450)
    static let handleHitOutset: CGFloat = 6
    static let selectionLineWidth: CGFloat = 2
    static let dashLengths: [CGFloat] = [6, 4]

    static func dragRect(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(bounds)
    }

    static func sourceRect(from rect: CGRect, bounds: CGRect) -> CGRect {
        CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func defaultRect(
        in bounds: CGRect,
        size: CGSize = defaultSize,
        minimum: CGFloat
    ) -> CGRect {
        let width = min(bounds.width, max(minimum, size.width))
        let height = min(bounds.height, max(minimum, size.height))
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Keeps a previously saved region on this display. Regions smaller than `minimum` are discarded.
    static func placed(_ rect: CGRect, in bounds: CGRect, minimum: CGFloat) -> CGRect? {
        guard bounds.width >= minimum, bounds.height >= minimum else { return nil }
        guard rect.width >= minimum, rect.height >= minimum else { return nil }
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        guard width >= minimum, height >= minimum else { return nil }
        return CGRect(
            x: min(max(bounds.minX, rect.minX), bounds.maxX - width),
            y: min(max(bounds.minY, rect.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    static func center(for handle: RecordingRegionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        diameter: CGFloat,
        hitOutset: CGFloat
    ) -> RecordingRegionHandle? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let hit = diameter + hitOutset * 2
        for handle in RecordingRegionHandle.hitOrder {
            let center = center(for: handle, in: rect)
            let hitRect = CGRect(x: center.x - hit / 2, y: center.y - hit / 2, width: hit, height: hit)
            if hitRect.contains(point) { return handle }
        }
        return nil
    }

    static func moved(_ rect: CGRect, from start: CGPoint, to current: CGPoint, in bounds: CGRect) -> CGRect {
        let proposed = CGPoint(x: rect.origin.x + current.x - start.x, y: rect.origin.y + current.y - start.y)
        return CGRect(
            x: min(max(bounds.minX, proposed.x), bounds.maxX - rect.width),
            y: min(max(bounds.minY, proposed.y), bounds.maxY - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    static func resized(
        _ rect: CGRect,
        handle: RecordingRegionHandle,
        to point: CGPoint,
        minimum: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var minX = handle.adjustsMinX ? clamped.x : rect.minX
        var maxX = handle.adjustsMaxX ? clamped.x : rect.maxX
        var minY = handle.adjustsMinY ? clamped.y : rect.minY
        var maxY = handle.adjustsMaxY ? clamped.y : rect.maxY
        fit(
            minEdge: &minX, maxEdge: &maxX,
            movesMin: handle.adjustsMinX, movesMax: handle.adjustsMaxX,
            lower: bounds.minX, upper: bounds.maxX, minimum: minimum
        )
        fit(
            minEdge: &minY, maxEdge: &maxY,
            movesMin: handle.adjustsMinY, movesMax: handle.adjustsMaxY,
            lower: bounds.minY, upper: bounds.maxY, minimum: minimum
        )
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func fit(
        minEdge: inout CGFloat,
        maxEdge: inout CGFloat,
        movesMin: Bool,
        movesMax: Bool,
        lower: CGFloat,
        upper: CGFloat,
        minimum: CGFloat
    ) {
        if maxEdge - minEdge < minimum {
            if movesMin {
                minEdge = maxEdge - minimum
            } else if movesMax {
                maxEdge = minEdge + minimum
            }
        }
        if minEdge < lower {
            minEdge = lower
            if maxEdge - minEdge < minimum {
                maxEdge = min(upper, minEdge + minimum)
            }
        }
        if maxEdge > upper {
            maxEdge = upper
            if maxEdge - minEdge < minimum {
                minEdge = max(lower, maxEdge - minimum)
            }
        }
    }
}

enum RecordingRegionStore {
    static let defaultsKey = "voxstudio.recording.savedRegion"

    static func screenKey(for screen: NSScreen) -> String {
        let name = screen.localizedName
        return name.isEmpty ? "display-\(screen.displayID)" : name
    }

    static func rect(for screenName: String, defaults: UserDefaults = .standard) -> CGRect? {
        guard let map = defaults.dictionary(forKey: defaultsKey),
              let entry = map[screenName] as? [String: Any],
              let x = (entry["x"] as? NSNumber)?.doubleValue,
              let y = (entry["y"] as? NSNumber)?.doubleValue,
              let width = (entry["width"] as? NSNumber)?.doubleValue,
              let height = (entry["height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func save(_ rect: CGRect, for screenName: String, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: defaultsKey) ?? [:]
        map[screenName] = [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height)
        ]
        defaults.set(map, forKey: defaultsKey)
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
