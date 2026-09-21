import AppKit
import SwiftUI

enum AppTheme {
    /// Live UI zoom factor for metric (layout == hit-target) scaling.
    /// Posture 3: prefer this over `scaleEffect` so frames match painting.
    static var appZoomScaleFactor: CGFloat { AppZoomScale.shared.scale }

    /// Converts a design-space measurement into the active app layout space.
    /// Every value returned here is used by SwiftUI layout and therefore also
    /// participates in the same hit-testing geometry.
    static func zoomed(_ value: CGFloat) -> CGFloat {
        value * appZoomScaleFactor
    }

    static func zoomed(_ size: CGSize) -> CGSize {
        CGSize(width: zoomed(size.width), height: zoomed(size.height))
    }

    static func zoomed(_ values: [CGFloat]) -> [CGFloat] {
        values.map(zoomed)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Backgrounds

    enum Background {
        static let base = AppTheme.adaptive(
            light: NSColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1),
            dark: NSColor(red: 10/255, green: 10/255, blue: 10/255, alpha: 1)
        )
        static let surface = AppTheme.adaptive(
            light: NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1),
            dark: NSColor(red: 22/255, green: 22/255, blue: 22/255, alpha: 1)
        )
        static let raised = AppTheme.adaptive(
            light: NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1),
            dark: NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        )
        static let prominent = AppTheme.adaptive(
            light: NSColor(red: 0.975, green: 0.975, blue: 0.975, alpha: 1),
            dark: NSColor(red: 44/255, green: 44/255, blue: 44/255, alpha: 1)
        )

        /// Alias — empty media slot is a raised plate.
        static let placeholder = raised

        static var baseColor: Color { Color(base) }
        static var surfaceColor: Color { Color(surface) }
        static var raisedColor: Color { Color(raised) }
        static var prominentColor: Color { Color(prominent) }
        static var previewCanvasColor: Color { .black }
        static var placeholderColor: Color { Color(placeholder) }
        static var clearColor: Color { .clear }
    }

    // MARK: - Borders

    enum Border {
        static let primary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.24),
            dark: NSColor.white.withAlphaComponent(0.16)
        )
        static let subtle = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.18),
            dark: NSColor.white.withAlphaComponent(0.12)
        )
        static let divider = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.44),
            dark: NSColor.white.withAlphaComponent(0.44)
        )
        static let timelineClip = AppTheme.adaptive(light: .white, dark: .black)
        static let timelineClipSelected = AppTheme.adaptive(light: .black, dark: .white)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
        static var dividerColor: Color { Color(divider) }
    }

    // MARK: - Border widths

    enum BorderWidth {
        static var hairline: CGFloat { AppTheme.zoomed(0.5) }
        static var thin: CGFloat { AppTheme.zoomed(1) }
        static var medium: CGFloat { AppTheme.zoomed(1.5) }
        static var thick: CGFloat { AppTheme.zoomed(2) }
    }

    // MARK: - Accent

    enum Accent {
        static let timecodeNSColor = AppTheme.adaptive(
            light: NSColor(red: 0.58, green: 0.29, blue: 0.02, alpha: 1),
            dark: NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)
        )
        static let timecodeColor = Color(timecodeNSColor)

        static let primaryNSColor = AppTheme.adaptive(
            light: NSColor(red: 0.18, green: 0.16, blue: 0.13, alpha: 1),
            dark: NSColor(red: 0.961, green: 0.937, blue: 0.894, alpha: 1)
        )
        static let primary = Color(primaryNSColor)

        static let link = Color(nsColor: .linkColor)
        static let meetingBotBadge = Color(red: 0.75, green: 0.86, blue: 1.0)

        /// Vibrant highlight used by the onboarding tour spotlight.
        static let spotlight = Color(red: 1.0, green: 0.27, blue: 0.27)
        static let spotlightGradient = LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.34, blue: 0.30),
                Color(red: 0.95, green: 0.15, blue: 0.28),
                Color(red: 1.0, green: 0.48, blue: 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Adjust sliders

    enum Slider {
        static var trackHeight: CGFloat { AppTheme.zoomed(4) }
        static var thumbSize: CGFloat { AppTheme.zoomed(10) }
        static var labelColumn: CGFloat { AppTheme.zoomed(106) }
        /// Temperature track: cool blue (low) → warm amber (high).
        static let tempGradient = [Color(red: 0.32, green: 0.55, blue: 0.92), Color(red: 0.95, green: 0.72, blue: 0.32)]
        /// Tint track: green (low) → magenta (high).
        static let tintGradient = [Color(red: 0.42, green: 0.78, blue: 0.45), Color(red: 0.82, green: 0.38, blue: 0.72)]
        /// Master luma track: near-black → near-white.
        static let lumaGradient = [Color(white: 0.05), Color(white: 0.95)]
    }


    // MARK: - Color wheels

    enum Wheels {
        static var padSize: CGFloat { AppTheme.zoomed(96) }
        static var puckSize: CGFloat { AppTheme.zoomed(10) }
        static var ringWidth: CGFloat { AppTheme.zoomed(1) }
        static let crosshairColor = Color.white.opacity(AppTheme.Opacity.faint)
    }

    enum Curve {
        static var editorHeight: CGFloat { AppTheme.zoomed(180) }
        static var pointDiameter: CGFloat { AppTheme.zoomed(9) }
        /// Invisible grab target around each point — much larger than the dot so it's easy to hit.
        static var pointHitDiameter: CGFloat { AppTheme.zoomed(30) }
        static var lumaColor: Color { AppTheme.Text.primaryColor }
        static let redColor = Color(red: 1, green: 0.22, blue: 0.18)
        static let greenColor = Color(red: 0.32, green: 0.82, blue: 0.36)
        static let blueColor = Color(red: 0.32, green: 0.56, blue: 1)
    }

    static var aiGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Text.primaryColor, location: 0.00),
                .init(color: Text.secondaryColor, location: 0.45),
                .init(color: Text.tertiaryColor, location: 0.55),
                .init(color: Text.primaryColor, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Authentication

    enum Auth {
        static var purchaseWindowWidth: CGFloat { AppTheme.zoomed(520) }
        static var purchaseWindowHeight: CGFloat { AppTheme.zoomed(640) }
        static var contentWidth: CGFloat { AppTheme.zoomed(380) }
        static var providerButtonHeight: CGFloat { AppTheme.zoomed(44) }
        static var fieldHeight: CGFloat { AppTheme.zoomed(42) }
        static let pressedScale: CGFloat = 0.98
        static let fieldBackground = Background.raisedColor
        static let fieldBorder = Border.primaryColor
        static let appleBackground = Color.black
        static let appleForeground = Color.white
        static let googleBackground = Color.white
        static let googleForeground = Color.black.opacity(0.86)
        static let appleHoverFill = Color.white.opacity(Opacity.faint)
        static let googleHoverFill = Color.black.opacity(Opacity.faint)
        static let primaryBackground = Color(red: 0.31, green: 0.27, blue: 0.88)
        static let primaryForeground = Color.white
        static let primaryHoverFill = Color.white.opacity(Opacity.faint)
        static let focusBorder = primaryBackground
        static let googleMarkGradient = LinearGradient(
            colors: [
                Color(red: 0.26, green: 0.52, blue: 0.96),
                Color(red: 0.20, green: 0.67, blue: 0.34),
                Color(red: 0.98, green: 0.72, blue: 0.08),
                Color(red: 0.90, green: 0.24, blue: 0.20),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Status

    enum Status {
        static let error = AppTheme.adaptive(
            light: NSColor(red: 0.70, green: 0.14, blue: 0.09, alpha: 1),
            dark: NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)
        )

        static var errorColor: Color { Color(error) }

        static let success = AppTheme.adaptive(
            light: NSColor(red: 0.09, green: 0.45, blue: 0.28, alpha: 1),
            dark: NSColor(red: 0x4F/255.0, green: 0xB8/255.0, blue: 0x5F/255.0, alpha: 1)
        )

        static var successColor: Color { Color(success) }

        static let warning = NSColor.systemOrange

        static var warningColor: Color { Color(warning) }

        static let info = NSColor(red: 0x4F/255.0, green: 0x8F/255.0, blue: 0xE5/255.0, alpha: 1)

        static var infoColor: Color { Color(info) }
    }

    // MARK: - Text

    enum Text {
        static let primary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.94),
            dark: NSColor.white
        )
        static let secondary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.78),
            dark: NSColor.white.withAlphaComponent(0.80)
        )
        static let tertiary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.64),
            dark: NSColor.white.withAlphaComponent(0.62)
        )
        static let muted = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.44),
            dark: NSColor.white.withAlphaComponent(0.34)
        )

        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
    }

    // MARK: - Interaction fills

    enum Interaction {
        static let hoverScale: CGFloat = 1.1

        static func fill(_ opacity: Double) -> Color {
            AppTheme.Text.primaryColor.opacity(opacity)
        }
    }

    // MARK: - Media overlays

    enum MediaOverlay {
        static let background = NSColor.black
        static let primary = NSColor.white
        static let secondary = NSColor.white.withAlphaComponent(0.80)
        static let tertiary = NSColor.white.withAlphaComponent(0.62)
        static let muted = NSColor.white.withAlphaComponent(0.34)
        static let error = NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)

        static var backgroundColor: Color { Color(background) }
        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
        static var errorColor: Color { Color(error) }

        static let aiGradient = LinearGradient(
            stops: [
                .init(color: Color(white: 1.00), location: 0.00),
                .init(color: Color(white: 0.78), location: 0.45),
                .init(color: Color(white: 0.60), location: 0.55),
                .init(color: Color(white: 1.00), location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Opacity

    enum Opacity {
        static let zero: Double = 0
        static let opaque: Double = 1
        static let subtle: Double = 0.04
        static let hint: Double = 0.06
        static let faint: Double = 0.08
        static let soft: Double = 0.10
        static let muted: Double = 0.15
        static let moderate: Double = 0.25
        static let medium: Double = 0.35
        static let strong: Double = 0.55
        static let high: Double = 0.70
        static let prominent: Double = 0.80
    }


    // MARK: - Track type colors

    enum TrackColor {
        static var video: NSColor { TimelineClipColorPalette.shared.color(for: .video) }
        static var audio: NSColor { TimelineClipColorPalette.shared.color(for: .audio) }
        static var dub: NSColor { .systemGreen }
        static var image: NSColor { TimelineClipColorPalette.shared.color(for: .image) }
        static var text: NSColor { TimelineClipColorPalette.shared.color(for: .text) }
        static var lottie: NSColor { TimelineClipColorPalette.shared.color(for: .animation) }
        static var sequence: NSColor { TimelineClipColorPalette.shared.color(for: .sequence) }
        static let multicam = NSColor.systemRed

        static func readableForeground(on background: NSColor) -> NSColor {
            guard let background = background.usingColorSpace(.sRGB) else { return .white }
            let luminance = relativeLuminance(
                red: background.redComponent,
                green: background.greenComponent,
                blue: background.blueComponent
            )
            let blackContrast = (luminance + 0.05) / 0.05
            let whiteContrast = 1.05 / (luminance + 0.05)
            return blackContrast >= whiteContrast ? .black : .white
        }

        private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
        }
    }

    // MARK: - Corner radii

    enum Radius {
        static var xs: CGFloat { AppTheme.zoomed(3) }
        static var xsSm: CGFloat { AppTheme.zoomed(4) }
        static var sm: CGFloat { AppTheme.zoomed(6) }
        static var md: CGFloat { AppTheme.zoomed(10) }
        static var mdLg: CGFloat { AppTheme.zoomed(12) }
        static var lg: CGFloat { AppTheme.zoomed(14) }
        static var xl: CGFloat { AppTheme.zoomed(20) }

        static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, 0)
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static var zero: CGFloat { 0 }
        static var xxs: CGFloat { AppTheme.zoomed(2) }
        static var xs: CGFloat { AppTheme.zoomed(4) }
        static var sm: CGFloat { AppTheme.zoomed(6) }
        static var smMd: CGFloat { AppTheme.zoomed(8) }
        static var md: CGFloat { AppTheme.zoomed(10) }
        static var mdLg: CGFloat { AppTheme.zoomed(12) }
        static var lg: CGFloat { AppTheme.zoomed(14) }
        static var lgXl: CGFloat { AppTheme.zoomed(16) }
        static var xl: CGFloat { AppTheme.zoomed(20) }
        static var xlXxl: CGFloat { AppTheme.zoomed(24) }
        static var xxl: CGFloat { AppTheme.zoomed(28) }
    }

    // MARK: - Font sizes

    enum FontSize {
        static var micro: CGFloat { AppTheme.zoomed(8) }
        static var xxs: CGFloat { AppTheme.zoomed(9) }
        static var xs: CGFloat { AppTheme.zoomed(10) }
        static var sm: CGFloat { AppTheme.zoomed(11) }
        static var smMd: CGFloat { AppTheme.zoomed(12) }
        static var md: CGFloat { AppTheme.zoomed(13) }
        static var mdLg: CGFloat { AppTheme.zoomed(14) }
        static var lg: CGFloat { AppTheme.zoomed(15) }
        static var xl: CGFloat { AppTheme.zoomed(18) }
        static var title1: CGFloat { AppTheme.zoomed(22) }
        static var title2: CGFloat { AppTheme.zoomed(28) }
        static var display: CGFloat { AppTheme.zoomed(36) }
    }

    // MARK: - Font weights

    enum FontWeight {
        static let light: Font.Weight = .light
        static let regular: Font.Weight = .regular
        static let medium: Font.Weight = .medium
        static let semibold: Font.Weight = .semibold
        static let bold: Font.Weight = .bold
    }

    // MARK: - Tracking (letter-spacing)

    enum Tracking {
        static var tight: CGFloat { AppTheme.zoomed(-0.5) }
        static var normal: CGFloat { 0 }
        static var wide: CGFloat { AppTheme.zoomed(1.5) }
    }

    // MARK: - Icon sizes (square frame dimensions)

    enum IconSize {
        static var xxs: CGFloat { AppTheme.zoomed(12) }
        static var xs: CGFloat { AppTheme.zoomed(14) }
        static var sm: CGFloat { AppTheme.zoomed(18) }
        static var smMd: CGFloat { AppTheme.zoomed(20) }
        static var md: CGFloat { AppTheme.zoomed(22) }
        static var mdLg: CGFloat { AppTheme.zoomed(24) }
        static var lg: CGFloat { AppTheme.zoomed(26) }
        static var lgXl: CGFloat { AppTheme.zoomed(28) }
        static var xl: CGFloat { AppTheme.zoomed(30) }
    }

    enum ComponentSize {
        static var captionPreviewMaxHeight: CGFloat { AppTheme.zoomed(150) }
        static let captionPreviewMaxTextWidthRatio: CGFloat = 0.9
        static var toolImagePreviewMaxHeight: CGFloat { AppTheme.zoomed(50) }
        static var razorHintMaxTextWidth: CGFloat { AppTheme.zoomed(220) }
        static var razorHintMaxWidth: CGFloat { AppTheme.zoomed(560) }
        static var projectCardWidth: CGFloat { AppTheme.zoomed(150) }
        static var projectCardHeight: CGFloat { AppTheme.zoomed(120) }
        static var projectSearchWidth: CGFloat { AppTheme.zoomed(260) }
        static var timelineClipBorderMinWidth: CGFloat { AppTheme.zoomed(8) }
        static var timelineClipDetailMinWidth: CGFloat { AppTheme.zoomed(32) }
        static var timelineTabRenameWidth: CGFloat { AppTheme.zoomed(120) }
        static var timelineClipLabelMinWidth: CGFloat { AppTheme.zoomed(56) }
        static var timelineBadgePadH: CGFloat { AppTheme.zoomed(4) }
        static var timelineBadgePadV: CGFloat { AppTheme.zoomed(1) }
        static var timelineBadgeMinWidth: CGFloat { AppTheme.zoomed(16) }
        static var timelineDotSize: CGFloat { AppTheme.zoomed(5) }
        static var speakerEditorWidth: CGFloat { AppTheme.zoomed(320) }
    }

    enum VideoEditorHome {
        static var posterMinWidth: CGFloat { AppTheme.zoomed(248) }
        static let posterAspect: CGFloat = 16.0 / 9.0
        static let posterThumbnailMaxPixelSize: Int = 960
        static var listPosterWidth: CGFloat { AppTheme.zoomed(112) }
        static var listPosterHeight: CGFloat { listPosterWidth / posterAspect }
        static var listOpenedColumnWidth: CGFloat { AppTheme.zoomed(160) }
        static var listRowMinHeight: CGFloat { AppTheme.zoomed(76) }
        static var resumePosterWidth: CGFloat { AppTheme.zoomed(168) }
        static var searchWidth: CGFloat { AppTheme.zoomed(240) }
        static var layoutPickerWidth: CGFloat { AppTheme.zoomed(88) }
        static var newBadgeSize: CGFloat { AppTheme.zoomed(44) }
        static let hoverOpenOverlay: Double = Opacity.strong
        static var posterDash: [CGFloat] { [Spacing.md, Spacing.sm] }
    }

    enum SpeechInput {
        static var scriptMaxHeight: CGFloat { AppTheme.zoomed(144) }
        static var progressWidth: CGFloat { AppTheme.zoomed(120) }
        static var quickInputWidth: CGFloat { AppTheme.zoomed(560) }
        static var quickInputMinimumHeight: CGFloat { AppTheme.zoomed(180) }
        static let quickInputMaximumHeightRatio: CGFloat = 0.6
        static var quickInputEditorMinimumHeight: CGFloat { AppTheme.zoomed(72) }
        static var quickInputEditorLineHeight: CGFloat { AppTheme.zoomed(22) }
        static var quickInputEstimatedLineWidth: CGFloat { AppTheme.zoomed(44) }
        static var quickInputRecordingWaveformWidth: CGFloat { AppTheme.zoomed(220) }
        static var inlineRecordingWaveformWidth: CGFloat { AppTheme.zoomed(132) }
        static let quickInputPanelLevelOffset: Int = 1
    }

    enum Settings {
        static var sidebarWidth: CGFloat { AppTheme.zoomed(220) }
        static var contentMaxWidth: CGFloat { AppTheme.zoomed(640) }
        static var creditInputWidth: CGFloat { AppTheme.zoomed(56) }
        static var skillsSearchWidth: CGFloat { AppTheme.zoomed(260) }
        static var skillRowIconFrame: CGFloat { AppTheme.zoomed(42) }
        static var skillStatusWidth: CGFloat { AppTheme.zoomed(124) }
        static var skillActionWidth: CGFloat { AppTheme.zoomed(72) }
        static var skillDetailWidth: CGFloat { AppTheme.zoomed(720) }
        static var skillDetailMinHeight: CGFloat { AppTheme.zoomed(600) }
        static var skillToastWidth: CGFloat { AppTheme.zoomed(380) }
        static var skillMenuWidth: CGFloat { AppTheme.zoomed(168) }
        static let skillToastDuration: Duration = .seconds(5)
        static var fieldLabelWidth: CGFloat { AppTheme.zoomed(84) }
        static var providerListWidth: CGFloat { AppTheme.zoomed(152) }
        static var providerOrderListMinHeight: CGFloat { AppTheme.zoomed(72) }
        static var extraBodyEditorMinHeight: CGFloat { AppTheme.zoomed(128) }
    }

    enum EditorPanel {
        static var defaultWidth: CGFloat { AppTheme.zoomed(340) }
        static var minimumWidth: CGFloat { AppTheme.zoomed(300) }
        static var labelColumnWidth: CGFloat { AppTheme.zoomed(88) }
        static var rowMinHeight: CGFloat { AppTheme.zoomed(22) }
        static var groupHeaderHeight: CGFloat { AppTheme.zoomed(28) }
        static var fieldMinHeight: CGFloat { AppTheme.zoomed(22) }
        static var numericFieldWidth: CGFloat { AppTheme.zoomed(56) }
        static var compactNumericFieldWidth: CGFloat { AppTheme.zoomed(36) }
        static var fontMenuWidth: CGFloat { AppTheme.zoomed(160) }
        static var fontPickerWidth: CGFloat { AppTheme.zoomed(280) }
        static var fontPickerHeight: CGFloat { AppTheme.zoomed(360) }
        static var textEditorMinHeight: CGFloat { AppTheme.zoomed(96) }
    }

    enum Window {
        static var homeDefault: NSSize { AppTheme.zoomed(NSSize(width: 1200, height: 800)) }
        static var homeMin: NSSize { AppTheme.zoomed(NSSize(width: 760, height: 480)) }
        static var projectMin: NSSize {
            NSSize(
                width: AppTheme.zoomed(960) + GenerationPanel.minimumWidthAdjustment,
                height: AppTheme.zoomed(600)
            )
        }
        static var settingsDefault: NSSize { AppTheme.zoomed(NSSize(width: 1200, height: 800)) }
        static var settingsMin: NSSize { AppTheme.zoomed(NSSize(width: 860, height: 640)) }
    }

    enum Workbench {
        static var sidebarCollapsedWidth: CGFloat { AppTheme.zoomed(64) }
        static var sidebarExpandedWidth: CGFloat { AppTheme.zoomed(216) }
        static var sidebarRowHeight: CGFloat { AppTheme.zoomed(38) }
        /// Compact top chrome for the main canvas (titlebar strip, not stacked under it).
        static var toolbarHeight: CGFloat { AppTheme.zoomed(32) }
        /// Vertical clearance for traffic lights in the sidebar under fullSizeContentView.
        static var windowControlsInset: CGFloat { AppTheme.zoomed(28) }
        static var contentMaxWidth: CGFloat { AppTheme.zoomed(1180) }
        static var composerMaxWidth: CGFloat { AppTheme.zoomed(1040) }
        static var translationSheetWidth: CGFloat { AppTheme.zoomed(420) }
        static var dubSheetWidth: CGFloat { AppTheme.zoomed(520) }
        static var voiceRowMinHeight: CGFloat { AppTheme.zoomed(92) }
        static var sessionHeaderMinHeight: CGFloat { AppTheme.zoomed(92) }
        static var sessionTabBarMinHeight: CGFloat { AppTheme.zoomed(34) }
        static let sessionSplitDefaultRatio: CGFloat = 0.5
        static let sessionSplitMinimumRatio: CGFloat = 0.3
        static let sessionSplitMaximumRatio: CGFloat = 0.7
        static let sessionSummaryDefaultRatio: CGFloat = 0.5
        static var sessionSplitMinimumRightWidth: CGFloat { AppTheme.zoomed(400) }
        static var sessionSplitDividerHitWidth: CGFloat { AppTheme.zoomed(12) }
        static var sessionVideoMinHeight: CGFloat { AppTheme.zoomed(360) }
        static var netVideoCardWidth: CGFloat { AppTheme.zoomed(360) }
        static var netVideoCardHeight: CGFloat { AppTheme.zoomed(260) }
        static var netVideoCardCollapsedHeight: CGFloat { AppTheme.zoomed(48) }
        static var clipPreviewMaxHeight: CGFloat { AppTheme.zoomed(220) }
        static var clipTimelineHeight: CGFloat { AppTheme.zoomed(28) }
        static var clipHandleSize: CGFloat { AppTheme.zoomed(14) }
        static var clipHandleHitWidth: CGFloat { AppTheme.zoomed(16) }
        static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        static var transcriptCardMinHeight: CGFloat { AppTheme.zoomed(76) }
        static var filterWidth: CGFloat { AppTheme.zoomed(170) }
        static var pickerWidth: CGFloat { AppTheme.zoomed(190) }
        static var recordingDevicePickerWidth: CGFloat { AppTheme.zoomed(220) }
        static var recordingInfoPopoverWidth: CGFloat { AppTheme.zoomed(280) }
        static var recordingRegionMinSize: CGFloat { AppTheme.zoomed(48) }
        static var recordingRegionHandleSize: CGFloat { AppTheme.zoomed(8) }
        static var recordingControlsWidth: CGFloat { AppTheme.zoomed(360) }
        static var recordingControlsHeight: CGFloat { AppTheme.zoomed(52) }
        static var recordingControlsButtonSize: CGFloat { AppTheme.zoomed(32) }
        static var recordingControlsTimerWidth: CGFloat { AppTheme.zoomed(72) }
        static var recordingControlsWaveformWidth: CGFloat { AppTheme.zoomed(96) }
        static var recordingWaveformHeight: CGFloat { AppTheme.zoomed(22) }
        static var recordingWaveformBarWidth: CGFloat { AppTheme.zoomed(3) }
        static var recordingWaveformBarSpacing: CGFloat { AppTheme.zoomed(2) }
        static var recordingWaveformMinimumBarHeight: CGFloat { AppTheme.zoomed(2) }
        static let recordingWaveformRefreshInterval: Double = 1.0 / 30.0
        static let recordingWaveformFloorDb: Float = -48
        static let recordingWaveformCeilingDb: Float = -3
        static let cloudClipAnchor = "cloudClipLimit"
        static var compactPanelWidth: CGFloat { AppTheme.zoomed(420) }
        static var summaryRefinementSheetWidth: CGFloat { AppTheme.zoomed(520) }
        static var summaryRefinementEditorHeight: CGFloat { AppTheme.zoomed(140) }
        static var summaryTemplateSheetWidth: CGFloat { AppTheme.zoomed(920) }
        static var summaryTemplateSheetHeight: CGFloat { AppTheme.zoomed(640) }
        static var summaryTemplateSidebarWidth: CGFloat { AppTheme.zoomed(280) }
        static var summaryTemplateEditorMinHeight: CGFloat { AppTheme.zoomed(280) }
        static var exportSheetWidth: CGFloat { AppTheme.zoomed(920) }
        static var exportSheetHeight: CGFloat { AppTheme.zoomed(720) }
        static var exportSummaryWidth: CGFloat { AppTheme.zoomed(280) }
        static var exportChoiceMinHeight: CGFloat { AppTheme.zoomed(112) }
        static var searchWidth: CGFloat { AppTheme.zoomed(260) }
        static var searchPaletteWidth: CGFloat { AppTheme.zoomed(600) }
        static var searchPaletteHeight: CGFloat { AppTheme.zoomed(560) }
        static var searchPaletteFieldHeight: CGFloat { AppTheme.zoomed(46) }
        static var searchPaletteRowHeight: CGFloat { AppTheme.zoomed(42) }
        static let searchPaletteRecentLimit = 6
        static var revisionPickerWidth: CGFloat { AppTheme.zoomed(190) }
        static var sessionIconSize: CGFloat { AppTheme.zoomed(44) }
        static var sessionStatusWidth: CGFloat { AppTheme.zoomed(238) }
        static var sessionStatusHelpWidth: CGFloat { AppTheme.zoomed(320) }
        static var sessionStatusProgressHeight: CGFloat { AppTheme.zoomed(4) }
        static let sessionStatusPulseScale: CGFloat = 1.06
        static var recentSessionThumbnailWidth: CGFloat { AppTheme.zoomed(76) }
        static var recentSessionThumbnailHeight: CGFloat { AppTheme.zoomed(52) }
        static var fullscreenControlSize: CGFloat { AppTheme.zoomed(48) }
        static let fullscreenChromeIdle: Duration = .seconds(3)
        static let fullscreenSeekStepSeconds: Double = 5
        static let dubSeekStepSeconds: Double = 10
        static let tipAutoDismiss: Duration = .seconds(15)
        static let tipDedupeWindow: Duration = .seconds(10)
        static var tipHorizontalInset: CGFloat { AppTheme.zoomed(16) }
        static var tipVerticalInset: CGFloat { AppTheme.zoomed(12) }
        static var emptyStateMinHeight: CGFloat { AppTheme.zoomed(260) }
        static var summaryPanelMinHeight: CGFloat { AppTheme.zoomed(160) }
        static var waveformHeight: CGFloat { AppTheme.zoomed(54) }
        static var sessionAudioCanvasHeight: CGFloat {
            AppTheme.Spacing.lgXl
                + waveformHeight
                + AppTheme.Spacing.smMd
                + AppTheme.IconSize.xl
                + AppTheme.Spacing.md
                + AppTheme.Spacing.lgXl
        }
        static var waveformBarStep: CGFloat { AppTheme.zoomed(5) }
        static var waveformBarSpacing: CGFloat { AppTheme.zoomed(2) }
        static var waveformBarWidth: CGFloat { AppTheme.zoomed(3) }
        static var waveformMinimumBarHeight: CGFloat { AppTheme.zoomed(3) }
        static let waveformMinimumLoudness: CGFloat = 0.08
        static let playerRefreshInterval: Double = 0.2
        static let playerEndTolerance: Double = 0.05
        static let playerTimescale: Int32 = 600
        static var dubScriptMinHeight: CGFloat { AppTheme.zoomed(190) }
        static var recentSessionControlHeight: CGFloat { AppTheme.zoomed(44) }
        static var recentSessionUpdatedColumnWidth: CGFloat { AppTheme.zoomed(132) }
        static var recentSessionTagColumnWidth: CGFloat { AppTheme.zoomed(160) }
        static var recentSessionMenuWidth: CGFloat { AppTheme.zoomed(36) }
        static var recentSessionEmptyTextMaxWidth: CGFloat { AppTheme.zoomed(520) }
    }

    enum Knowledge {
        static let defaultPanelRatio: CGFloat = 0.32
        static var minimumSourceWidth: CGFloat { AppTheme.zoomed(248) }
        static var minimumChatWidth: CGFloat { AppTheme.zoomed(420) }
        static let minimumPanelRatio: CGFloat = 0.22
        static let maximumPanelRatio: CGFloat = 0.68
        static var messageMaxWidth: CGFloat { AppTheme.zoomed(720) }
        static var emptyStateMaxWidth: CGFloat { AppTheme.zoomed(560) }
        static var starterPromptMinHeight: CGFloat { AppTheme.zoomed(44) }
        static let transcriptAutoScrollCooldown: TimeInterval = 1.25
    }

    enum Caption {
        static let defaultFontSize: Double = 48
        static let minPosition: Double = 0
        static let maxPosition: Double = 1
        static let centerSnapValue: CGFloat = 0.5
        static let centerSnapThreshold: Double = 0.02
        static let defaultCenterY: CGFloat = 0.9
        static let defaultCenter = CGPoint(x: centerSnapValue, y: defaultCenterY)
        static let minDisplayDuration: Double = 0.7
    }

    enum GenerationPanel {
        static var typeTabWidth: CGFloat { IconSize.xl + Spacing.lg }
        static var minimumWidthAdjustment: CGFloat { typeTabWidth + Spacing.xxl }
        static var loadingHeight: CGFloat { AppTheme.zoomed(180) }
        static var promptMinHeight: CGFloat { AppTheme.zoomed(40) }
        static var referenceTileWidth: CGFloat { AppTheme.zoomed(80) }
        static var referenceTileHeight: CGFloat { AppTheme.zoomed(56) }
    }

    enum MediaPanel {
        static var tabRailWidth: CGFloat { IconSize.lg + Spacing.sm * 2 }
        static var contextRowHeight: CGFloat { IconSize.md }
    }

    enum Export {
        static var sheetWidth: CGFloat { AppTheme.zoomed(600) }
        static var sheetHeight: CGFloat { AppTheme.zoomed(600) }
        static var logPaneWidth: CGFloat { AppTheme.zoomed(420) }
        static var queueTimestampWidth: CGFloat { AppTheme.zoomed(56) }
        static var activityDotSize: CGFloat { AppTheme.zoomed(6) }
        static var queueProgressBarWidth: CGFloat { AppTheme.zoomed(96) }
        static var queueProgressWidth: CGFloat { AppTheme.zoomed(32) }
        static var sheetWidthWithLog: CGFloat { sheetWidth + logPaneWidth + BorderWidth.hairline }
    }

    enum Matte {
        static var sheetWidth: CGFloat { AppTheme.zoomed(280) }
        static var controlWidth: CGFloat { AppTheme.zoomed(116) }
    }

    // MARK: - Shadows

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        static var sm: ShadowStyle { ShadowStyle(color: .black.opacity(0.3), radius: AppTheme.zoomed(1), x: 0, y: AppTheme.zoomed(0.5)) }
        static var md: ShadowStyle { ShadowStyle(color: .black.opacity(0.3), radius: AppTheme.zoomed(4), x: 0, y: AppTheme.zoomed(2)) }
        static var lg: ShadowStyle { ShadowStyle(color: .black.opacity(0.25), radius: AppTheme.zoomed(24), x: 0, y: AppTheme.zoomed(8)) }
    }

    // MARK: - Animation durations

    enum Onboarding {
        static var windowSize: CGSize { AppTheme.zoomed(CGSize(width: 1000, height: 680)) }
        static var panelWidth: CGFloat { AppTheme.zoomed(920) }
        static var panelHeight: CGFloat { AppTheme.zoomed(570) }
        static var showcaseWidth: CGFloat { AppTheme.zoomed(430) }
        static var panelRadius: CGFloat { AppTheme.zoomed(28) }
        static var cardWidth: CGFloat { AppTheme.zoomed(204) }
        static var cardHeight: CGFloat { AppTheme.zoomed(166) }
        static var smallCardHeight: CGFloat { AppTheme.zoomed(134) }
        static var cardPitch: CGFloat { AppTheme.zoomed(196) }
        static var columnOffset: CGFloat { AppTheme.zoomed(94) }
        static let cardRestingScale: CGFloat = 0.94
        static let cardFocusedScale: CGFloat = 1.24
        static let cardTilt: Double = 3.5
        static var waveHeight: CGFloat { AppTheme.zoomed(40) }
        static var waveBarWidth: CGFloat { AppTheme.zoomed(4) }
        static var focalRadius: CGFloat { AppTheme.zoomed(140) }
        static let fadeEdge: CGFloat = 0.12
        static var laneInset: CGFloat { AppTheme.zoomed(10) }
        static var resourceWindow: CGSize { AppTheme.zoomed(CGSize(width: 820, height: 680)) }
        static let canvas = Color(AppTheme.adaptive(
            light: NSColor(red: 0.91, green: 0.92, blue: 0.98, alpha: 1),
            dark: NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1)
        ))
        static let paper = Color(AppTheme.adaptive(
            light: NSColor(red: 0.99, green: 0.99, blue: 1, alpha: 1),
            dark: NSColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1)
        ))
        static let ink = Color(AppTheme.adaptive(
            light: NSColor(red: 0.28, green: 0.25, blue: 0.64, alpha: 1),
            dark: NSColor(red: 0.72, green: 0.68, blue: 1, alpha: 1)
        ))
        static let mint = Color(AppTheme.adaptive(
            light: NSColor(red: 0.15, green: 0.48, blue: 0.40, alpha: 1),
            dark: NSColor(red: 0.42, green: 0.80, blue: 0.65, alpha: 1)
        ))
        static let coral = Color(AppTheme.adaptive(
            light: NSColor(red: 0.72, green: 0.30, blue: 0.26, alpha: 1),
            dark: NSColor(red: 0.98, green: 0.57, blue: 0.49, alpha: 1)
        ))
    }

    enum Anim {
        static let showcaseFrameInterval: Double = 1 / 30
        static let showcasePointsPerSecond: Double = 17
        static let hover: Double = 0.15
        static let transition: Double = 0.2
        static let pulse: Double = 0.8
        static let slipPreviewRefresh: Duration = .milliseconds(67)
    }
}

// MARK: - Shadow view modifier

extension View {
    func shadow(_ style: AppTheme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func panelHeaderBar() -> some View {
        frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .background(AppTheme.Background.raisedColor)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
    }
}

// MARK: - ClipType color mapping

extension ClipType {
    var themeColor: NSColor {
        switch self {
        case .video: AppTheme.TrackColor.video
        case .audio: AppTheme.TrackColor.audio
        case .dub: AppTheme.TrackColor.dub
        case .image: AppTheme.TrackColor.image
        case .text: AppTheme.TrackColor.text
        case .lottie: AppTheme.TrackColor.lottie
        case .sequence: AppTheme.TrackColor.sequence
        }
    }

    var themeForegroundColor: NSColor {
        AppTheme.TrackColor.readableForeground(on: themeColor)
    }
}
