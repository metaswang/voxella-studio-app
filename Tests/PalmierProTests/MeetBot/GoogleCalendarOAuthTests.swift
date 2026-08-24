import Foundation
import Testing
@testable import PalmierPro

@Suite("Google Calendar OAuth")
struct GoogleCalendarOAuthTests {
    @Test("Callback parsing verifies state and extracts the authorization code")
    func callbackParsing() throws {
        let callback = URL(string: "voxstudio://oauth/google-calendar?code=one-time-code&state=expected")!

        let parsed = try GoogleCalendarOAuthConnector.parseCallback(callback, expectedState: "expected")

        #expect(parsed.code == "one-time-code")
        #expect(parsed.state == "expected")
    }

    @Test("Callback parsing rejects a mismatched state")
    func stateMismatch() {
        let callback = URL(string: "voxstudio://oauth/google-calendar?code=one-time-code&state=wrong")!

        #expect(throws: VoxellaCalendarOAuthError.stateMismatch) {
            _ = try GoogleCalendarOAuthConnector.parseCallback(callback, expectedState: "expected")
        }
    }

    @Test("Provider denial becomes a cancellation")
    func accessDenied() {
        let callback = URL(string: "voxstudio://oauth/google-calendar?state=expected&error=access_denied")!

        #expect(throws: VoxellaCalendarOAuthError.cancelled) {
            _ = try GoogleCalendarOAuthConnector.parseCallback(callback, expectedState: "expected")
        }
    }
}
