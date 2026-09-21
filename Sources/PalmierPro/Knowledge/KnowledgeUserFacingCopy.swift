import Foundation

enum KnowledgeUserFacingCopy {
    static func message(for error: Error) -> String {
        if let error = error as? KnowledgeQAError, let message = error.errorDescription {
            return message
        }
        if error is CancellationError {
            return "This request was cancelled."
        }
        return "Knowledge search is temporarily unavailable. Try again."
    }
}
