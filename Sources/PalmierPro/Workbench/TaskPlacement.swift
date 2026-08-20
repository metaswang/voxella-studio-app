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

struct TranscriptionPlacement: Equatable, Codable, Sendable {
    var storage: TaskStorageDestination
    var compute: TaskComputeDestination

    static let localDefault = TranscriptionPlacement(storage: .local, compute: .local)

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

enum RemotePersistenceScope: String, Codable, Sendable {
    case persistent
    case temporary
}

enum RemoteClientCompute: String, Codable, Sendable {
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

enum CloudAccessPreparation: Equatable, Sendable {
    case ready
    case cancelled
    case failed(String)
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
        var next = current
        next.storage = .local
        next.compute = .local
        return next
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

    static func summaryLine(storage: TaskStorageDestination, compute: TaskComputeDestination) -> String {
        "\(keepSessionTitle): \(storage.label)  ·  \(processWithTitle): \(compute.label)"
    }
}

struct CloudTranscriptionQuota: Equatable, Sendable {
    static let uploadUsageType = "upload_transcribe"
    static let translationUsageType = "translation"

    let durationSeconds: Double
    let estimatedCredits: Double
    let availableCredits: Double
    let creditsPerSecond: Double
    let canAfford: Bool

    init(
        durationSeconds: Double,
        estimatedCredits: Double,
        availableCredits: Double,
        creditsPerSecond: Double,
        canAfford: Bool
    ) {
        self.durationSeconds = max(0, durationSeconds)
        self.estimatedCredits = max(0, estimatedCredits)
        self.availableCredits = max(0, availableCredits)
        self.creditsPerSecond = max(0, creditsPerSecond)
        self.canAfford = canAfford
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
