import AppKit
import SwiftUI

/// Brand mark used in the workbench sidebar, loaded from the bundled app icon.
enum WorkbenchBrandIcon {
    @ViewBuilder
    static func image(size: CGFloat = 32) -> some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.white)
                    .overlay {
                        Image(systemName: "hexagon.fill")
                            .font(.system(size: size * 0.45, weight: .bold))
                            .foregroundStyle(.black)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }

    private static let nsImage: NSImage? = {
        if let url = BundledResource.url("AppIcon.png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }()
}

/// Custom workbench nav glyphs aligned with `voxella-web` `Sidebar.tsx`
/// (`transcriptionIcon` / `voiceoverIcon` / `MeetingIcon`) and Lucide session icons.
enum WorkbenchNavGlyph: Hashable {
    case transcription
    case meetBot
    case voiceover
    case captions
    case squarePlay
    case system(String)

    @ViewBuilder
    func view(size: CGFloat = 18) -> some View {
        switch self {
        case .transcription:
            TranscriptionNavIcon()
                .frame(width: size, height: size)
        case .meetBot:
            MeetingNavIcon()
                .frame(width: size, height: size)
        case .voiceover:
            VoiceoverNavIcon()
                .frame(width: size, height: size)
        case .captions:
            CaptionsNavIcon()
                .frame(width: size, height: size)
        case .squarePlay:
            SquarePlayNavIcon()
                .frame(width: size, height: size)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.85, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}

/// Calendar with a bot badge — ported from web `MeetingIcon.tsx` (512 viewBox).
private struct MeetingNavIcon: View {
    var body: some View {
        GeometryReader { geo in
            // Web SVG is 512×512; normalize to the view's shorter edge.
            let s = min(geo.size.width, geo.size.height) / 512
            Canvas { context, _ in
                let calendarStroke = StrokeStyle(lineWidth: 20 * s, lineCap: .round, lineJoin: .round)
                let calendar = CGRect(x: 56 * s, y: 72 * s, width: 320 * s, height: 320 * s)
                let header = CGRect(x: 56 * s, y: 72 * s, width: 320 * s, height: 88 * s)
                let corner = CGSize(width: 40 * s, height: 40 * s)

                context.fill(Path(roundedRect: calendar, cornerSize: corner), with: .color(AppTheme.Background.surfaceColor))
                context.fill(Path(roundedRect: header, cornerSize: corner), with: .color(AppTheme.Background.raisedColor))
                context.stroke(Path(roundedRect: calendar, cornerSize: corner), with: .foreground, style: calendarStroke)

                var binding = Path()
                binding.move(to: CGPoint(x: 136 * s, y: 48 * s))
                binding.addLine(to: CGPoint(x: 136 * s, y: 112 * s))
                binding.move(to: CGPoint(x: 296 * s, y: 48 * s))
                binding.addLine(to: CGPoint(x: 296 * s, y: 112 * s))
                context.stroke(binding, with: .foreground, style: StrokeStyle(lineWidth: 24 * s, lineCap: .round))

                var cells = Path()
                for (x, y) in [
                    (104.0, 196.0), (168.0, 196.0), (232.0, 196.0),
                    (104.0, 260.0), (168.0, 260.0), (232.0, 260.0),
                ] {
                    cells.addRoundedRect(
                        in: CGRect(x: x * s, y: y * s, width: 44 * s, height: 44 * s),
                        cornerSize: CGSize(width: 10 * s, height: 10 * s)
                    )
                }
                context.fill(cells, with: .foreground)

                // Lucide Bot badge: translate(160,152) scale(14.5) in the web SVG.
                let botScale = 14.5 * s
                let botOrigin = CGPoint(x: 160 * s, y: 152 * s)
                func botPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(x: botOrigin.x + x * botScale, y: botOrigin.y + y * botScale)
                }
                let botBody = CGRect(
                    x: botOrigin.x + 4 * botScale,
                    y: botOrigin.y + 8 * botScale,
                    width: 16 * botScale,
                    height: 12 * botScale
                )
                context.fill(
                    Path(roundedRect: botBody, cornerSize: CGSize(width: 2 * botScale, height: 2 * botScale)),
                    with: .color(AppTheme.Accent.meetingBotBadge)
                )
                context.stroke(
                    Path(roundedRect: botBody, cornerSize: CGSize(width: 2 * botScale, height: 2 * botScale)),
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 2 * botScale, lineCap: .round, lineJoin: .round)
                )

                var bot = Path()
                bot.move(to: botPoint(12, 8))
                bot.addLine(to: botPoint(12, 4))
                bot.addLine(to: botPoint(8, 4))
                bot.move(to: botPoint(2, 14))
                bot.addLine(to: botPoint(4, 14))
                bot.move(to: botPoint(20, 14))
                bot.addLine(to: botPoint(22, 14))
                bot.move(to: botPoint(15, 13))
                bot.addLine(to: botPoint(15, 15))
                bot.move(to: botPoint(9, 13))
                bot.addLine(to: botPoint(9, 15))
                context.stroke(
                    bot,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 2 * botScale, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Lucide `Captions` — rectangle with caption bars.
private struct CaptionsNavIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            Canvas { context, _ in
                let stroke = StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round)
                context.stroke(
                    Path(roundedRect: CGRect(x: 3 * s, y: 5 * s, width: 18 * s, height: 14 * s),
                         cornerSize: CGSize(width: 2 * s, height: 2 * s)),
                    with: .foreground,
                    style: stroke
                )
                var bars = Path()
                bars.move(to: CGPoint(x: 7 * s, y: 15 * s))
                bars.addLine(to: CGPoint(x: 11 * s, y: 15 * s))
                bars.move(to: CGPoint(x: 15 * s, y: 15 * s))
                bars.addLine(to: CGPoint(x: 17 * s, y: 15 * s))
                bars.move(to: CGPoint(x: 7 * s, y: 11 * s))
                bars.addLine(to: CGPoint(x: 9 * s, y: 11 * s))
                bars.move(to: CGPoint(x: 13 * s, y: 11 * s))
                bars.addLine(to: CGPoint(x: 17 * s, y: 11 * s))
                context.stroke(bars, with: .foreground, style: stroke)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Lucide `SquarePlay` — rounded square with a play triangle.
private struct SquarePlayNavIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            Canvas { context, _ in
                let stroke = StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round)
                context.stroke(
                    Path(roundedRect: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s),
                         cornerSize: CGSize(width: 2 * s, height: 2 * s)),
                    with: .foreground,
                    style: stroke
                )
                // Lucide play triangle (approximate the rounded tip with a filled path).
                var play = Path()
                play.move(to: CGPoint(x: 9 * s, y: 8.5 * s))
                play.addLine(to: CGPoint(x: 16 * s, y: 12 * s))
                play.addLine(to: CGPoint(x: 9 * s, y: 15.5 * s))
                play.closeSubpath()
                context.fill(play, with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Microphone with a document badge — mirrors web `transcriptionIcon`.
private struct TranscriptionNavIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3 * s, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
                    .frame(width: 6 * s, height: 13 * s)
                    .position(x: 12 * s, y: 8.5 * s)

                Path { path in
                    path.move(to: CGPoint(x: 12 * s, y: 19 * s))
                    path.addLine(to: CGPoint(x: 12 * s, y: 22 * s))
                }
                .stroke(style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: 19 * s, y: 10 * s))
                    path.addLine(to: CGPoint(x: 19 * s, y: 12 * s))
                    path.addArc(
                        center: CGPoint(x: 12 * s, y: 12 * s),
                        radius: 7 * s,
                        startAngle: .degrees(0),
                        endAngle: .degrees(180),
                        clockwise: false
                    )
                    path.addLine(to: CGPoint(x: 5 * s, y: 10 * s))
                }
                .stroke(style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))

                // Opaque badge plate matching web `--icon-bg` over the mic corner.
                RoundedRectangle(cornerRadius: 3 * s, style: .continuous)
                    .fill(AppTheme.Background.surfaceColor)
                    .frame(width: 12 * s, height: 14 * s)
                    .position(x: 17.6 * s, y: 17.4 * s)

                DocumentGlyph(scale: s * 0.5)
                    .frame(width: 12 * s, height: 14 * s)
                    .position(x: 17.6 * s, y: 17.4 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Document with speaker badge — mirrors web `voiceoverIcon`.
private struct VoiceoverNavIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            ZStack(alignment: .topLeading) {
                DocumentGlyph(scale: s)
                    .frame(width: 24 * s, height: 24 * s)

                Circle()
                    .fill(AppTheme.Background.surfaceColor)
                    .frame(width: 19.2 * s, height: 19.2 * s)
                    .position(x: 18.6 * s, y: 18.6 * s)

                SpeakerGlyph(scale: s * 0.52)
                    .frame(width: 12.5 * s, height: 12.5 * s)
                    .position(x: 18.6 * s, y: 18.6 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct DocumentGlyph: View {
    let scale: CGFloat

    var body: some View {
        let s = scale
        Canvas { context, _ in
            let stroke = StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round)
            func strokePath(_ build: (inout Path) -> Void) {
                var path = Path()
                build(&path)
                context.stroke(path, with: .foreground, style: stroke)
            }

            strokePath { p in
                p.move(to: CGPoint(x: 8 * s, y: 2 * s))
                p.addLine(to: CGPoint(x: 8 * s, y: 6 * s))
            }
            strokePath { p in
                p.move(to: CGPoint(x: 12 * s, y: 2 * s))
                p.addLine(to: CGPoint(x: 12 * s, y: 6 * s))
            }
            strokePath { p in
                p.move(to: CGPoint(x: 16 * s, y: 2 * s))
                p.addLine(to: CGPoint(x: 16 * s, y: 6 * s))
            }

            let page = Path(
                roundedRect: CGRect(x: 4 * s, y: 4 * s, width: 16 * s, height: 18 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s)
            )
            context.stroke(page, with: .foreground, style: stroke)

            strokePath { p in
                p.move(to: CGPoint(x: 8 * s, y: 10 * s))
                p.addLine(to: CGPoint(x: 14 * s, y: 10 * s))
            }
            strokePath { p in
                p.move(to: CGPoint(x: 8 * s, y: 14 * s))
                p.addLine(to: CGPoint(x: 16 * s, y: 14 * s))
            }
            strokePath { p in
                p.move(to: CGPoint(x: 8 * s, y: 18 * s))
                p.addLine(to: CGPoint(x: 13 * s, y: 18 * s))
            }
        }
    }
}

private struct SpeakerGlyph: View {
    let scale: CGFloat

    var body: some View {
        let s = scale
        Canvas { context, _ in
            let stroke = StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round)
            func strokePath(_ build: (inout Path) -> Void) {
                var path = Path()
                build(&path)
                context.stroke(path, with: .foreground, style: stroke)
            }

            // Simplified Lucide Speech silhouette used by web voiceover badge.
            strokePath { p in
                p.move(to: CGPoint(x: 8.8 * s, y: 20 * s))
                p.addLine(to: CGPoint(x: 8.8 * s, y: 15.9 * s))
                p.addLine(to: CGPoint(x: 10.7 * s, y: 16.1 * s))
                p.addQuadCurve(
                    to: CGPoint(x: 12.864 * s, y: 14 * s),
                    control: CGPoint(x: 13.5 * s, y: 16 * s)
                )
                p.addLine(to: CGPoint(x: 12.864 * s, y: 8.3 * s))
                p.addQuadCurve(
                    to: CGPoint(x: 2 * s, y: 8.25 * s),
                    control: CGPoint(x: 7.4 * s, y: 2.5 * s)
                )
                p.addCurve(
                    to: CGPoint(x: 3 * s, y: 12.8 * s),
                    control1: CGPoint(x: 2 * s, y: 11 * s),
                    control2: CGPoint(x: 2.656 * s, y: 11.3 * s)
                )
                p.addQuadCurve(
                    to: CGPoint(x: 3.029 * s, y: 15.558 * s),
                    control: CGPoint(x: 3.2 * s, y: 14.2 * s)
                )
                p.addLine(to: CGPoint(x: 2 * s, y: 20 * s))
            }
            strokePath { p in
                p.move(to: CGPoint(x: 19.8 * s, y: 17.8 * s))
                p.addQuadCurve(
                    to: CGPoint(x: 19.803 * s, y: 7.197 * s),
                    control: CGPoint(x: 24 * s, y: 12.5 * s)
                )
            }
            strokePath { p in
                p.move(to: CGPoint(x: 17 * s, y: 15 * s))
                p.addQuadCurve(
                    to: CGPoint(x: 16.975 * s, y: 10.025 * s),
                    control: CGPoint(x: 19.2 * s, y: 12.5 * s)
                )
            }
        }
    }
}
