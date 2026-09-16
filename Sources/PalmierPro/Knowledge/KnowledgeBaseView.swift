import AppKit
import SwiftUI

struct KnowledgeBaseView: View {
    private static let defaultRatio: CGFloat = 0.28
    private static var minLeftWidth: CGFloat { AppTheme.Knowledge.minimumSourceWidth }
    private static var minRightWidth: CGFloat { AppTheme.Knowledge.minimumChatWidth }
    private static let panelRatioKey = "voxella.kb.panel-ratio.v1"

    @State private var controller = KnowledgeBaseController()
    @State private var splitRatio: CGFloat = Self.defaultRatio
    @State private var dragStartRatio: CGFloat?
    @State private var isDraggingSplitter = false

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let left = Self.clampedLeftWidth(total: total, ratio: splitRatio)
            HStack(spacing: 0) {
                KnowledgeSourceListView(controller: controller)
                    .frame(width: left)

                splitter(total: total)

                KnowledgeChatPane(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            splitRatio = Self.loadPersistedRatio()
            controller.onAppear()
        }
    }

    private func splitter(total: CGFloat) -> some View {
        let hit = AppTheme.Workbench.sessionSplitDividerHitWidth
        return ZStack {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(width: AppTheme.BorderWidth.hairline)
            Color.clear
                .frame(width: hit)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering || isDraggingSplitter {
                        NSCursor.resizeLeftRight.set()
                    } else if !isDraggingSplitter {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartRatio == nil {
                                dragStartRatio = splitRatio
                                isDraggingSplitter = true
                                NSCursor.resizeLeftRight.set()
                            }
                            let startLeft = Self.clampedLeftWidth(
                                total: total,
                                ratio: dragStartRatio ?? splitRatio
                            )
                            let newLeft = startLeft + value.translation.width
                            splitRatio = Self.clampedRatio(left: newLeft, total: total)
                        }
                        .onEnded { _ in
                            dragStartRatio = nil
                            isDraggingSplitter = false
                            Self.persistRatio(splitRatio)
                            NSCursor.arrow.set()
                        }
                )
        }
        .frame(width: hit)
        .zIndex(1)
        .accessibilityLabel(Text("Resize knowledge panels"))
    }

    // MARK: - Ratio helpers

    static func clampedLeftWidth(total: CGFloat, ratio: CGFloat) -> CGFloat {
        let minLeft = minLeftWidth
        let maxLeft = max(total - minRightWidth, minLeft)
        return min(max(total * ratio, minLeft), maxLeft)
    }

    static func clampedRatio(left: CGFloat, total: CGFloat) -> CGFloat {
        let width = clampedLeftWidth(total: total, ratio: left / max(total, 1))
        return min(max(width / max(total, 1), 0.05), 0.95)
    }

    static func loadPersistedRatio() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: panelRatioKey) != nil else {
            return defaultRatio
        }
        let value = defaults.double(forKey: panelRatioKey)
        guard value.isFinite, value > 0.05, value < 0.95 else {
            return defaultRatio
        }
        return CGFloat(value)
    }

    static func persistRatio(_ ratio: CGFloat) {
        guard ratio.isFinite else { return }
        UserDefaults.standard.set(Double(ratio), forKey: panelRatioKey)
    }
}
