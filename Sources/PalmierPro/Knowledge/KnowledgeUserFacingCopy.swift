import Foundation

enum KnowledgeUserFacingCopy {
    static func message(for error: Error) -> String {
        if let error = error as? KnowledgeQAError, let message = error.errorDescription {
            return message
        }
        if let error = error as? KnowledgeNativeRunError { return error.localizedDescription }
        if let error = error as? AgentClientTransportError { return error.localizedDescription }
        if error is CancellationError {
            return "This request was cancelled."
        }
        return "Knowledge search is temporarily unavailable. Try again."
    }
}
