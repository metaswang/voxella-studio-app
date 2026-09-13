import Testing
@testable import PalmierPro

@Suite("Screen capture authorization")
@MainActor
struct RecordingScreenCaptureAuthorizationTests {
    @Test func authorizedCaptureDoesNotRequestAgain() throws {
        let authorization = RecordingScreenCaptureAuthorization(
            preflight: { true },
            request: { Issue.record("Already authorized"); return false }
        )
        try authorization.requireAccess()
    }

    @Test func pendingPermissionOffersSettingsWithoutRepeatedRequests() {
        var requests = 0
        let authorization = RecordingScreenCaptureAuthorization(
            preflight: { false }, request: { requests += 1; return false }
        )
        #expect(throws: RecordingError.screenCapturePermissionRequired) { try authorization.requireAccess() }
        #expect(throws: RecordingError.screenCapturePermissionRequired) { try authorization.requireAccess() }
        #expect(requests == 1)
        #expect(RecordingError.screenCapturePermissionRequired.permissionKind == .screenCapture)
    }

    @Test func permissionGrantedInSettingsAllowsRetryWithoutRelaunch() throws {
        var authorized = false
        let authorization = RecordingScreenCaptureAuthorization(
            preflight: { authorized }, request: { false }
        )
        #expect(throws: RecordingError.screenCapturePermissionRequired) { try authorization.requireAccess() }
        authorized = true
        try authorization.requireAccess()
    }

    @Test func permissionGrantedByTheRequestAllowsCapture() throws {
        let authorization = RecordingScreenCaptureAuthorization(preflight: { false }, request: { true })
        try authorization.requireAccess()
    }

    @Test func cancelledPreparationDoesNotRequestPermission() async {
        let authorization = RecordingScreenCaptureAuthorization(
            preflight: { false }, request: { Issue.record("Cancelled request"); return false }
        )
        let task = Task { try authorization.requireAccess() }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
