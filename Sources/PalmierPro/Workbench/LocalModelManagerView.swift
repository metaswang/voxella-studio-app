import AppKit
import SwiftUI

struct LocalModelManagerView: View {
    enum Presentation {
        case window
        case settings
    }

    var presentation: Presentation = .window

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                HStack {
                    Text(L10n.string("Local Features"))
                        .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.regular))
                    Spacer()
                    if presentation == .window {
                        Button(L10n.string("Done")) { LocalModelManagerWindowController.shared.close() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                Text(L10n.string("Prepare the features you want to use on this Mac. Approved downloads resume when you reopen the app."))
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                ForEach(LocalPreparationFeature.allCases) { feature in
                    LocalFeaturePreparationRow(feature: feature, allowsRemoval: true)
                }
                SpeakerIdentificationPreparationRow()
                Button(L10n.string("Replay introduction")) {
                    LocalModelManagerWindowController.shared.close()
                    SettingsWindowController.shared.close()
                    AppState.shared.showHome()
                    OnboardingState.shared.replay()
                    HomeWindowController.shared.showWindow(nil)
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.Background.baseColor)
    }
}

@MainActor
final class LocalModelManagerWindowController: NSWindowController {
    static let shared = LocalModelManagerWindowController()

    private init() {
        let content = LocalModelManagerView().appLocalization().tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(AppTheme.Onboarding.resourceWindow)
        window.minSize = AppTheme.Window.settingsMin
        window.title = L10n.string("Local Features")
        window.backgroundColor = AppTheme.Background.base
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
