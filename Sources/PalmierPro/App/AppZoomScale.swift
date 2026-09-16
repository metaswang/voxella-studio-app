import AppKit
import Foundation
import Observation
import SwiftUI

/// Controls the application's UI zoom.
///
/// Posture 3 (metric scaling): layout frames and hit targets share the same
/// scaled metrics via `AppTheme` + `@Environment(\.appZoomScale)`. Do **not**
/// use `scaleEffect` for app chrome — it scales painting only and desyncs hits.
@Observable
final class AppZoomScale: @unchecked Sendable {
    static let shared = AppZoomScale()

    static let defaultsKey = "voxella.ui.zoomScale"
    static let defaultScale: CGFloat = 1.0
    static let minimumScale: CGFloat = 0.8
    static let maximumScale: CGFloat = 1.5
    static let step: CGFloat = 0.1

    private let defaults: UserDefaults
    private(set) var scale: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedScale = defaults.object(forKey: Self.defaultsKey) as? Double
        scale = Self.clamped(CGFloat(storedScale ?? Double(Self.defaultScale)))
    }

    var isAtMinimum: Bool { scale <= Self.minimumScale }
    var isAtMaximum: Bool { scale >= Self.maximumScale }
    var isDefault: Bool { scale == Self.defaultScale }

    func increase() {
        setScale(scale + Self.step)
    }

    func decrease() {
        setScale(scale - Self.step)
    }

    func reset() {
        setScale(Self.defaultScale)
    }

    func setScale(_ newScale: CGFloat) {
        let nextScale = Self.clamped((newScale * 10).rounded() / 10)
        guard nextScale != scale else { return }
        scale = nextScale
        defaults.set(Double(scale), forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .voxellaZoomScaleDidChange, object: self)
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }
}

extension Notification.Name {
    static let voxellaZoomScaleDidChange = Notification.Name("Voxella.zoomScaleDidChange")
}

private struct AppZoomScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = AppZoomScale.defaultScale
}

private struct AppZoomAlreadyAppliedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Active app UI zoom (0.8…1.5). Prefer reading metrics through `AppTheme`
    /// or this environment rather than applying `scaleEffect`.
    var appZoomScale: CGFloat {
        get { self[AppZoomScaleKey.self] }
        set { self[AppZoomScaleKey.self] = newValue }
    }

    fileprivate var appZoomAlreadyApplied: Bool {
        get { self[AppZoomAlreadyAppliedKey.self] }
        set { self[AppZoomAlreadyAppliedKey.self] = newValue }
    }
}

private struct AppZoomScaleEnvironmentModifier: ViewModifier {
    @Bindable private var zoom = AppZoomScale.shared
    @Environment(\.appZoomAlreadyApplied) private var appZoomAlreadyApplied
    let isPresentationBoundary: Bool

    func body(content: Content) -> some View {
        if appZoomAlreadyApplied && !isPresentationBoundary {
            content
        } else if isPresentationBoundary {
            content
                .environment(\.appZoomScale, zoom.scale)
                .environment(\.appZoomAlreadyApplied, true)
                // Recreate when scale changes so `AppTheme.*` computed metrics refresh.
                .id(zoom.scale)
                .modifier(AppZoomSheetContentSizeModifier(scale: zoom.scale))
        } else {
            content
                .environment(\.appZoomScale, zoom.scale)
                .environment(\.appZoomAlreadyApplied, true)
                .id(zoom.scale)
        }
    }
}

/// Sizes sheet / detached presentation windows from **real layout** size.
/// Metrics are already zoom-scaled via `AppTheme`, so measured size == hit box.
private struct AppZoomSheetContentSizeModifier: ViewModifier {
    let scale: CGFloat
    @State private var measuredSize: CGSize = .zero

    func body(content: Content) -> some View {
        let hasMeasured = measuredSize.width > 1 && measuredSize.height > 1
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: AppZoomMeasuredSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(AppZoomMeasuredSizeKey.self) { size in
                guard size.width > 1, size.height > 1, size != measuredSize else { return }
                measuredSize = size
            }
            .background {
                if hasMeasured {
                    AppZoomSheetWindowSizer(contentSize: measuredSize)
                }
            }
    }
}

private struct AppZoomMeasuredSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 1, next.height > 1 {
            value = next
        }
    }
}

private struct AppZoomSheetWindowSizer: NSViewRepresentable {
    var contentSize: CGSize

    func makeNSView(context: Context) -> AppZoomSheetFitView {
        AppZoomSheetFitView()
    }

    func updateNSView(_ nsView: AppZoomSheetFitView, context: Context) {
        nsView.targetSize = NSSize(width: contentSize.width, height: contentSize.height)
        nsView.applyIfNeeded()
    }
}

private final class AppZoomSheetFitView: NSView {
    var targetSize: NSSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.applyIfNeeded()
        }
    }

    func applyIfNeeded() {
        guard let window, targetSize.width > 1, targetSize.height > 1 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - targetSize.width) > 0.5
            || abs(current.height - targetSize.height) > 0.5 else { return }
        window.setContentSize(targetSize)
    }
}

extension NSWindow {
    /// Applies a new content size without making a zoom change move the window.
    @MainActor
    func setContentSizePreservingCenter(_ size: NSSize) {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: center.x - frame.width / 2,
            y: center.y - frame.height / 2
        ))
    }
}

extension View {
    /// Applies metric app zoom to a top-level SwiftUI surface (no `scaleEffect`).
    func appZoomEnvironment(presentationBoundary: Bool = false) -> some View {
        modifier(AppZoomScaleEnvironmentModifier(isPresentationBoundary: presentationBoundary))
    }
}
