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
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            applyZoomScale(to: window)
            window.orderFrontRegardless()
            window.makeKey()
            return
        }
        let controller = NSHostingController(rootView: VStack(spacing: 0) {
            WorkbenchTopTipBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    accessHeader
                    AccountPane()
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .frame(width: AppTheme.Auth.purchaseWindowWidth)
        .frame(minHeight: AppTheme.Auth.purchaseWindowHeight)
        .appZoomEnvironment()
        .appLocalization())
        let window = NSWindow(contentViewController: controller)
        applyZoomScale(to: window)
        window.title = L10n.string("App access")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.orderFrontRegardless()
        window.makeKey()
    }

    private var accessHeader: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Auth.primaryBackground)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: AppTheme.zoomed(44), height: AppTheme.zoomed(44))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("VoxStudio access")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Unlock new projects and keep your existing work safe.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyZoomScale() {
        guard let window else { return }
        applyZoomScale(to: window)
    }

    private func applyZoomScale(to window: NSWindow) {
        // Auth metrics already include app zoom.
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setContentSize(NSSize(
            width: AppTheme.Auth.purchaseWindowWidth,
            height: AppTheme.Auth.purchaseWindowHeight
        ))
        window.setFrameOrigin(NSPoint(
            x: center.x - window.frame.width / 2,
            y: center.y - window.frame.height / 2
        ))
    }
}
