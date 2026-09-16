import AppKit
import SwiftUI

@MainActor
final class AppAccessWindow {
    static let shared = AppAccessWindow()
    private var window: NSWindow?
    private var zoomObserver: NSObjectProtocol?

    private init() {
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

    func present() {
        if let window {
            applyZoomScale(to: window)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text("Choose app access")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                Text("Choose Lifetime or a monthly subscription to create new content. Existing projects remain available.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                AccountPane()
            }
            .padding(AppTheme.Spacing.xl)
            .frame(width: AppTheme.Auth.contentWidth)
        }
        .frame(height: AppTheme.Auth.purchaseWindowHeight)
        .appZoomEnvironment())
        let window = NSWindow(contentViewController: controller)
        applyZoomScale(to: window)
        window.title = "App access"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func applyZoomScale() {
        guard let window else { return }
        applyZoomScale(to: window)
    }

    private func applyZoomScale(to window: NSWindow) {
        // Auth metrics already include app zoom.
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setContentSize(NSSize(
            width: AppTheme.Auth.contentWidth,
            height: AppTheme.Auth.purchaseWindowHeight
        ))
        window.setFrameOrigin(NSPoint(
            x: center.x - window.frame.width / 2,
            y: center.y - window.frame.height / 2
        ))
    }
}
