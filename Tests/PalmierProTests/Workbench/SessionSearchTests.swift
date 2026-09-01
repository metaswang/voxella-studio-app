import Foundation
import Testing
@testable import PalmierPro

@Suite("Session search results")
@MainActor
struct SessionSearchResultTests {
    @Test func rejectsResultsWithNoDisplayableText() {
        let result = SessionSearchController.Result(
            id: UUID(),
            localSessionID: nil,
            remoteSessionID: UUID(),
            title: " \n",
            summary: " \t",
            snippet: nil,
            matchSource: "summary",
            updatedAt: nil,
            origin: .cloud,
            isTranscript: false
        )

        #expect(!result.isDisplayable)
    }

    @Test func rejectsSummaryMatchesWithoutSummaryOrSnippet() {
        let result = SessionSearchController.Result(
            id: UUID(),
            localSessionID: nil,
            remoteSessionID: UUID(),
            title: "手法学习体验分享.m4a",
            summary: nil,
            snippet: nil,
            matchSource: "summary",
            updatedAt: nil,
            origin: .cloud,
            isTranscript: false
        )

        #expect(!result.isDisplayable)
    }

    @Test func acceptsResultsWithAUsableSummaryOrSnippet() {
        let summaryResult = SessionSearchController.Result(
            id: UUID(),
            localSessionID: nil,
            remoteSessionID: UUID(),
            title: "",
            summary: "有内容",
            snippet: nil,
            matchSource: "summary",
            updatedAt: nil,
            origin: .cloud,
            isTranscript: false
        )
        let snippetResult = SessionSearchController.Result(
            id: UUID(),
            localSessionID: nil,
            remoteSessionID: UUID(),
            title: "",
            summary: nil,
            snippet: "有匹配片段",
            matchSource: "transcript",
            updatedAt: nil,
            origin: .cloud,
            isTranscript: true
        )

        #expect(summaryResult.isDisplayable)
        #expect(snippetResult.isDisplayable)
    }

    @Test func deduplicatesResultsByRemoteSessionID() {
        let remoteSessionID = UUID()
        let results = [
            SessionSearchController.Result(
                id: UUID(), localSessionID: UUID(), remoteSessionID: remoteSessionID,
                title: "First", summary: "First summary", snippet: nil,
                matchSource: "summary", updatedAt: nil, origin: .local, isTranscript: false
            ),
            SessionSearchController.Result(
                id: UUID(), localSessionID: nil, remoteSessionID: remoteSessionID,
                title: "Second", summary: "Second summary", snippet: nil,
                matchSource: "summary", updatedAt: nil, origin: .cloud, isTranscript: false
            ),
        ]

        #expect(SessionSearchController.Result.deduplicated(results).map(\.title) == ["First"])
    }
}

@Suite("Voxella API error messages")
struct VoxellaAPIErrorTests {
    @Test func extractsFastAPIErrorDetailInsteadOfShowingJSON() {
        let error = VoxellaAPIError.http(404, #"{"detail":"Not Found"}"#)

        #expect(error.localizedDescription == "Not Found")
    }

    @Test func extractsValidationMessageFromStructuredDetail() {
        let error = VoxellaAPIError.http(
            422,
            #"{"detail":[{"loc":["body","query"],"msg":"Field required","type":"missing"}]}"#
        )

        #expect(error.localizedDescription == "Field required")
    }
}
