import Foundation
import Observation

@Observable
@MainActor
final class SpeechInputController {
    enum State: Equatable {
        case idle
        case recognizing(fraction: Double, message: String)
        case recognized
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var partialText = ""
    typealias Recognizer = @Sendable (URL, @escaping @Sendable (LocalSpeechProgress) -> Void) async throws -> SpeechInputResult

    private let recognize: Recognizer
    private var task: Task<Void, Never>?
    private var attemptID: UUID?

    init(
        purpose: SpeechInputPurpose = .referenceAudio,
        recognize: Recognizer? = nil
    ) {
        self.recognize = recognize ?? { url, progress in
            try await LocalSpeechPipeline.shared.recognizeInput(
                sourceURL: url,
                purpose: purpose,
                progressUpdate: progress
            )
        }
    }

    var isRecognizing: Bool {
        if case .recognizing = state { return true }
        return false
    }

    func start(
        sourceURL: URL,
        onRecognized: @escaping @MainActor (SpeechInputResult) -> Void
    ) {
        guard !isRecognizing else { return }
        let currentAttemptID = UUID()
        attemptID = currentAttemptID
        partialText = ""
        state = .recognizing(fraction: 0, message: "Preparing local recognition…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await recognize(
                    sourceURL, { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.attemptID == currentAttemptID else { return }
                            if let text = update.partialText { self.partialText = text }
                            self.state = .recognizing(
                                fraction: update.fraction,
                                message: update.message
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard attemptID == currentAttemptID else { return }
                state = .recognized
                attemptID = nil
                task = nil
                onRecognized(result)
            } catch is CancellationError {
                guard attemptID == currentAttemptID else { return }
                state = .idle
                attemptID = nil
                task = nil
            } catch {
                guard attemptID == currentAttemptID else { return }
                state = .failed(error.localizedDescription)
                attemptID = nil
                task = nil
            }
        }
    }

    @discardableResult
    func cancel(resetState: Bool = true) -> Task<Void, Never>? {
        let pending = task
        task?.cancel()
        task = nil
        attemptID = nil
        partialText = ""
        if resetState { state = .idle }
        return pending
    }
}
