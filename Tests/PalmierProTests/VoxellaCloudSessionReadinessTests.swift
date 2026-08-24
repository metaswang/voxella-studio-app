import Foundation
import Testing
@testable import PalmierPro

@Suite("Voxella cloud session readiness")
struct VoxellaCloudSessionReadinessTests {
    @Test func sessionListDecodesWebMetadataAndPagination() throws {
        let response = try JSONDecoder().decode(VoxellaSessionListResponse.self, from: Data("""
        {
          "items": [{
            "session_id": "01a01c85-35aa-700b-85fd-31ba1e92fa20",
            "source_type": "upload",
            "status": "completed",
            "result_ready": true,
            "title": "Interview",
            "summary": "A summary",
            "source_language": "en",
            "duration_sec": 12.5,
            "created_at": "2026-08-24T03:04:05.123Z",
            "updated_at": "2026-08-24T03:05:05.123Z",
            "options": {"client_compute": "cloud"}
          }],
          "next_cursor": "cursor-2"
        }
        """.utf8))

        #expect(response.items.count == 1)
        #expect(response.items[0].sourceType == "upload")
        #expect(response.items[0].title == "Interview")
        #expect(response.items[0].durationSec == 12.5)
        #expect(response.items[0].createdAt != nil)
        #expect(response.nextCursor == "cursor-2")
    }

    @Test func sessionDetailDecodesTheWebResultReadinessFlag() throws {
        let detail = try JSONDecoder().decode(VoxellaSessionDetail.self, from: Data("""
        {
          "session_id": "01a01c85-35aa-700b-85fd-31ba1e92fa20",
          "status": "completed",
          "current_stage": "postprocess",
          "result_ready": false
        }
        """.utf8))

        #expect(detail.resultReady == false)
    }

    @Test func sessionDetailDecodesVideoAndNetVideoArtifacts() throws {
        let detail = try JSONDecoder().decode(VoxellaSessionDetail.self, from: Data("""
        {
          "session_id": "01a01c85-35aa-700b-85fd-31ba1e92fa20",
          "source_type": "meeting_record",
          "options": {"record_has_video": true},
          "artifacts": {
            "net_video_source_url": "https://www.ganjingworld.com/video/abc",
            "net_video_embed_url": "https://www.ganjingworld.com/zh-CN/embed/abc"
          }
        }
        """.utf8))

        #expect(detail.options?.recordHasVideo == true)
        #expect(detail.artifacts?["net_video_source_url"]?.stringValue == "https://www.ganjingworld.com/video/abc")
        #expect(detail.artifacts?["net_video_embed_url"]?.stringValue == "https://www.ganjingworld.com/zh-CN/embed/abc")
    }

    @Test func completedSessionWaitsUntilTheBackendMarksResultsReady() {
        #expect(!VoxellaSessionReadiness.isResultReady(
            status: "completed",
            currentStage: "postprocess",
            resultReady: false
        ))
    }

    @Test func completedSessionUsesResultReadyWhenTheBackendProvidesIt() {
        #expect(VoxellaSessionReadiness.isResultReady(
            status: "completed",
            currentStage: "transcribe",
            resultReady: true
        ))
    }

    @Test func readySessionEventStaysInProgressUntilItsArtifactsAreRead() {
        let progress = CloudTranscriptionTaskAccess.progress(
            for: VoxellaSSEEvent(event: "message", data: [
                "event": .string("session_state"),
                "status": .string("completed"),
                "stage": .string("postprocess"),
                "result_ready": .bool(true),
            ]),
            jobID: UUID()
        )

        #expect(progress.status == .processing)
    }

    @Test func chunkProgressCarriesFineGrainedTranscriptionCounts() {
        let progress = CloudTranscriptionTaskAccess.progress(
            for: VoxellaSSEEvent(event: "message", data: [
                "event": .string("transcribe_chunk_completed"),
                "stage": .string("transcribe"),
                "status": .string("processing"),
                "completed_chunks": .number(3),
                "total_chunks": .number(8),
                "progress": .number(0.625),
            ]),
            jobID: UUID()
        )

        #expect(progress.current == 3)
        #expect(progress.total == 8)
        #expect(progress.progress == 0.625)
        #expect(progress.stageProgress == 0.7)
    }

    @Test func chunkProgressMapperDeduplicatesSSEReconnectsAndUsesCloudCopy() async {
        let mapper = CloudProgressMapper(jobID: UUID())
        let event = VoxellaSSEEvent(event: "message", data: [
            "event": .string("transcribe_chunk_completed"),
            "stage": .string("transcribe"),
            "status": .string("processing"),
            "chunk_index": .number(1),
            "chunk_count": .number(4),
        ])

        _ = await mapper.progress(for: event)
        let progress = await mapper.progress(for: VoxellaSSEEvent(event: "message", data: [
            "event": .string("session_state"),
            "stage": .string("transcribe"),
            "status": .string("processing"),
            "completed_chunks": .number(0),
            "total_chunks": .number(4),
        ]))

        #expect(progress.current == 1)
        #expect(progress.total == 4)
        #expect(progress.message == "Transcribing in VoxStudio Cloud · 1 of 4 segments")
        #expect(abs(progress.progress - 0.45) < 0.0001)
    }

    @Test func chunkProgressMapperDoesNotJumpToLateTranscriptionBeforeCountsArrive() async {
        let mapper = CloudProgressMapper(jobID: UUID())
        let started = await mapper.progress(for: VoxellaSSEEvent(event: "message", data: [
            "event": .string("stage_started"),
            "stage": .string("transcribe"),
            "status": .string("processing"),
        ]))

        let firstChunk = await mapper.progress(for: VoxellaSSEEvent(event: "message", data: [
            "event": .string("transcribe_chunk_completed"),
            "stage": .string("transcribe"),
            "status": .string("processing"),
            "chunk_index": .number(0),
            "total_chunks": .number(4),
        ]))

        #expect(abs(started.progress - 0.35) < 0.0001)
        #expect(abs(firstChunk.progress - 0.45) < 0.0001)
    }

    @Test func stoppedCloudEventMapsToCancelled() {
        let progress = CloudTranscriptionTaskAccess.progress(
            for: VoxellaSSEEvent(event: "message", data: [
                "event": .string("session_state"),
                "status": .string("stopped"),
                "stage": .string("transcribe"),
            ]),
            jobID: UUID()
        )

        #expect(progress.status == .cancelled)
    }

    @Test func SSEEventReadsWorkflowRunAndChunkAliasesUsedByTheWebStream() {
        let event = VoxellaSSEEvent(event: "message", data: [
            "workflow_run_id": .string("run-42"),
            "chunk_count": .number(6),
            "chunk_index": .number(2),
        ])

        #expect(event.workflowRunID == "run-42")
        #expect(event.totalChunks == 6)
        #expect(event.chunkIndex == 2)
    }

    @Test func legacyCompletedPostprocessSessionIsReadyWithoutTheExplicitFlag() {
        #expect(VoxellaSessionReadiness.isResultReady(
            status: "completed",
            currentStage: "postprocess",
            resultReady: nil
        ))
    }

    @Test func completedDubSessionWaitsForTheBackendResultReadyFlag() throws {
        let detail = try JSONDecoder().decode(VoxellaSessionDetail.self, from: Data("""
        {
          "session_id": "01a01c85-35aa-700b-85fd-31ba1e92fa20",
          "status": "completed",
          "current_stage": "dub",
          "result_ready": false
        }
        """.utf8))

        #expect(!CloudDubTaskAccess.isReady(detail))
    }
}
