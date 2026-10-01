import SwiftUI

struct HueCurveEditorView: View {
    let curves: HueCurves
    var onChange: (HueCurves.Channel, [CurvePoint]) -> Void
    var onCommit: (HueCurves.Channel, [CurvePoint]) -> Void

    @Environment(EditorViewModel.self) private var editor
    @State private var channel: HueCurves.Channel = .hue
    @State private var liveDrag: (points: [CurvePoint], index: Int)?
    @State private var hueHist: [Float] = []
    @State private var histInFlight = false
    @State private var histDirty = false

    private static let spectrum: [Color] = [
        .init(red: 1, green: 0.23, blue: 0.19), .init(red: 0.95, green: 0.85, blue: 0.2),
        .init(red: 0.3, green: 0.85, blue: 0.35), .init(red: 0.2, green: 0.8, blue: 0.85),
        .init(red: 0.25, green: 0.5, blue: 0.95), .init(red: 0.8, green: 0.35, blue: 0.9),
        .init(red: 1, green: 0.23, blue: 0.19),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker(String(), selection: $channel) {
                ForEach(HueCurves.Channel.allCases) { Text(channelTitle($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: AppTheme.Curve.editorHeight)
                ZStack {
                    LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing)
                        .opacity(AppTheme.Opacity.medium)
                    Canvas { ctx, _ in
                        if hueHist.count > 1 {
                            ctx.fill(CurveEditorGeometry.histogramAreaPath(hueHist, in: size),
                                     with: .color(AppTheme.MediaOverlay.primaryColor.opacity(AppTheme.Opacity.muted)))
                            ctx.stroke(histogramLine(hueHist, size),
                                       with: .color(AppTheme.MediaOverlay.primaryColor.opacity(AppTheme.Opacity.prominent)),
                                       lineWidth: AppTheme.BorderWidth.thin)
                        }
                        var grid = Path()
                        for stop in stride(from: 0.0, through: 1.0, by: 1.0 / 6) {
                            let x = CGFloat(stop) * size.width
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        ctx.stroke(grid, with: .color(AppTheme.Border.subtleColor.opacity(AppTheme.Opacity.medium)),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var mid = Path()
                        mid.move(to: CGPoint(x: 0, y: size.height / 2))
                        mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        ctx.stroke(mid, with: .color(AppTheme.Border.subtleColor),
                                   style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var line = Path()
                        for i in stride(from: 0.0, through: 1.0, by: 0.01) {
                            let p = CurveEditorGeometry.screenPoint(
                                CurvePoint(x: i, y: HueCurves.eval(activePoints, i)),
                                in: size
                            )
                            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        }
                        ctx.stroke(line, with: .color(AppTheme.Text.primaryColor),
                                   lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .gesture(curveDrag(size))
                    .onTapGesture(count: 2) { location in removeNearest(to: location, size) }

                    ForEach(Array(activePoints.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(AppTheme.Text.primaryColor)
                            .frame(width: AppTheme.Curve.pointDiameter, height: AppTheme.Curve.pointDiameter)
                            .position(CurveEditorGeometry.screenPoint(pt, in: size))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            .frame(height: AppTheme.Curve.editorHeight)

            Text(L10n.string("Drag to add or shape a point · double-click to remove"))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .onAppear { refreshHistogram() }
        .onChange(of: editor.timelineRenderRevision) { _, _ in refreshHistogram() }
        .onChange(of: editor.activeFrame) { _, _ in refreshHistogram() }
        .onChange(of: editor.isPlaying) { _, playing in if !playing { refreshHistogram() } }
    }

    /// One generator pass in flight at a time; coalesce mid-pass changes into a trailing refresh.
    private func refreshHistogram() {
        guard editor.videoEngine != nil, !editor.isPlaying else { return }
        if histInFlight { histDirty = true; return }
        histInFlight = true
        let frame = editor.activeFrame
        Task { @MainActor in
            if let h = await editor.videoEngine?.hueHistogram(frame: frame) { hueHist = h }
            histInFlight = false
            if histDirty { histDirty = false; refreshHistogram() }
        }
    }

    /// The histogram's top contour only — stroked over the fill.
    private func histogramLine(_ bins: [Float], _ size: CGSize) -> Path {
        var path = Path()
        for (i, v) in bins.enumerated() {
            let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
            let p = CGPoint(x: x, y: size.height - CGFloat(v) * size.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private var channelPoints: [CurvePoint] { curves.points(channel) }

    private func channelTitle(_ channel: HueCurves.Channel) -> String {
        switch channel {
        case .hue: L10n.string("Hue")
        case .sat: L10n.string("Sat")
        case .lum: L10n.string("Luma")
        }
    }

    private var displayPoints: [CurvePoint] {
        (channelPoints.isEmpty ? HueCurves.defaultPoints : channelPoints).sorted { $0.x < $1.x }
    }

    /// Points to draw — the live in-flight drag if any, else the committed curve.
    private var activePoints: [CurvePoint] { liveDrag?.points ?? displayPoints }

    /// One gesture: grab the nearest point (or drop a new one) at press, then drag it.
    private func curveDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                var d = liveDrag ?? CurveEditorGeometry.grabbedPoint(
                    at: v.startLocation,
                    in: displayPoints,
                    canvasSize: size,
                    hitDiameter: AppTheme.Curve.pointHitDiameter
                )
                d.points = CurveEditorGeometry.movedPoint(
                    in: d.points,
                    at: d.index,
                    to: v.location,
                    canvasSize: size
                )
                liveDrag = d
                emit(d.points, commit: false)
            }
            .onEnded { v in
                if let d = liveDrag {
                    emit(
                        CurveEditorGeometry.movedPoint(
                            in: d.points,
                            at: d.index,
                            to: v.location,
                            canvasSize: size
                        ),
                        commit: true
                    )
                }
                liveDrag = nil
            }
    }

    private func removeNearest(to location: CGPoint, _ size: CGSize) {
        guard let points = CurveEditorGeometry.removingNearestPoint(
            to: location,
            in: displayPoints,
            canvasSize: size,
            hitDiameter: AppTheme.Curve.pointHitDiameter
        ) else { return }
        emit(points, commit: true)
    }

    private func emit(_ pts: [CurvePoint], commit: Bool) {
        let value = HueCurves.isNeutral(pts) ? [] : pts
        (commit ? onCommit : onChange)(channel, value)
    }
}
