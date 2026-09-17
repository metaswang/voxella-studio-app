import Testing
import Foundation
@testable import PalmierPro

/// Test knowledge tool executor helper functions
struct KnowledgeToolExecutorTests {
    @Test("Timeline bucketing with empty hits")
    func testTimelineBucketingEmpty() {
        let buckets = KnowledgeToolExecutor.bucketTimeline(hits: [], bucketSeconds: 60)
        #expect(buckets.isEmpty)
    }
    
    @Test("Timeline bucketing with single bucket")
    func testTimelineBucketingSingleBucket() {
        let hits = [
            SessionSearchHit(
                sessionID: UUID(),
                title: "Test",
                unitID: 1,
                kind: .transcriptChunk,
                start: 10,
                end: 20,
                speakerLabels: [],
                text: "First",
                score: 1.0,
                matchSource: "test",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
            SessionSearchHit(
                sessionID: UUID(),
                title: "Test",
                unitID: 2,
                kind: .transcriptChunk,
                start: 30,
                end: 40,
                speakerLabels: [],
                text: "Second",
                score: 1.0,
                matchSource: "test",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
        ]
        
        let buckets = KnowledgeToolExecutor.bucketTimeline(hits: hits, bucketSeconds: 60)
        #expect(buckets.count == 1)
        
        guard let bucket = buckets.first else {
            Issue.record("Expected one bucket")
            return
        }
        
        #expect(bucket["start"] as? Double == 0.0)
        #expect(bucket["end"] as? Double == 60.0)
        #expect(bucket["segment_count"] as? Int == 2)
    }
    
    @Test("Timeline bucketing with multiple buckets")
    func testTimelineBucketingMultipleBuckets() {
        let hits = [
            SessionSearchHit(
                sessionID: UUID(),
                title: "Test",
                unitID: 1,
                kind: .transcriptChunk,
                start: 10,
                end: 20,
                speakerLabels: [],
                text: "First",
                score: 1.0,
                matchSource: "test",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
            SessionSearchHit(
                sessionID: UUID(),
                title: "Test",
                unitID: 2,
                kind: .transcriptChunk,
                start: 65,
                end: 75,
                speakerLabels: [],
                text: "Second",
                score: 1.0,
                matchSource: "test",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
        ]
        
        let buckets = KnowledgeToolExecutor.bucketTimeline(hits: hits, bucketSeconds: 60)
        #expect(buckets.count == 2)
        
        if buckets.count >= 2 {
            #expect(buckets[0]["start"] as? Double == 0.0)
            #expect(buckets[0]["end"] as? Double == 60.0)
            #expect(buckets[0]["segment_count"] as? Int == 1)
            
            #expect(buckets[1]["start"] as? Double == 60.0)
            #expect(buckets[1]["end"] as? Double == 120.0)
            #expect(buckets[1]["segment_count"] as? Int == 1)
        }
    }

    @Test
    func knowledgeSearchUsesSharedRetrievalAndGraph() async throws {
        let graphCalls = PlannerCallBox()
        let hit = searchHit(unitID: 11, text: "graph-backed transcript")
        let executor = KnowledgeToolExecutor(
            scope: .all,
            originFilter: nil,
            retrievalService: KnowledgeRetrievalService(
                dependencies: KnowledgeQAExecutionDependencies(
                    hybridRecall: { _, _ in [] },
                    graphRecall: { _, _ in
                        graphCalls.count += 1
                        return [hit]
                    },
                    reranker: { _, chunks in chunks.map { _ in 0.9 } }
                )
            )
        )
        let result = try await executor.execute(
            toolName: "knowledge.search",
            arguments: ["query": "张三 方案 原因", "limit": 8]
        )
        guard case let .success(data) = result else {
            Issue.record("expected search success")
            return
        }
        #expect(graphCalls.count == 1)
        #expect(data["hits"] as? Int == 1)
        let citations = data["citations"] as? [[String: Any]]
        #expect(citations?.count == 1)
        #expect(citations?.first?["chunk_index"] as? Int == 11)
        #expect(citations?.first?["speaker"] as? String == "Alice")
        #expect((citations?.first?["source_type"] as? String) == "sessionTranscript")
    }

    @Test
    func sessionSearchSegmentsAlsoRunsGraphAndReturnsCitations() async throws {
        let graphCalls = PlannerCallBox()
        let sessionID = UUID()
        let executor = KnowledgeToolExecutor(
            scope: .all,
            originFilter: nil,
            retrievalService: KnowledgeRetrievalService(
                dependencies: KnowledgeQAExecutionDependencies(
                    hybridRecall: { _, _ in [] },
                    graphRecall: { _, filter in
                        graphCalls.count += 1
                        #expect(filter.sessionIDs?.contains(sessionID) == true || filter.sessionID == sessionID)
                        return [searchHit(sessionID: sessionID, unitID: 21, text: "segment hit")]
                    },
                    reranker: { _, chunks in chunks.map { _ in 0.9 } }
                )
            )
        )
        let result = try await executor.execute(
            toolName: "session.search_segments",
            arguments: ["session_ids": [sessionID.uuidString], "query": "budget"]
        )
        guard case let .success(data) = result else {
            Issue.record("expected segment search success")
            return
        }
        #expect(graphCalls.count == 1)
        #expect(data["hit_count"] as? Int == 1)
        #expect((data["citations"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func sessionScopedSearchPassesSessionFilterToGraph() async throws {
        let sessionID = UUID()
        let graphCalls = PlannerCallBox()
        let service = KnowledgeRetrievalService(
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { _, _ in [] },
                graphRecall: { _, filter in
                    graphCalls.count += 1
                    #expect(filter.sessionID == sessionID)
                    return [searchHit(sessionID: sessionID, unitID: 5, text: "scoped graph hit")]
                },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(
            KnowledgeRetrievalRequest(
                query: "theme",
                scope: .session(sessionID),
                originFilter: nil,
                resultLimit: 3,
                requestID: UUID(),
                includeCatalog: false,
                retrievalPath: .agent
            )
        )
        #expect(graphCalls.count == 1)
        #expect(result.hits.first?.sessionID == sessionID)
    }

    @Test
    func deterministicReadsDoNotStartGraph() async throws {
        let graphCalls = PlannerCallBox()
        let sessionID = UUID()
        let executor = KnowledgeToolExecutor(
            scope: .all,
            originFilter: nil,
            retrievalService: KnowledgeRetrievalService(
                dependencies: KnowledgeQAExecutionDependencies(
                    graphRecall: { _, _ in
                        graphCalls.count += 1
                        return []
                    }
                )
            )
        )
        do {
            _ = try await executor.execute(
                toolName: "session.get_segments",
                arguments: ["session_id": sessionID.uuidString]
            )
            _ = try await executor.execute(
                toolName: "session.get_timeline",
                arguments: ["session_id": sessionID.uuidString]
            )
        } catch {
            // The live session index may be empty in unit tests; Graph must still stay idle.
        }
        #expect(graphCalls.count == 0)
    }

    @Test
    func sessionIDsCannotEscapeCurrentScope() async throws {
        let allowed = UUID()
        let blocked = UUID()
        let hybridCalls = PlannerCallBox()
        let executor = KnowledgeToolExecutor(
            scope: .session(allowed),
            originFilter: nil,
            retrievalService: KnowledgeRetrievalService(
                dependencies: KnowledgeQAExecutionDependencies(
                    hybridRecall: { _, _ in
                        hybridCalls.count += 1
                        return [searchHit(unitID: 1, text: "should not run")]
                    },
                    graphRecall: { _, _ in [] },
                    reranker: { _, chunks in chunks.map { _ in 0.9 } }
                )
            )
        )
        let result = try await executor.execute(
            toolName: "knowledge.search",
            arguments: ["query": "secret", "session_ids": [blocked.uuidString]]
        )
        guard case let .success(data) = result else {
            Issue.record("expected empty success")
            return
        }
        #expect(data["hits"] as? Int == 0)
        #expect(hybridCalls.count == 0)
    }

    private func searchHit(
        sessionID: UUID = UUID(),
        unitID: Int,
        text: String
    ) -> SessionSearchHit {
        SessionSearchHit(
            sessionID: sessionID,
            title: "Session",
            unitID: unitID,
            kind: .transcriptChunk,
            start: 12,
            end: 18,
            speakerLabels: ["Alice"],
            text: text,
            score: 1,
            matchSource: "graph",
            snippet: text,
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil
        )
    }
}
