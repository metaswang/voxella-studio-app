import Foundation

// Feature plans reuse the same dependencies as task submission.
enum LocalPreparationFeature: String, CaseIterable, Identifiable, Codable, Sendable {
    case transcription
    case dubbing
    case search
    case knowledgeRanking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription: "Transcription & Captions"
        case .dubbing: "Dubbing"
        case .search: "Search by meaning"
        case .knowledgeRanking: "Knowledge ranking"
        }
    }

    var detail: String {
        switch self {
        case .transcription: "Turn recordings into editable text and timed captions on this Mac."
        case .dubbing: "Create a voiceover from your script on this Mac."
        case .search: "Search sessions, videos, and images by meaning or what appears on screen."
        case .knowledgeRanking: "Rank evidence for Knowledge Base answers on this Mac."
        }
    }

    var icon: String {
        switch self {
        case .transcription: "text.bubble"
        case .dubbing: "waveform"
        case .search: "sparkle.magnifyingglass"
        case .knowledgeRanking: "books.vertical"
        }
    }

    func requiredIDs(asrModelID: LocalModelID) -> [LocalModelID] {
        switch self {
        case .transcription:
            LocalModelInstallPlan.requiredModelIDs(languageCode: nil, speakerCount: nil, asrModelID: asrModelID)
        case .dubbing:
            LocalModelInstallPlan.dubPlan(modelID: .qwenTTS17B, isInstalled: { _ in false }).items.map(\.id)
        case .search:
            [SearchIndexConfig.modelID]
        case .knowledgeRanking:
            LocalModelInstallPlan.knowledgeQARequiredIDs(
                answerModelID: nil,
                includeReranker: true
            )
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

    init(ids: [LocalModelID], catalog: [LocalModelDescriptor], state: (LocalModelID) -> LocalModelDownloadState) {
        let descriptors = Dictionary(
            catalog.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let unique = Set(ids)
        var total = 0.0
        var completed = 0.0
        var remaining: Int64 = 0
        var ready = true
        var busy = false
        var failed = false
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
            case .failed: failed = true
            default: break
            }
        }
        isReady = ready
        isBusy = busy
        hasFailure = failed
        progress = total > 0 ? completed / total : (ready ? 1 : 0)
        remainingBytes = remaining
    }
}

extension LocalModelManager {
    func preparationStatus(for ids: [LocalModelID]) -> LocalPreparationStatus {
        LocalPreparationStatus(ids: ids, catalog: Self.catalog, state: state(for:))
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
        for id in LocalPreparationFeature.requiredIDs(for: features, asrModelID: activeASRModelID)
            where !state(for: id).isInstalled && !state(for: id).isBusy {
            download(id)
        }
    }
}
