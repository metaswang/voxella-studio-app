import CoreGraphics
import Foundation

enum CaptionSpecBuilder {
    struct Target: Sendable {
        let clip: Clip
        let result: TranscriptionResult
        var source: CaptionSourceContext? = nil
    }

    struct Input: Sendable {
        let targets: [Target]
        let fps: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let style: TextStyle
        let center: CGPoint
        let textCase: EditorViewModel.CaptionCase
        let maxWords: Int?
        let animation: TextAnimation?
        var automaticLayout = true
    }

    @concurrent
    static func build(_ input: Input) async throws -> [EditorViewModel.TextClipSpec] {
        try Task.checkCancellation()
        let groupId = UUID().uuidString
        var specs: [EditorViewModel.TextClipSpec] = []

        for target in input.targets {
            try Task.checkCancellation()
            let phrases = CaptionTranscriptMapper.phrases(
                for: target.clip,
                result: target.result,
                fps: input.fps,
                maxWords: input.maxWords,
                minDuration: AppTheme.Caption.minDisplayDuration,
                fits: { text in
                    if Task.isCancelled { return true }
                    return lineFits(
                        text,
                        style: input.style,
                        canvasWidth: input.canvasWidth,
                        canvasHeight: input.canvasHeight
                    )
                }
            )
            try Task.checkCancellation()
            guard !phrases.isEmpty else { continue }

            let cased = phrases.map {
                CaptionBuilder.Phrase(
                    text: input.textCase.apply($0.text),
                    start: $0.start,
                    end: $0.end,
                    words: $0.words
                )
            }
            var targetSpecs = CaptionBuilder.specs(
                for: cased,
                sourceClip: target.clip,
                trackIndex: 0,
                fps: input.fps,
                style: input.style,
                captionGroupId: groupId + "-" + (target.source?.placementId ?? target.clip.id),
                animation: input.animation,
                transformFor: { text in
                    guard !Task.isCancelled else { return nil }
                    return transform(
                        for: text,
                        style: input.style,
                        center: input.center,
                        canvasWidth: input.canvasWidth,
                        canvasHeight: input.canvasHeight
                    )
                }
            )
            if let source = target.source {
                for index in targetSpecs.indices {
                    targetSpecs[index].sourcePlacementId = source.placementId
                    targetSpecs[index].captionLayout = CaptionLayoutBinding(source: source, automatic: input.automaticLayout)
                }
            }
            specs.append(contentsOf: targetSpecs)
            try Task.checkCancellation()
        }
        return specs
    }

    static func lineFits(
        _ text: String,
        style: TextStyle,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Bool {
        ElasticSubtitleSegmenter.LayoutProfile(style: style, canvasWidth: canvasWidth, canvasHeight: canvasHeight).measure(text).fits
    }

    private static func transform(
        for text: String,
        style: TextStyle,
        center: CGPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Transform {
        let width = Double(canvasWidth)
        let height = Double(canvasHeight)
        let natural = TextLayout.naturalSize(
            content: text,
            style: style,
            maxWidth: CGFloat(width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
            canvasHeight: CGFloat(height)
        )
        return Transform(
            center: (Double(center.x), Double(center.y)),
            width: Double(natural.width) / width,
            height: Double(natural.height) / height
        )
    }
}
