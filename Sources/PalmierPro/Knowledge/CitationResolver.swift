import Foundation

enum CitationResolver {
    @MainActor
    static func open(_ ref: KnowledgeSourceRef) {
        guard let sessionID = ref.sessionUUID else { return }
        WorkbenchStore.shared.openSession(sessionID)
    }
}
