import AVFoundation

extension AVVideoComposition {
    func palmierMutableCopy() -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = customVideoCompositorClass
        composition.frameDuration = frameDuration
        composition.sourceTrackIDForFrameTiming = sourceTrackIDForFrameTiming
        composition.renderSize = renderSize
        composition.renderScale = renderScale
        composition.instructions = instructions
        composition.animationTool = animationTool
        composition.sourceSampleDataTrackIDs = sourceSampleDataTrackIDs
        return composition
    }
}
