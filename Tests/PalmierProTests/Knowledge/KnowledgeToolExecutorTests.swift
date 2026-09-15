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
}
