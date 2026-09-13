import Foundation
import Observation

@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case features
        case selection
        case preparation
    }

    static let completionKey = "voxstudio.onboarding.completed.v1"
    static let selectionKey = "voxstudio.onboarding.localFeatures.v1"
    static let shared = OnboardingState()

    private let defaults: UserDefaults
    private(set) var isComplete: Bool
    private(set) var step: Step = .features
    var selectedFeatures: Set<LocalPreparationFeature> {
        didSet { defaults.set(selectedFeatures.map(\.rawValue).sorted(), forKey: Self.selectionKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.bool(forKey: Self.completionKey)
        selectedFeatures = Set((defaults.stringArray(forKey: Self.selectionKey) ?? []).compactMap(LocalPreparationFeature.init(rawValue:)))
    }

    func showSelection() { step = .selection }
    func showFeatures() { step = .features }

    func prepare(startDownloads: (Set<LocalPreparationFeature>) -> Void) {
        guard step == .selection else { return }
        step = .preparation
        startDownloads(selectedFeatures)
    }

    func complete() {
        guard step == .preparation else { return }
        defaults.set(true, forKey: Self.completionKey)
        isComplete = true
    }

    func replay() {
        step = .features
        isComplete = false
    }
}
