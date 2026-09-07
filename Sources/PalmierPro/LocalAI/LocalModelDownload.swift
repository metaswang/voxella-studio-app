import Foundation
#if BUNDLED_SPEECH
import HuggingFace
#endif

enum LocalModelDownload {
    #if BUNDLED_SPEECH
    static func client(session: URLSession = URLSession(configuration: .ephemeral)) -> HubClient {
        HubClient(
            session: session,
            host: URL(string: "https://huggingface.co")!,
            tokenProvider: .none,
            cache: nil
        )
    }

    @concurrent
    static func transferSnapshot(
        repository: Repo.ID,
        revision: String,
        to directory: URL,
        matching globs: [String],
        session: URLSession = URLSession(configuration: .ephemeral),
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            _ = try await client(session: session).downloadSnapshot(
                of: repository,
                kind: .model,
                to: directory,
                revision: revision,
                matching: globs,
                maxConcurrentDownloads: 4
            ) { progress in
                progressHandler(progress.fractionCompleted)
            }
        } catch HubCacheError.snapshotRequiresCacheOrDestination(let failedRepository)
            where failedRepository == repository.description {
            // Hub 0.9.0 throws after destination transfers; the installer still verifies every required artifact.
        }
        try Task.checkCancellation()
    }
    #endif

    static func message(for error: Error) -> String {
        #if BUNDLED_SPEECH
        if let httpError = error as? HTTPClientError {
            switch httpError {
            case .responseError(let response, _):
                switch response.statusCode {
                case 401, 403:
                    return "Model server denied access (HTTP \(response.statusCode)). This is separate from the model license accepted in the app."
                case 429:
                    return "Model server download limit reached (HTTP 429). Try again later."
                default:
                    return "Model server returned HTTP \(response.statusCode). Try downloading again later."
                }
            case .decodingError:
                return "Model server returned invalid metadata. Try downloading again later."
            default:
                return "The model download request failed. Try downloading again."
            }
        }
        #endif
        if let error = error as? URLError {
            return "Model download network error (\(error.code.rawValue)). Check your connection and try again."
        }
        if let error = error as? CocoaError {
            return "Unable to read or write model files (\(error.code.rawValue)). Check available disk space and permissions."
        }
        return error.localizedDescription
    }
}
