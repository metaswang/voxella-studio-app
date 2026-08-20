import Foundation

enum TaskStorageDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "This Mac"
        case .cloud: "VoxStudio Cloud"
        }
    }
}

enum TaskComputeDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "This Mac"
        case .cloud: "VoxStudio Cloud"
        }
    }
}

struct TaskPlacement: Equatable, Codable, Sendable {
    var storage: TaskStorageDestination
    var compute: TaskComputeDestination

    static let localDefault = TaskPlacement(storage: .local, compute: .local)

    var needsAuthentication: Bool {
        storage == .cloud || compute == .cloud
    }

    var remotePersistenceScope: RemotePersistenceScope? {
        switch (storage, compute) {
        case (.local, .local):
            nil
        case (.local, .cloud):
            .temporary
        case (.cloud, _):
            .persistent
        }
    }
}

/// Compatibility name retained for the existing transcription flow.
typealias TranscriptionPlacement = TaskPlacement

enum RemotePersistenceScope: String, Codable, Equatable, Sendable {
    case persistent
    case temporary
}

enum RemoteClientCompute: String, Codable, Equatable, Sendable {
    case local
    case cloud
}

enum CloudResultSyncDestination: Equatable, Sendable {
    case updateExisting
    case createNew
}

enum CloudResultSyncPolicy {
    static func destination(for existingClientCompute: RemoteClientCompute?) -> CloudResultSyncDestination {
        existingClientCompute == .local ? .updateExisting : .createNew
    }
}

/// Upload-transcribe options aligned with voxella-web `ProcessingOptions`.
/// Location-neutral: storage and compute are chosen separately on `TranscriptionSubmission`.
struct TranscriptionProcessingOptions: Equatable, Sendable {
    var languageCode: String?
    /// Optional user title for a single-file import; blank means auto-generate after transcription.
    var customTitle: String?
    var speakerCount: SpeakerCountOption = .auto
    var enableTranslation = false
    var targetLanguageCode: String?
    var useLLMSubtitleProcessing: Bool? = nil
    var clipStartMs: Int?
    var clipEndMs: Int?

    var normalizedTargetLanguageCode: String? {
        guard enableTranslation else { return nil }
        let trimmed = targetLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var clipRangeSeconds: ClosedRange<Double>? {
        guard let startMs = clipStartMs, let endMs = clipEndMs, endMs > startMs else { return nil }
        return Double(startMs) / 1000 ... Double(endMs) / 1000
    }
}

typealias LocalProcessingOptions = TranscriptionProcessingOptions

struct TranscriptionSubmission: Equatable, Sendable {
    var options: TranscriptionProcessingOptions
    var placement: TranscriptionPlacement = .localDefault
}

struct DubSubmission: Equatable, Sendable {
    var placement: TaskPlacement
}

enum CloudAccessPreparation: Equatable, Sendable {
    case ready
    case cancelled
    case failed(String)
}

enum CloudTaskAccessDefaults {
    static func prepare() async -> CloudAccessPreparation {
        await AccountService.shared.ensureCloudAccess()
    }
}

enum TranscriptionPlacementRouter {
    static func requiresAuthentication(_ placement: TranscriptionPlacement) -> Bool {
        placement.needsAuthentication
    }

    static func shouldStartCloudPipeline(_ placement: TranscriptionPlacement) -> Bool {
        placement.compute == .cloud
    }

    static func shouldRunLocalPipeline(_ placement: TranscriptionPlacement) -> Bool {
        placement.compute == .local
    }

    static func shouldSyncLocalResults(_ placement: TranscriptionPlacement) -> Bool {
        placement.storage == .cloud && placement.compute == .local
    }

    static func shouldConfirmEphemeralDelete(_ placement: TranscriptionPlacement) -> Bool {
        placement.storage == .local && placement.compute == .cloud
    }

    static func shouldReturnToSessionAfterCancellation(
        _ placement: TranscriptionPlacement,
        hasRemoteSession: Bool
    ) -> Bool {
        placement.storage == .cloud && (placement.compute == .cloud || hasRemoteSession)
    }

    static func shouldPreserveRemoteSessionAfterCancellation(_ placement: TranscriptionPlacement) -> Bool {
        placement.storage == .cloud
    }

    static func remotePersistenceScope(_ placement: TranscriptionPlacement) -> RemotePersistenceScope? {
        placement.remotePersistenceScope
    }

    static func remoteClientCompute(_ placement: TranscriptionPlacement) -> RemoteClientCompute? {
        guard placement.needsAuthentication else { return nil }
        return placement.compute == .local ? .local : .cloud
    }

    static func placement(afterCancelledAuthentication current: TranscriptionPlacement) -> TranscriptionPlacement {
        current
    }
}

struct TaskPlacementCopy {
    static let keepSessionTitle = "Keep this session in VoxStudio Cloud"
    static let processWithTitle = "Process with VoxStudio Cloud"
    static let thisMac = "This Mac"
    static let voxStudioCloud = "VoxStudio Cloud"

    static func storageTooltip(for destination: TaskStorageDestination) -> String {
        switch destination {
        case .local: "Session stored on This Mac"
        case .cloud: "Session stored in VoxStudio Cloud"
        }
    }

    static func computeTooltip(for destination: TaskComputeDestination) -> String {
        switch destination {
        case .local: "Processing on This Mac"
        case .cloud: "Processing in VoxStudio Cloud"
        }
    }

    static let checkingCloudAccount = "Checking your VoxStudio account…"
    static let signingIn = "Signing in…"
    static let cloudAccountRequired = "Sign in once to use VoxStudio Cloud. Your account stays connected on this Mac."
    static let freeCloudUpgrade = "Cloud processing starts without local model downloads. Upgrade to Pro for more cloud time and a lower rate."
    static let cloudCreditsUnavailable = "Cloud usage could not be checked. Try again before submitting."
    static let cloudDubProcessDetail = "Generate dubbed audio without downloading local voice models."

    static func summaryLine(storage: TaskStorageDestination, compute: TaskComputeDestination) -> String {
        "\(keepSessionTitle): \(storage.label)  ·  \(processWithTitle): \(compute.label)"
    }
}

struct CloudUsageEstimate: Equatable, Sendable {
    static let uploadUsageType = "upload_transcribe"
    static let translationUsageType = "translation"

    let durationSeconds: Double
    let estimatedCredits: Double
    let availableCredits: Double
    let creditsPerSecond: Double
    let canAfford: Bool
    let maxDurationWithRemainingQuota: Double?

    init(
        durationSeconds: Double,
        estimatedCredits: Double,
        availableCredits: Double,
        creditsPerSecond: Double,
        canAfford: Bool,
        maxDurationWithRemainingQuota: Double? = nil
    ) {
        self.durationSeconds = max(0, durationSeconds)
        self.estimatedCredits = max(0, estimatedCredits)
        self.availableCredits = max(0, availableCredits)
        self.creditsPerSecond = max(0, creditsPerSecond)
        self.canAfford = canAfford
        self.maxDurationWithRemainingQuota = maxDurationWithRemainingQuota.map { max(0, $0) }
    }

    init(
        mediaDurationSeconds: Double,
        estimatedCostPoints: Double,
        remainingCreditsPoints: Double,
        maxDurationSecWithRemainingQuota: Double?,
        canAfford: Bool
    ) {
        let duration = max(0, mediaDurationSeconds)
        let cost = max(0, estimatedCostPoints)
        let remaining = max(0, remainingCreditsPoints)
        let rate = duration > 0 ? cost / duration : 0
        self.init(
            durationSeconds: duration,
            estimatedCredits: cost,
            availableCredits: remaining,
            creditsPerSecond: rate,
            canAfford: canAfford,
            maxDurationWithRemainingQuota: maxDurationSecWithRemainingQuota
        )
    }

    var mediaDurationSeconds: Double { durationSeconds }
    var estimatedCostPoints: Double { estimatedCredits }
    var remainingCreditsPoints: Double { availableCredits }
    var maxDurationSecWithRemainingQuota: Double? {
        maxDurationWithRemainingQuota ?? affordableMediaSeconds
    }

    var affordableMediaSeconds: Double? {
        guard creditsPerSecond > 0 else { return nil }
        return availableCredits / creditsPerSecond
    }

    var remainingMediaSecondsAfterSubmission: Double? {
        guard creditsPerSecond > 0 else { return nil }
        return max(0, availableCredits - estimatedCredits) / creditsPerSecond
    }

    var shouldShowLowBalanceNotice: Bool {
        guard canAfford,
              let remainingMediaSecondsAfterSubmission
        else {
            return false
        }
        let threshold = max(15 * 60, durationSeconds * 2)
        return remainingMediaSecondsAfterSubmission <= threshold
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 {
            return "less than 1 min"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

/// Existing transcription call sites continue to use the generalized estimate type.
typealias CloudTranscriptionQuota = CloudUsageEstimate

enum CloudTranscriptionNoticeKind: Equatable, Sendable {
    case signIn
    case freeUpgrade
    case insufficientCredits
    case lowBalance(remainingSeconds: Double)
    case none
}

enum CloudTranscriptionNoticePolicy {
    static func notice(
        isSignedIn: Bool,
        isPaid: Bool,
        quota: CloudTranscriptionQuota?
    ) -> CloudTranscriptionNoticeKind {
        guard isSignedIn else { return .signIn }
        guard let quota else {
            return isPaid ? .none : .freeUpgrade
        }
        guard quota.canAfford else { return .insufficientCredits }
        guard isPaid else { return .freeUpgrade }
        if quota.shouldShowLowBalanceNotice,
           let remaining = quota.remainingMediaSecondsAfterSubmission {
            return .lowBalance(remainingSeconds: remaining)
        }
        return .none
    }
}

enum CloudCreditNotice: Equatable, Sendable {
    case signIn
    case checking
    case failed
    case freeUpgrade
    case insufficient(mediaDuration: Double, availableDuration: Double)
    case lowBalance(remainingSeconds: Double)
    case none

    var message: String? {
        switch self {
        case .signIn:
            return TaskPlacementCopy.cloudAccountRequired
        case .checking:
            return TaskPlacementCopy.checkingCloudAccount
        case .failed:
            return TaskPlacementCopy.cloudCreditsUnavailable
        case .freeUpgrade:
            return TaskPlacementCopy.freeCloudUpgrade
        case .insufficient(let mediaDuration, let availableDuration):
            return "This media is \(CloudUsageEstimate.formatDuration(mediaDuration)), but your balance covers about \(CloudUsageEstimate.formatDuration(availableDuration)). Upgrade to Pro or add credits to continue in the Cloud."
        case .lowBalance(let remainingSeconds):
            return "After this media, your balance covers about \(CloudUsageEstimate.formatDuration(remainingSeconds)) more of this cloud workflow."
        case .none:
            return nil
        }
    }
}

enum CloudCreditNoticePolicy {
    static func notice(
        isSignedIn: Bool,
        isPaid: Bool,
        estimate: CloudUsageEstimate?,
        estimateFailed: Bool = false
    ) -> CloudCreditNotice {
        guard isSignedIn else { return .signIn }
        guard !estimateFailed else { return .failed }
        guard let estimate else { return .checking }
        guard estimate.canAfford else {
            return .insufficient(
                mediaDuration: estimate.durationSeconds,
                availableDuration: estimate.maxDurationSecWithRemainingQuota ?? 0
            )
        }
        guard isPaid else { return .freeUpgrade }
        guard estimate.shouldShowLowBalanceNotice,
              let remaining = estimate.remainingMediaSecondsAfterSubmission else {
            return .none
        }
        return .lowBalance(remainingSeconds: remaining)
    }
}
