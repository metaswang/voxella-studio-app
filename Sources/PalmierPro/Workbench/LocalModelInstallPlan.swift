import Foundation

struct LocalModelInstallPlan: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        var id: LocalModelID
        var title: String
        var purpose: String
        var byteSize: Int64
        var sizeLabel: String
        var license: String
        var requiresLicenseAcceptance: Bool
        var isInstalled: Bool
    }

    var asrModelID: LocalModelID
    var languageCode: String?
    var speakerCount: Int?
    var items: [Item]

    var missingItems: [Item] {
        items.filter { !$0.isInstalled }
    }

    var additionalBytes: Int64 {
        missingItems.reduce(0) { $0 + $1.byteSize }
    }

    var additionalDiskSpaceLabel: String {
        "Additional disk space for models: \(Self.formatBytes(additionalBytes))"
    }

    var requiresLicenseAcceptance: Bool {
        missingItems.contains { $0.requiresLicenseAcceptance }
    }

    static func requiredModelIDs(
        languageCode: String?,
        speakerCount: Int?,
        asrModelID: LocalModelID
    ) -> [LocalModelID] {
        requiredModelIDs(
            languageCode: languageCode,
            speakerCount: speakerCount,
            whisperFallbackModelID: asrModelID.isWhisperFallbackModel ? asrModelID : .whisperLargeV3Turbo8Bit
        )
    }

    static func requiredModelIDs(
        languageCode: String?,
        speakerCount: Int?,
        whisperFallbackModelID: LocalModelID
    ) -> [LocalModelID] {
        var required: [LocalModelID] = [.sileroVAD]
        if languageCode == nil {
            required.append(contentsOf: [
                .qwen3ASR17B8Bit,
                .parakeetTDT06Bv3,
                whisperFallbackModelID,
                .forcedAligner,
                .spokenLanguageID,
            ])
        } else {
            let engine = ASREngineLanguagePolicy.engine(forLanguageCode: languageCode)
            required.append(ASREngineLanguagePolicy.modelID(for: engine, whisperFallback: whisperFallbackModelID))
            if engine != .parakeet {
                required.append(.forcedAligner)
            }
        }
        if speakerCount != 1 {
            required.append(.sortformerDiarization)
        }
        var seen = Set<LocalModelID>()
        return required.filter { seen.insert($0).inserted }
    }

    static func plan(
        languageCode: String?,
        speakerCount: Int?,
        asrModelID: LocalModelID,
        catalog: [LocalModelDescriptor] = LocalModelManager.catalog,
        isInstalled: (LocalModelID) -> Bool
    ) -> LocalModelInstallPlan {
        let ids = requiredModelIDs(
            languageCode: languageCode,
            speakerCount: speakerCount,
            asrModelID: asrModelID
        )
        let descriptors = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let items = ids.compactMap { id -> Item? in
            guard let model = descriptors[id] else { return nil }
            return Item(
                id: model.id,
                title: model.title,
                purpose: model.purpose,
                byteSize: model.byteSize,
                sizeLabel: model.sizeLabel,
                license: model.license,
                requiresLicenseAcceptance: model.requiresLicenseAcceptance,
                isInstalled: isInstalled(model.id)
            )
        }
        return LocalModelInstallPlan(
            asrModelID: asrModelID,
            languageCode: languageCode,
            speakerCount: speakerCount,
            items: items
        )
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "~0 MB" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "~%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "~%.0f MB", mb.rounded())
        }
        return String(format: "~%.1f MB", mb)
    }
}

extension LocalModelManager {
    func installPlan(
        languageCode: String?,
        speakerCount: Int?,
        asrModelID: LocalModelID? = nil
    ) -> LocalModelInstallPlan {
        LocalModelInstallPlan.plan(
            languageCode: languageCode,
            speakerCount: speakerCount,
            asrModelID: asrModelID ?? activeASRModelID
        ) { id in
            state(for: id).isInstalled
        }
    }
}
