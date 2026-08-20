import Foundation
import Testing
@testable import PalmierPro

@Suite("Cloud task authentication")
struct CloudTaskAccessAuthenticationTests {
    @Test func transcriptionReportsCloudAccessFailureBeforeUploading() async {
        let calls = CallCounter()
        let access = CloudTranscriptionTaskAccess(
            prepareCloudAccess: {
                await calls.increment()
                return .failed("Sign in required")
            }
        )
        let jobID = UUID()
        let request = TranscriptionTaskRequest(
            jobID: jobID,
            sourceURL: URL(fileURLWithPath: "/tmp/input.m4a"),
            originalFilename: "input.m4a",
            mimeType: "audio/m4a",
            sizeBytes: nil,
            durationHintSec: 1,
            options: TranscriptionProcessingOptions(languageCode: "en", customTitle: nil),
            placement: TaskPlacement(storage: .local, compute: .cloud),
            flowRequest: MediaFlowRequest(id: jobID, input: .media(URL(fileURLWithPath: "/tmp/input.m4a")), steps: []),
            remoteSessionID: nil,
            shouldReuseRemoteSession: false
        )

        var events: [MediaJobProgressEvent] = []
        for await event in access.events(for: request) {
            if case .progress(let progress) = event {
                events.append(progress)
            }
        }

        #expect(await calls.value == 1)
        #expect(events.count == 1)
        #expect(events.first?.status == .failed)
        #expect(events.first?.step == "cloud_access")
        #expect(events.first?.message == "Sign in required")
    }

    @Test func dubbingReportsCloudAccessFailureBeforeCreatingASession() async {
        let calls = CallCounter()
        let access = CloudDubTaskAccess(
            prepareCloudAccess: {
                await calls.increment()
                return .failed("Sign in required")
            }
        )
        let request = DubTaskRequest(
            jobID: UUID(),
            script: "Hello",
            segments: [DubSegmentPayload(index: 0, text: "Hello")],
            language: "en",
            model: .medium,
            referenceVoiceID: nil,
            reference: nil,
            speakerReferences: [:],
            segmentReferences: [:],
            referenceAudioID: nil,
            referenceAudioR2Key: nil,
            referenceText: "",
            placement: TaskPlacement(storage: .local, compute: .cloud),
            remoteSessionID: nil,
            generationID: "generation",
            clientRequestID: "request",
            title: nil,
            cacheURL: URL(fileURLWithPath: "/tmp/output.m4a"),
            hasSubtitleModel: false
        )

        var events: [DubTaskEvent] = []
        for await event in access.events(for: request) {
            events.append(event)
        }

        #expect(await calls.value == 1)
        guard case .failure(let message, _) = events.first else {
            Issue.record("Expected a cloud access failure before the dub session starts")
            return
        }
        #expect(message == "Sign in required")
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
