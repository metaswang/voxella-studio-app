import AppKit
import SwiftUI

@MainActor
final class AppAccessWindow {
    static let shared = AppAccessWindow()
    private var window: NSWindow?

    func present() {
        if let window {
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
        }.frame(height: AppTheme.Auth.purchaseWindowHeight))
        let window = NSWindow(contentViewController: controller)
        window.title = "App access"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
