import Foundation

// Feature plans reuse the same dependencies as task submission.
enum LocalPreparationFeature: String, CaseIterable, Identifiable, Codable, Sendable {
    case transcription
    case speakerIdentification
    case dubbing
    case search
    case knowledgeRanking
    case audioEnhancement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription: "Transcription & Captions"
        case .speakerIdentification: "Speaker identification"
        case .dubbing: "Dubbing"
        case .search: "Search by meaning"
        case .knowledgeRanking: "Knowledge ranking"
        case .audioEnhancement: "Audio enhancement"
        }
    }

    var detail: String {
        switch self {
        case .transcription: "Turn recordings into editable text and timed captions on this Mac."
        case .speakerIdentification: "Distinguish speakers in a conversation on this Mac."
        case .dubbing: "Create a voiceover from your script on this Mac."
        case .search: "Search sessions, videos, and images by meaning or what appears on screen."
        case .knowledgeRanking: "Rank evidence for Knowledge Base answers on this Mac."
        case .audioEnhancement: "Reduce background noise in audio on this Mac."
        }
    }

    var icon: String {
        switch self {
        case .transcription: "text.bubble"
        case .speakerIdentification: "person.2.wave.2"
        case .dubbing: "waveform"
        case .search: "sparkle.magnifyingglass"
        case .knowledgeRanking: "books.vertical"
        case .audioEnhancement: "waveform.badge.mic"
        }
    }

    func requiredIDs(asrModelID: LocalModelID) -> [LocalModelID] {
        switch self {
        case .transcription:
            LocalModelInstallPlan.requiredModelIDs(languageCode: nil, speakerCount: nil, asrModelID: asrModelID)
        case .speakerIdentification:
            [.sortformerDiarization]
        case .dubbing:
            LocalModelInstallPlan.dubPlan(modelID: .qwenTTS17B, isInstalled: { _ in false }).items.map(\.id)
        case .search:
            [SearchIndexConfig.modelID]
        case .knowledgeRanking:
            LocalModelInstallPlan.knowledgeQARequiredIDs(
                answerModelID: nil,
                includeReranker: true
            )
        case .audioEnhancement:
            [.mossFormer2SE]
        }
    }

    static func removableIDs(
        for feature: Self,
        asrModelID: LocalModelID,
        isInstalled: (LocalModelID) -> Bool
    ) -> [LocalModelID] {
        let shared = Set(allCases.filter { $0 != feature }.flatMap { other in
            let ids = other.requiredIDs(asrModelID: asrModelID)
            return ids.allSatisfy(isInstalled) ? ids : []
        })
        return feature.requiredIDs(asrModelID: asrModelID).filter {
            isInstalled($0) && $0 != asrModelID && !shared.contains($0)
        }
    }

    static func requiredIDs(for features: Set<Self>, asrModelID: LocalModelID) -> [LocalModelID] {
        var seen = Set<LocalModelID>()
        return allCases.filter { features.contains($0) }
            .flatMap { $0.requiredIDs(asrModelID: asrModelID) }
            .filter { seen.insert($0).inserted }
    }
}

struct LocalPreparationStatus: Equatable {
    let isReady: Bool
    let isBusy: Bool
    let hasFailure: Bool
    let progress: Double
    let remainingBytes: Int64
    let completedBytes: Int64
    let totalBytes: Int64
    let currentModelID: LocalModelID?
    let currentModelTitle: String?
    let currentModelProgress: Double
    let currentModelState: LocalModelDownloadState?
    let currentMessage: String?

    init(ids: [LocalModelID], catalog: [LocalModelDescriptor], state: (LocalModelID) -> LocalModelDownloadState) {
        let descriptors = Dictionary(
            catalog.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var seen = Set<LocalModelID>()
        let unique = ids.filter { seen.insert($0).inserted }
        var total = 0.0
        var completed = 0.0
        var remaining: Int64 = 0
        var ready = true
        var busy = false
        var failed = false
        var current: (id: LocalModelID, state: LocalModelDownloadState, rank: Int)?
        for id in unique {
            let value = state(id)
            let bytes = max(descriptors[id]?.byteSize ?? 0, 0)
            total += Double(bytes)
            ready = ready && value.isInstalled
            busy = busy || value.isBusy
            if !value.isInstalled { remaining += bytes }
            switch value {
            case .installed: completed += Double(bytes)
            case .downloading(let fraction, _):
                completed += Double(bytes) * (fraction.isFinite ? min(max(fraction, 0), 1) : 0)
            case .verifying(let fraction, _):
                completed += Double(bytes) * (fraction.isFinite ? min(max(fraction, 0), 1) : 0)
            case .failed: failed = true
            default: break
            }

            guard !value.isInstalled else { continue }
            let rank: Int = switch value {
            case .downloading: 0
            case .verifying: 0
            case .queued: 1
            case .failed: 2
            case .notInstalled: 3
            case .installed: 4
            }
            if current == nil || rank < current!.rank {
                current = (id, value, rank)
            }
        }
        isReady = ready
        isBusy = busy
        hasFailure = failed
        progress = total > 0 ? completed / total : (ready ? 1 : 0)
        remainingBytes = remaining
        completedBytes = Int64(max(0, completed.rounded()))
        totalBytes = Int64(max(0, total.rounded()))
        currentModelID = current?.id
        currentModelTitle = current.map { $0.id.userFacingTitle }
        currentModelState = current?.state
        currentModelProgress = switch current?.state {
        case .installed: 1
        case .downloading(let fraction, _), .verifying(let fraction, _): fraction.isFinite ? min(max(fraction, 0), 1) : 0
        default: 0
        }
        currentMessage = switch current?.state {
        case .downloading(_, let message), .verifying(_, let message), .failed(let message): message
        case .queued: "Queued for download"
        case .notInstalled: "Waiting to start download"
        case .installed, nil: nil
        }
    }

    var userFacingMessage: String {
        guard !isReady else { return "Speech features are ready" }
        guard let title = currentModelTitle else {
            return "Preparing speech features…"
        }
        let byteProgress = "\(LocalModelInstallPlan.formatBytes(completedBytes)) of \(LocalModelInstallPlan.formatBytes(totalBytes))"
        switch currentModelState {
        case .downloading:
            return "Preparing \(title.lowercased())… \(byteProgress)"
        case .verifying:
            return "Verifying \(title.lowercased())… \(byteProgress)"
        case .queued:
            return "Waiting to prepare \(title.lowercased())… \(byteProgress)"
        case .failed:
            return "Couldn’t prepare \(title.lowercased()). Retry to continue."
        case .notInstalled, nil:
            return "Preparing \(title.lowercased())… \(byteProgress)"
        case .installed:
            return "Preparing speech features… \(byteProgress)"
        }
    }
}

extension LocalModelManager {
    func preparationStatus(for ids: [LocalModelID]) -> LocalPreparationStatus {
        LocalPreparationStatus(ids: ids, catalog: Self.catalog, state: state(for:))
    }

    func preparationStatus(for feature: LocalPreparationFeature) -> LocalPreparationStatus {
        LocalPreparationStatus(
            ids: feature.requiredIDs(asrModelID: activeASRModelID), catalog: Self.catalog
        ) { id in
            let value = state(for: id)
            return cancelledFeatures.contains(feature) && !value.isInstalled ? .notInstalled : value
        }
    }

    func removableResources(for feature: LocalPreparationFeature) -> [LocalModelID] {
        LocalPreparationFeature.removableIDs(for: feature, asrModelID: activeASRModelID) {
            state(for: $0).isInstalled
        }
    }

    func removeFeatureResources(_ feature: LocalPreparationFeature) {
        for id in removableResources(for: feature) { remove(id) }
    }

    func prepareFeatures(_ features: Set<LocalPreparationFeature>) {
        for feature in LocalPreparationFeature.allCases where features.contains(feature) {
            beginPreparingFeature(feature)
            for id in feature.requiredIDs(asrModelID: activeASRModelID) where !state(for: id).isInstalled {
                download(id, demand: .feature(feature))
            }
        }
    }
}
