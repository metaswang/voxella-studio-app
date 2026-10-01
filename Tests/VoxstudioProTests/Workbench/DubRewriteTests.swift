import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Dub AI rewrite")
struct DubRewriteTests {
    @Test func replacementRequiresUnchangedSelectedDub() {
        var job = WorkbenchDubJob()
        job.segments = [DubSegmentPayload(index: 0, text: "Original")]
        let snapshot = DubRewriteSnapshot(job: job)
        #expect(snapshot.matches(job, selectedID: job.id))
        #expect(!snapshot.matches(job, selectedID: UUID()))
        #expect(!snapshot.matches(job, selectedID: nil))
        job.segments?[0].text = "User edited this"
        #expect(!snapshot.matches(job, selectedID: job.id))
    }

    @Test func removedOrRenumberedSegmentsInvalidateReplacement() {
        var job = WorkbenchDubJob()
        job.segments = [DubSegmentPayload(index: 0, text: "First"), DubSegmentPayload(index: 1, text: "Second")]
        let snapshot = DubRewriteSnapshot(job: job)
        job.segments = [DubSegmentPayload(index: 0, text: "Second")]
        #expect(!snapshot.matches(job, selectedID: job.id))
    }

    @Test func sendsOriginalScriptAndUserInstructionToAI() async throws {
        let client = RewriteClient(response: "  A shorter script.\n")
        let request = DubRewriteRequest(script: "An original, longer script.", instruction: "Make it shorter", language: "en")
        let result = try await request.complete(using: client)
        #expect(result == "A shorter script.")
        let payload = try #require(await client.payload)
        #expect(payload["script"] == request.script)
        #expect(payload["editing_instruction"] == request.instruction)
        #expect(payload["language"] == "en")
    }

    @Test(arguments: [("", "Shorten"), ("Script", " \n")])
    func rejectsEmptyInputs(script: String, instruction: String) async {
        let client = RewriteClient(response: "Revised")
        await #expect(throws: DubRewriteError.self) {
            try await DubRewriteRequest(script: script, instruction: instruction, language: "en").complete(using: client)
        }
        #expect(await client.payload == nil)
    }

    @Test func rejectsEmptyAIResponse() async {
        await #expect(throws: DubRewriteError.self) {
            try await DubRewriteRequest(script: "Script", instruction: "Shorten", language: "en")
                .complete(using: RewriteClient(response: " \n"))
        }
    }

    @Test func cancelledCompletionCannotProduceReplacement() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DubRewriteRequest(script: "Script", instruction: "Shorten", language: "en")
                .complete(using: RewriteClient(response: "Revised"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor RewriteClient: LLMTextClient {
    let response: String
    private(set) var payload: [String: String]?
    init(response: String) { self.response = response }
    func complete(system: String, user: String) async throws -> String {
        payload = try JSONDecoder().decode([String: String].self, from: Data(user.utf8))
        return response
    }
}
