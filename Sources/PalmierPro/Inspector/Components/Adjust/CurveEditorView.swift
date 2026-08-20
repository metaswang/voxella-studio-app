import SwiftUI

struct CurveEditorView: View {
    let curve: GradeCurve
    var onChange: (Channel, [CurvePoint]) -> Void
    var onCommit: (Channel, [CurvePoint]) -> Void

    @Environment(EditorViewModel.self) private var editor
    @State private var channel: Channel = .master
    @State private var liveDrag: (points: [CurvePoint], index: Int)?
    @State private var histY: [Float] = []
    @State private var histR: [Float] = []
    @State private var histG: [Float] = []
    @State private var histB: [Float] = []
    @State private var histInFlight = false
    @State private var histDirty = false

    enum Channel: String, CaseIterable, Identifiable {
        case master = "Y", red = "R", green = "G", blue = "B"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .master: AppTheme.Text.secondaryColor
            case .red: AppTheme.Curve.redColor
            case .green: AppTheme.Curve.greenColor
            case .blue: AppTheme.Curve.blueColor
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker(String(), selection: $channel) {
                ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: AppTheme.Curve.editorHeight)
                ZStack {
                    Canvas { ctx, _ in
                        if histR.count > 1 {
                            // Luma silhouette behind, then the RGB parade additively on top.
                            ctx.fill(
                                CurveEditorGeometry.histogramAreaPath(histY, in: size),
                                with: .color(AppTheme.Curve.lumaColor.opacity(AppTheme.Opacity.medium))
                            )
                            ctx.blendMode = .plusLighter
                            ctx.fill(
                                CurveEditorGeometry.histogramAreaPath(histR, in: size),
                                with: .color(AppTheme.Curve.redColor.opacity(AppTheme.Opacity.medium))
                            )
                            ctx.fill(
                                CurveEditorGeometry.histogramAreaPath(histG, in: size),
                                with: .color(AppTheme.Curve.greenColor.opacity(AppTheme.Opacity.medium))
                            )
                            ctx.fill(
                                CurveEditorGeometry.histogramAreaPath(histB, in: size),
                                with: .color(AppTheme.Curve.blueColor.opacity(AppTheme.Opacity.medium))
                            )
                            ctx.blendMode = .normal
                        }
                        // Quarter grid: black · shadow · mid · highlight · white.
                        var grid = Path()
                        for stop in stride(from: 0.0, through: 1.0, by: 0.25) {
                            let s = CGFloat(stop)
                            grid.move(to: CGPoint(x: s * size.width, y: 0))
                            grid.addLine(to: CGPoint(x: s * size.width, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: s * size.height))
                            grid.addLine(to: CGPoint(x: size.width, y: s * size.height))
                        }
                        ctx.stroke(grid, with: .color(AppTheme.Border.subtleColor.opacity(AppTheme.Opacity.medium)),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var diag = Path()
                        diag.move(
                            to: CurveEditorGeometry.screenPoint(CurvePoint(x: 0, y: 0), in: size)
                        )
                        diag.addLine(
                            to: CurveEditorGeometry.screenPoint(CurvePoint(x: 1, y: 1), in: size)
                        )
                        ctx.stroke(diag, with: .color(AppTheme.Border.subtleColor),
                                   style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        var line = Path()
                        for i in stride(from: 0.0, through: 1.0, by: 0.02) {
                            let p = CurveEditorGeometry.screenPoint(
                                CurvePoint(x: i, y: GradeCurve.eval(activePoints, i)),
                                in: size
                            )
                            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        }
                        ctx.stroke(line, with: .color(channel.tint), lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .gesture(curveDrag(size))
                    .onTapGesture(count: 2) { location in removeNearest(to: location, size) }

                    ForEach(Array(activePoints.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(channel.tint)
                            .frame(width: AppTheme.Curve.pointDiameter, height: AppTheme.Curve.pointDiameter)
                            .position(CurveEditorGeometry.screenPoint(pt, in: size))
                            .allowsHitTesting(false)
                    }
                }
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
            if let h = await editor.videoEngine?.histogramYRGB(frame: frame) {
                histY = h.y; histR = h.r; histG = h.g; histB = h.b
            }
            histInFlight = false
            if histDirty { histDirty = false; refreshHistogram() }
        }
    }

    // MARK: - Points

    private var channelPoints: [CurvePoint] {
        switch channel {
        case .master: curve.master
        case .red: curve.red
        case .green: curve.green
        case .blue: curve.blue
        }
    }

    private var sortedPoints: [CurvePoint] {
        (channelPoints.isEmpty ? GradeCurve.identityPoints : channelPoints).sorted { $0.x < $1.x }
    }

    /// Points to draw — the live in-flight drag if any, else the committed curve.
    private var activePoints: [CurvePoint] { liveDrag?.points ?? sortedPoints }

    /// One gesture: grab the nearest point (or drop a new one) at press, then drag it.
    private func curveDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                var d = liveDrag ?? CurveEditorGeometry.grabbedPoint(
                    at: v.startLocation,
                    in: sortedPoints,
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
            in: sortedPoints,
            canvasSize: size,
            hitDiameter: AppTheme.Curve.pointHitDiameter
        ) else { return }
        emit(points, commit: true)
    }

    private func emit(_ pts: [CurvePoint], commit: Bool) {
        let value = (pts == GradeCurve.identityPoints) ? [] : pts
        (commit ? onCommit : onChange)(channel, value)
    }
}
