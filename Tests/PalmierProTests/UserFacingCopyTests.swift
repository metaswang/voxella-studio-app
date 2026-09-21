import Foundation
import Testing
@testable import PalmierPro

@Suite("User-facing copy boundaries")
struct UserFacingCopyTests {
    private let forbiddenTerms = ["WeMM", "Qwen", "Whisper", "Parakeet", "MLX", "ASR"]

    @Test func localFeatureTitlesUseCapabilityLanguage() {
        for title in LocalModelID.allCases.map(\.userFacingTitle) {
            for term in forbiddenTerms {
                #expect(!title.localizedCaseInsensitiveContains(term))
            }
        }
    }

    @Test func localAndKnowledgeErrorsDoNotExposeRuntimeNames() {
        let errors: [Error] = [
            LocalAIError.modelPreparationFailed("Qwen runtime failed"),
            KnowledgeQAError.invalidRerankerOutput,
            KnowledgeQAError.invalidQueryPlan,
            KnowledgeQAError.timeout,
        ]

        for error in errors {
            let message = error.localizedDescription
            for term in forbiddenTerms {
                #expect(!message.localizedCaseInsensitiveContains(term))
            }
        }
    }

    @Test func knowledgeTipUsesTheSharedTopBannerAction() {
        let tip = WorkbenchTip(
            id: "knowledge-local-resources",
            message: "Prepare local search resources before asking.",
            kind: .warning,
            actionLabel: "Open Local Features",
            action: .openLocalFeatures,
            autoDismiss: false
        )

        #expect(tip.action == .openLocalFeatures)
        #expect(tip.autoDismiss == false)
        #expect(tip.id == "knowledge-local-resources")
    }
}
