import CoreGraphics

enum PreviewCanvasGeometry {
    static func videoContentRect(in viewSize: CGSize, timeline: Timeline) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              timeline.width > 0, timeline.height > 0 else {
            return .zero
        }
        let videoAspect = CGFloat(timeline.width) / CGFloat(timeline.height)
        let viewAspect = viewSize.width / viewSize.height
        let size: CGSize
        if viewAspect > videoAspect {
            size = CGSize(width: viewSize.height * videoAspect, height: viewSize.height)
        } else {
            size = CGSize(width: viewSize.width, height: viewSize.width / videoAspect)
        }
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
