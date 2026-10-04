import AppKit
import SwiftUI

/// Persist the chosen color, rather than hashing a mutable speaker name.
struct SessionSpeakerColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemIndigo
        self.init(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Keep a custom hue recognizable while maintaining readable labels in either appearance.
    var labelColor: Color {
        let light = readable(on: 0.98)
        let dark = readable(on: 0.09)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    }

    private func readable(on background: Double) -> Self {
        let backgroundLuminance = Self.linear(background)
        var result = self
        for _ in 0..<40 {
            let contrast = (max(result.luminance, backgroundLuminance) + 0.05)
                / (min(result.luminance, backgroundLuminance) + 0.05)
            if contrast >= 4.5 { break }
            let target = background > 0.5 ? 0.0 : 1.0
            result = Self(
                result.red * 0.94 + target * 0.06,
                result.green * 0.94 + target * 0.06,
                result.blue * 0.94 + target * 0.06
            )
        }
        return result
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private var luminance: Double {
        Self.linear(red) * 0.2126 + Self.linear(green) * 0.7152 + Self.linear(blue) * 0.0722
    }

    private var hue: Double {
        let rgb = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        return Double(rgb.hueComponent)
    }

    private var lab: (Double, Double, Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        )
    }

    func distance(to other: Self) -> Double {
        let a = lab, b = other.lab
        return sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
    }

    private func hueDistance(to other: Self) -> Double {
        let delta = abs(hue - other.hue)
        return min(delta, 1 - delta)
    }

    static let presets: [Self] = [
        Self(0.39, 0.32, 0.68), Self(0.12, 0.47, 0.41),
        Self(0.73, 0.30, 0.17), Self(0.62, 0.43, 0.08),
        Self(0.67, 0.23, 0.47), Self(0.18, 0.43, 0.72),
        Self(0.38, 0.51, 0.14), Self(0.51, 0.28, 0.57)
    ]

    static func next(excluding used: [Self]) -> Self {
        guard !used.isEmpty else { return presets[0] }
        // Favor a different hue family, then maximize the minimum perceptual
        // distance to *every* existing color, including user-selected colors.
        let candidates = presets + (0..<24).map { step in
            let rgb = NSColor(hue: Double(step) / 24, saturation: 0.72, brightness: 0.66, alpha: 1)
            return Self(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        }
        let distinct = candidates.filter { candidate in
            used.allSatisfy { candidate.hueDistance(to: $0) >= 0.075 && candidate.distance(to: $0) >= 0.10 }
        }
        return (distinct.isEmpty ? candidates : distinct).max { a, b in
            func score(_ candidate: Self) -> Double {
                used.map { candidate.distance(to: $0) + candidate.hueDistance(to: $0) * 0.35 }.min() ?? 0
            }
            return score(a) < score(b)
        } ?? presets[0]
    }
}

struct SessionSpeakerColors: Codable, Equatable, Sendable {
    private(set) var values: [String: SessionSpeakerColor] = [:]

    mutating func ensure(_ labels: [String]) {
        for raw in labels {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, values[label] == nil else { continue }
            values[label] = .next(excluding: Array(values.values))
        }
    }

    mutating func set(_ color: SessionSpeakerColor, for label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        values[label] = color
    }

    mutating func rename(_ current: String, to replacement: String) {
        guard current != replacement, let color = values.removeValue(forKey: current) else { return }
        // Renaming into an existing label merges identities; keep that label's color.
        if values[replacement] == nil { values[replacement] = color }
    }
}

struct SessionSpeakerColorPicker: View {
    let label: String
    @Binding var selection: SessionSpeakerColor

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Speaker color"))
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
            Text(label)
                .foregroundStyle(selection.labelColor)
            HStack(spacing: AppTheme.Spacing.smMd) {
                ForEach(Array(SessionSpeakerColor.presets.enumerated()), id: \.offset) { index, color in
                    Button {
                        selection = color
                    } label: {
                        Circle().fill(color.color)
                            .frame(width: AppTheme.zoomed(24), height: AppTheme.zoomed(24))
                            .overlay {
                                if selection == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: AppTheme.FontSize.xs, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("Speaker color %d", index + 1))
                    .accessibilityAddTraits(selection == color ? .isSelected : [])
                }
            }
            ColorPicker(L10n.string("Custom color…"), selection: Binding(
                get: { selection.color },
                set: { selection = SessionSpeakerColor(color: $0) }
            ), supportsOpacity: false)
            .font(.system(size: AppTheme.FontSize.smMd))
        }
        .font(.system(size: AppTheme.FontSize.md))
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.zoomed(320))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SessionAddSpeakerSheet: View {
    let existingLabels: [String]
    let onAdd: (String, SessionSpeakerColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: SessionSpeakerColor
    @State private var showsColorPicker = false

    init(existingLabels: [String], color: SessionSpeakerColor,
         onAdd: @escaping (String, SessionSpeakerColor) -> Void) {
        self.existingLabels = existingLabels
        self.onAdd = onAdd
        _color = State(initialValue: color)
    }

    private var label: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var alreadyExists: Bool { existingLabels.contains(label) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            Text(L10n.string("Add speaker"))
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
            TextField(L10n.string("Speaker name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
            HStack {
                Text(L10n.string("Color"))
                Spacer()
                Button { showsColorPicker = true } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .fill(color.color)
                            .frame(width: AppTheme.zoomed(28), height: AppTheme.zoomed(20))
                        Image(systemName: "chevron.down")
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("Change color…"))
                .popover(isPresented: $showsColorPicker) {
                    SessionSpeakerColorPicker(label: label.isEmpty ? L10n.string("Speaker") : label, selection: $color)
                }
            }
            Text(L10n.string(alreadyExists
                ? "This speaker already exists. Choose it from the speaker menu."
                : "New speakers receive a clearly distinct color."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Add"), action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty || alreadyExists)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(width: AppTheme.zoomed(340))
    }

    private func add() {
        guard !label.isEmpty, !alreadyExists else { return }
        onAdd(label, color)
        dismiss()
    }
}
