import Foundation
import Testing
@testable import PalmierPro

@Suite("Summary template API contracts")
struct SummaryTemplateAPITests {
    @Test func templateUpdatePayloadMatchesCloudTemplateContract() {
        let payload = VoxellaSummaryTemplateUpdatePayload(
            name: "Decision Notes",
            description: "Capture decisions.",
            userEdition: "List decisions and owners."
        )

        let json = payload.jsonObject()
        #expect(json["name"] as? String == "Decision Notes")
        #expect(json["description"] as? String == "Capture decisions.")
        #expect(json["user_edition"] as? String == "List decisions and owners.")
        #expect(json["auto_extract_schema"] as? Bool == true)
    }

    @Test func sessionSummaryResponseDecodesCompletedTemplateRun() throws {
        let data = Data(
            """
            {
              "summary": {
                "id": "run-1",
                "session_id": "session-1",
                "template_id": "template-1",
                "trigger_source": "manual",
                "router_reason": null,
                "router_score": null,
                "output_markdown": "## Overview\\nA decision.",
                "status": "completed",
                "error_message": null,
                "created_at": "2026-08-22T00:00:00Z"
              },
              "template": {
                "id": "template-1",
                "scope": "private",
                "owner_user_id": "user-1",
                "name": "Decision Notes",
                "description": "Capture decisions.",
                "emoji_icon": "📝",
                "user_edition": "List decisions.",
                "language_mode": "asr",
                "is_fallback": false,
                "is_active": true,
                "version": 1,
                "editable": true,
                "is_copied_from_public": true,
                "source_template_id": "public-1"
              },
              "tag": null,
              "recommended_template_ids": ["template-1"]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(VoxellaSessionSummaryResponse.self, from: data)
        #expect(response.summary?.status == "completed")
        #expect(response.summary?.templateID == "template-1")
        #expect(response.summary?.outputMarkdown.contains("A decision.") == true)
        #expect(response.template?.scope == "private")
        #expect(response.recommendedTemplateIDs == ["template-1"])
    }
}
