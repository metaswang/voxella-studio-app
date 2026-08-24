import Foundation
import Testing
@testable import PalmierPro

@Suite("Meet Bot API models")
struct MeetBotModelsTests {
    @Test("Calendar status decodes rules and connection metadata")
    func calendarStatusDecodes() throws {
        let data = Data(
            """
            {
              "connected": true,
              "status": "connected",
              "google_email": "editor@example.com",
              "display_name": "Editor",
              "granted_scopes": ["https://www.googleapis.com/auth/calendar.events.readonly"],
              "rules": {
                "enabled": true,
                "calendar_id": "primary",
                "mode": "title_prefix",
                "title_prefix": "[Bot]",
                "bot_display_name": "VoxStudio Notetaker",
                "record_screen": false
              },
              "onboarding_completed": true,
              "last_calendar_sync_at": "2026-08-22T03:00:00Z",
              "last_error": null
            }
            """.utf8
        )

        let status = try JSONDecoder().decode(VoxellaGoogleCalendarStatus.self, from: data)

        #expect(status.connected)
        #expect(status.googleEmail == "editor@example.com")
        #expect(status.rules?.mode == "title_prefix")
        #expect(status.rules?.recordScreen == false)
    }

    @Test("Meeting action and Meet Bot responses preserve stable IDs")
    func actionResponsesDecode() throws {
        let meetingID = "11111111-1111-1111-1111-111111111111"
        let joinID = "22222222-2222-2222-2222-222222222222"
        let actionData = Data(
            "{\"meeting_id\":\"\(meetingID)\",\"status\":\"joining\",\"queued_job_id\":\"job-1\"}".utf8
        )
        let joinData = Data(
            """
            {
              "session_id": "\(joinID)",
              "provider": "microsoft",
              "meeting_url": "https://teams.microsoft.com/l/meetup-join/example",
              "title": "Weekly sync",
              "bot_name": "VoxStudio Notetaker",
              "attendee_bot_id": "attendee-1",
              "attendee_bot_state": "joining",
              "attendee_transcription_state": "queued",
              "created_at": "2026-08-22T03:00:00Z"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(VoxellaGoogleCalendarMeetingActionResponse.self, from: actionData)
        let join = try JSONDecoder().decode(VoxellaMeetBotJoinResponse.self, from: joinData)

        #expect(action.meetingID == UUID(uuidString: meetingID))
        #expect(action.queuedJobID == "job-1")
        #expect(join.sessionID == UUID(uuidString: joinID))
        #expect(join.provider == .microsoft)
    }
}
