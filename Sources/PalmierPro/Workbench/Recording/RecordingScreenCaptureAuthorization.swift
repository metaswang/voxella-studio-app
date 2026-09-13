import CoreGraphics

@MainActor
final class RecordingScreenCaptureAuthorization {
    static let shared = RecordingScreenCaptureAuthorization()

    private let preflight: () -> Bool
    private let request: () -> Bool
    private var didRequest = false

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }
    ) {
        self.preflight = preflight
        self.request = request
    }

    func requireAccess() throws {
        try Task.checkCancellation()
        guard !preflight() else { return }
        if !didRequest {
            didRequest = true
            if request() { return }
        }
        guard preflight() else { throw RecordingError.screenCapturePermissionRequired }
    }
}
