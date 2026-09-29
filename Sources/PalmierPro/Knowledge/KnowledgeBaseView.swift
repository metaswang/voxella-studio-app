import AppKit
import SwiftUI

struct KnowledgeBaseView: View {
    private static let panelRatioKey = "voxella.kb.panel-ratio.v2"

    @State private var controller = KnowledgeBaseController()
    @State private var splitRatio: CGFloat = AppTheme.Knowledge.defaultPanelRatio
    @State private var dragStartRatio: CGFloat?
    @State private var isDraggingSplitter = false
    @Bindable private var account = AccountService.shared

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let left = Self.clampedLeftWidth(total: total, ratio: splitRatio)
            let chatWidth = max(1, total - left - AppTheme.Workbench.sessionSplitDividerHitWidth)
            HStack(spacing: 0) {
                KnowledgeSourceListView(controller: controller)
                    .frame(width: left)

                splitter(total: total)

                KnowledgeChatPane(controller: controller, availableWidth: chatWidth)
                    .frame(width: chatWidth, height: max(1, geo.size.height))
            }
        }
        .background(AppTheme.Background.baseColor)
        .onAppear {
            splitRatio = Self.loadPersistedRatio()
            controller.onAppear()
        }
        .task {
            do {
                try await account.prepareNewContentAccess()
            } catch is CancellationError {
                return
            } catch {
                controller.refreshAccessGate()
                return
            }
            controller.refreshAccessGate()
        }
        .onChange(of: account.appAccess) { _, _ in
            controller.refreshAccessGate()
        }
        .onChange(of: account.isSignedIn) { _, _ in
            controller.refreshAccessGate()
        }
        .onChange(of: account.isPaid) { _, _ in
            controller.refreshAccessGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiConfigurationDidChange)) { _ in
            controller.refreshAccessGate()
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
        let available = max(1, total - AppTheme.Workbench.sessionSplitDividerHitWidth)
        let minLeft = min(AppTheme.Knowledge.minimumSourceWidth, max(1, available - AppTheme.Knowledge.minimumChatWidth))
        let maxLeft = max(available - AppTheme.Knowledge.minimumChatWidth, minLeft)
        return min(max(total * ratio, minLeft), maxLeft)
    }

    static func clampedRatio(left: CGFloat, total: CGFloat) -> CGFloat {
        let width = clampedLeftWidth(total: total, ratio: left / max(total, 1))
        return min(
            max(width / max(total, 1), AppTheme.Knowledge.minimumPanelRatio),
            AppTheme.Knowledge.maximumPanelRatio
        )
    }

    static func loadPersistedRatio() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: panelRatioKey) != nil else {
            return AppTheme.Knowledge.defaultPanelRatio
        }
        let value = defaults.double(forKey: panelRatioKey)
        guard value.isFinite,
              value > AppTheme.Knowledge.minimumPanelRatio,
              value < AppTheme.Knowledge.maximumPanelRatio
        else {
            return AppTheme.Knowledge.defaultPanelRatio
        }
        return CGFloat(value)
    }

    static func persistRatio(_ ratio: CGFloat) {
        guard ratio.isFinite else { return }
        UserDefaults.standard.set(Double(ratio), forKey: panelRatioKey)
    }
}
