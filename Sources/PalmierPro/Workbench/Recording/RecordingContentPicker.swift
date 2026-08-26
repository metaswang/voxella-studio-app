import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

final class RecordingContentPicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    static let shared = RecordingContentPicker()

    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    func pick(style: SCShareableContentStyle) async throws -> SCContentFilter {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCContentFilter, Error>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.captureFailed("Recording picker unavailable."))
                    return
                }
                if self.continuation != nil {
                    self.resume(.failure(RecordingError.cancelled))
                }
                self.continuation = continuation
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = style == .window ? .singleWindow : .singleDisplay
                if let bundleID = Bundle.main.bundleIdentifier {
                    configuration.excludedBundleIDs = [bundleID]
                }
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                picker.present(using: style)
            }
        }
    }

    func cancelPending() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishPicker(SCContentSharingPicker.shared)
            self.resume(.failure(RecordingError.cancelled))
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishPicker(picker)
            self.resume(.success(filter))
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishPicker(picker)
            self.resume(.failure(RecordingError.cancelled))
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishPicker(SCContentSharingPicker.shared)
            self.resume(.failure(RecordingError.captureFailed(error.localizedDescription)))
        }
    }

    private func finishPicker(_ picker: SCContentSharingPicker) {
        picker.remove(self)
        picker.isActive = false
    }

    private func resume(_ result: Result<SCContentFilter, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let filter):
            nonisolated(unsafe) let captured = filter
            continuation.resume(returning: captured)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
