import Foundation

enum SearchIndexConfig {
    static let enabledDefaultsKey = "searchIndexEnabled"
    static let modelID = LocalModelID.weMMEmbedding2B4Bit
    static let embeddingDimension = 256
    static let model = LocalModelManager.catalog.first { $0.id == modelID }!
    static let visualSpec = VisualEmbedder.Spec(
        model: "\(model.repository)@\(model.revision)",
        version: 1,
        embeddingDim: embeddingDimension
    )

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }
}
