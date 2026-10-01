import Foundation

struct FeatureWallMotion {
    static func position(index: Int, count: Int, pitch: Double, elapsed: Double, speed: Double, offset: Double) -> Double {
        guard count > 0, pitch.isFinite, pitch > 0, elapsed.isFinite, speed.isFinite, offset.isFinite else { return 0 }
        let cycle = Double(count) * pitch
        let movement = elapsed * speed
        guard cycle.isFinite, movement.isFinite else { return 0 }
        let position = Double(index) * pitch + offset + movement
        let wrapped = position.truncatingRemainder(dividingBy: cycle)
        return (wrapped < 0 ? wrapped + cycle : wrapped) - pitch
    }

    static func scale(y: Double, center: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        let emphasis = prominence(y: y, center: center, radius: AppTheme.Onboarding.focalRadius)
        return AppTheme.Onboarding.cardRestingScale
            + (AppTheme.Onboarding.cardFocusedScale - AppTheme.Onboarding.cardRestingScale) * emphasis
    }

    static func prominence(y: Double, center: Double, radius: Double) -> Double {
        guard y.isFinite, center.isFinite, radius.isFinite, radius > 0 else { return 0 }
        let distance = min(abs(y - center) / radius, 1)
        return (1 - distance * distance) * (1 - distance * distance)
    }
}
