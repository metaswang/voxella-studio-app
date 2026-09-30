import Foundation
import Testing
@testable import PalmierPro

struct MCPKnowledgeToolsTests {
    @Test func publishesEveryChatbotOperationWithoutCollisions() {
        let names = MCPKnowledgeTools.tools.map(\.name)
        #expect(Set(KnowledgeToolRegistry.allTools.map(\.name)).isSubset(of: Set(names)))
        #expect(names.contains("knowledge.ask"))
        let combined = names + ToolDefinitions.mcpServer.map { $0.name.rawValue }
        #expect(Set(combined).count == combined.count)
    }

    @Test @MainActor func rejectsMalformedArgumentsBeforeAccessingServices() async {
        for (name, args) in [
            ("knowledge.ask", ["query": " "]),
            ("knowledge.search", ["query": "test", "session_ids": ["bad-id"]]),
            ("knowledge.ask", ["query": "test", "session_ids": []]),
            ("session.get_segments", ["session_id": UUID().uuidString, "limit": -1]),
            ("knowledge.ask", ["query": "test", "allow_cloud": "false"]),
            ("session.get_timeline", ["session_id": UUID().uuidString, "bucket_seconds": 0]),
        ] as [(String, [String: Any])] {
            #expect(await MCPKnowledgeTools.execute(name: name, args: args).isError)
        }
    }

    @Test @MainActor func controlsWorkWithoutAnEditor() async throws {
        let result = await MCPKnowledgeTools.execute(name: "ask_clarification", args: ["question": "Which meeting?"])
        #expect(!result.isError)
        guard case let .text(text) = result.content.first else { Issue.record("Missing result"); return }
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(json["status"] == "clarification")
        #expect(json["question"] == "Which meeting?")
    }

    @Test @MainActor func qaUsesSharedPipelineAndReturnsClarification() async throws {
        var service = KnowledgeQAService()
        service.dependencies.planner = { query, history, _, _ in
            #expect(query == "What about that?")
            #expect(history.last?.content == "Discuss the roadmap")
            return KnowledgeQueryPlan(standaloneQuery: query, searchQuery: query, answerConstraints: [], clarificationQuestion: "Which roadmap?")
        }
        let result = await MCPKnowledgeTools.execute(name: "knowledge.ask", args: [
            "query": "What about that?",
            "history": [["role": "user", "content": "Discuss the roadmap"]],
        ], qaService: service)
        #expect(!result.isError)
        guard case let .text(text) = result.content.first else { Issue.record("Missing result"); return }
        #expect(text.contains("Which roadmap?"))
        #expect(text.contains("clarification"))
    }


    @Test @MainActor func qaReturnsAnswerAndSourceCitations() async throws {
        let hit = SessionSearchHit(
            sessionID: UUID(), title: "Roadmap", unitID: 1, kind: .transcriptChunk,
            start: 0, end: 10, speakerLabels: ["Alice"], text: "Launch in October",
            score: 1, matchSource: "test", snippet: "Launch in October", cueIDs: [],
            hasVideo: false, language: "en", quoteSpan: nil
        )
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        service.dependencies = KnowledgeQAExecutionDependencies(
            planner: { query, _, _, _ in .fallback(for: query) },
            hybridRecall: { _, _ in [hit] },
            graphRecall: { _, _ in [] },
            reranker: { _, chunks in chunks.map { _ in 1.0 } },
            answer: { _, _, _ in "Launch in October." }
        )
        let result = await MCPKnowledgeTools.execute(
            name: "knowledge.ask", args: ["query": "When is launch?"], qaService: service,
            visibleSessionIDs: [hit.sessionID]
        )
        #expect(!result.isError)
        guard case let .text(text) = result.content.first else { Issue.record("Missing result"); return }
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "completed")
        #expect((json["answer"] as? String)?.contains("October") == true)
        let citations = try #require(json["citations"] as? [[String: Any]])
        #expect(citations.first?["sourceID"] as? String == hit.sessionID.uuidString)
    }

    @Test @MainActor func unknownSessionCannotBeReadDirectly() async {
        let result = await MCPKnowledgeTools.execute(name: "session.get_summary", args: ["session_id": UUID().uuidString])
        #expect(result.isError)
    }
}
