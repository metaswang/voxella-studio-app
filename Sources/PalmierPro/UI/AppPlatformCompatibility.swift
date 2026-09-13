import SwiftUI

enum AppGlassEffectStyle {
    case clear
    case regular
}

enum AppScrollEdge {
    case bottom
    case top
}

struct AppGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func appGlassEffect<S: Shape>(
        _ style: AppGlassEffectStyle = .regular,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            switch style {
            case .clear:
                glassEffect(.clear, in: shape)
            case .regular:
                glassEffect(.regular, in: shape)
            }
        } else {
            background(AppTheme.Background.raisedColor, in: shape)
                .overlay {
                    shape.stroke(
                        AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
                }
        }
    }

    @ViewBuilder
    func appGlassEffectID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func appGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    func appScrollEdgeEffect(_ edge: AppScrollEdge) -> some View {
        if #available(macOS 26.0, *) {
            switch edge {
            case .bottom:
                scrollEdgeEffectStyle(.soft, for: .bottom)
            case .top:
                scrollEdgeEffectStyle(.soft, for: .top)
            }
        } else {
            self
        }
    }
}
