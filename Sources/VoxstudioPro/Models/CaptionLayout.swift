import AppKit

/// A session can be placed on several audio tracks. Never use its ID as a layout group.
struct CaptionSourceContext: Codable, Sendable, Equatable, Hashable {
    var audioTrackId: String
    var placementId: String
}

struct CaptionLayoutBinding: Codable, Sendable, Equatable {
    var source: CaptionSourceContext
    var order: Int = 0
    var automatic = true
    var lastAutoTransform: Transform?
}

enum CaptionLayoutEngine {
    static let safetyFraction = 0.05
    static let referenceGap = 16.0

    struct Geometry: Sendable {
        var boxSize: CGSize
        var outsetX: Double
        var outsetTop: Double
        var outsetBottom: Double
        var height: Double { Double(boxSize.height) + outsetTop + outsetBottom }
    }

    private final class CachedGeometry: NSObject {
        let value: Geometry
        init(_ value: Geometry) { self.value = value }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedGeometry> = {
        let cache = NSCache<NSString, CachedGeometry>()
        cache.countLimit = 4096
        return cache
    }()

    static func geometry(for clip: Clip, width: Int, height: Int) -> Geometry {
        let style = (clip.textStyle ?? TextStyle()).scaledVisualStyle
        let content = TranscriptSegmenter.renderedSubtitleText(clip.textContent ?? "")
        let encodedStyle = (try? JSONEncoder().encode(style).base64EncodedString()) ?? ""
        let key = "\(width)|\(height)|\(encodedStyle)|\(clip.textAnimation?.preset.rawValue ?? "none")|\(content)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let scale = Double(height) / Double(TextLayout.referenceCanvasHeight)
        let font = style.fontSize * scale
        let shadowX = style.shadow.enabled ? (abs(style.shadow.offsetX) + max(0, style.shadow.blur) * 2) * scale : 0
        let shadowY = style.shadow.enabled ? (abs(style.shadow.offsetY) + max(0, style.shadow.blur) * 2) * scale : 0
        let border = style.border.enabled ? max(0, style.border.width) * scale : 0
        let backgroundX = style.background.enabled ? (abs(style.background.offsetX) + max(0, style.background.outlineWidth)) * scale : 0
        let backgroundY = style.background.enabled ? (abs(style.background.offsetY) + max(0, style.background.outlineWidth)) * scale : 0
        var outsetX = max(shadowX, border, backgroundX)
        var top = max(shadowY, border, backgroundY)
        var bottom = top
        switch clip.textAnimation?.preset {
        case .slideUp: bottom += Double(height) * 0.05
        case .wordSlide: bottom += font * 0.5
        case .highlightPop, .wordPop:
            top += font * 0.2; bottom += font * 0.2; outsetX += font * 0.2
        case .highlightBlock:
            top += font * 0.1; bottom += font * 0.1; outsetX += font * 0.18
        default: break
        }
        let boxWidth = max(1, Double(width) * 0.9 - outsetX * 2)
        // naturalSize adds decoration slack after measuring glyphs. Subtract it before
        // constraining CoreText, so its wrap width matches the rendered content box.
        let shadowPaddingX = style.shadow.enabled ? max(Double(TextLayout.shadowPadding), max(0, style.shadow.blur) + abs(style.shadow.offsetX)) * scale * 2 : 0
        let borderPadding = style.border.enabled ? Double(style.glyphBorderPadding(fontSize: CGFloat(font))) * 2 : 0
        let backgroundPadding = style.background.enabled ? max(0, style.background.paddingX) * scale * 2 : 0
        let natural = TextLayout.naturalSize(content: content, style: style,
            maxWidth: max(1, boxWidth - shadowPaddingX - borderPadding - backgroundPadding - 4),
            canvasHeight: CGFloat(height))
        let result = Geometry(boxSize: CGSize(width: min(boxWidth, natural.width), height: natural.height),
                              outsetX: outsetX, outsetTop: top, outsetBottom: bottom)
        cache.setObject(CachedGeometry(result), forKey: key)
        return result
    }

    /// Atomic, source-scoped layout. Fixed lane heights do not depend on the playhead.
    @discardableResult
    static func arrange(_ timeline: inout Timeline, source: CaptionSourceContext) -> Bool {
        guard timeline.width > 0, timeline.height > 0 else { return false }
        var candidate = timeline
        var lanes: [String: [(Int, Int)]] = [:]
        var obstacles: [ClosedRange<Double>] = []
        for ti in candidate.tracks.indices {
            for ci in candidate.tracks[ti].clips.indices {
                var clip = candidate.tracks[ti].clips[ci]
                guard var binding = clip.captionLayout, binding.source == source else { continue }
                if clip.hasTransformAnimation || clip.transform.rotation != 0 || clip.transform.flipHorizontal || clip.transform.flipVertical {
                    binding.automatic = false
                    clip.captionLayout = binding
                    candidate.tracks[ti].clips[ci] = clip
                }
                if binding.automatic {
                    lanes[clip.captionGroupId ?? clip.id, default: []].append((ti, ci))
                } else {
                    let g = geometry(for: clip, width: timeline.width, height: timeline.height)
                    let h = clip.transform.height * Double(timeline.height)
                    let y = clip.transform.centerY * Double(timeline.height)
                    obstacles.append((y - h / 2 - g.outsetTop)...(y + h / 2 + g.outsetBottom))
                }
            }
        }
        let ordered = lanes.keys.sorted {
            let a = lanes[$0]!.first!, b = lanes[$1]!.first!
            let oa = candidate.tracks[a.0].clips[a.1].captionLayout!.order
            let ob = candidate.tracks[b.0].clips[b.1].captionLayout!.order
            return oa == ob ? $0 < $1 : oa < ob
        }
        let canvasH = Double(timeline.height), canvasW = Double(timeline.width)
        let gap = referenceGap * canvasH / 1080
        var laneBottom = canvasH * (1 - safetyFraction)
        for lane in ordered {
            let entries = lanes[lane]!
            let measurements = entries.map { geometry(for: candidate.tracks[$0.0].clips[$0.1], width: timeline.width, height: timeline.height) }
            let laneHeight = measurements.map(\.height).max() ?? 0
            // Reserve manually positioned siblings as fixed obstacles in this source only.
            while let obstacle = obstacles.filter({ laneBottom - laneHeight < $0.upperBound + gap && laneBottom > $0.lowerBound - gap }).min(by: { $0.lowerBound < $1.lowerBound }) {
                laneBottom = obstacle.lowerBound - gap
            }
            guard laneBottom - laneHeight >= canvasH * safetyFraction else { return false }
            for (index, entry) in entries.enumerated() {
                let g = measurements[index]
                var clip = candidate.tracks[entry.0].clips[entry.1]
                clip.transform = Transform(center: (0.5, (laneBottom - g.outsetBottom - Double(g.boxSize.height) / 2) / canvasH),
                                           width: Double(g.boxSize.width) / canvasW, height: Double(g.boxSize.height) / canvasH)
                clip.captionLayout?.lastAutoTransform = clip.transform
                candidate.tracks[entry.0].clips[entry.1] = clip
            }
            laneBottom -= laneHeight + gap
        }
        timeline = candidate
        return true
    }
}
