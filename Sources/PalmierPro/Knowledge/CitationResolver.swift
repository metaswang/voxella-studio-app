import Foundation

enum CitationResolver {
    @MainActor
    static func open(_ ref: KnowledgeSourceRef, in controller: KnowledgeBaseController) {
        guard let sessionID = ref.sessionUUID else { return }
        controller.openTranscript(
            for: sessionID,
            target: KnowledgeTranscriptTarget(source: ref)
        )
    }
}
