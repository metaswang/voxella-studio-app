import Foundation
import Testing
@testable import PalmierPro

@Suite("Engine coverage posterior replay")
struct ASREngineCoverageReplayTests {
    private static let fixturePath = ProcessInfo.processInfo.environment["VOXSTUDIO_COVERAGE_FIXTURE"]

    @Test(.enabled(if: fixturePath != nil))
    func replayRecordedSessionPosteriors() throws {
        let url = URL(fileURLWithPath: try #require(Self.fixturePath))
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: url))
        var outputs: [Output] = []
        for input in inputs {
            let evidence = input.windows.map { window in
                ASRLanguageEvidence(
                    window: .init(slices: window.slices.map { .init(start: $0[0], end: $0[1]) }),
                    posterior: window.posterior
                )
            }
            let route = ASREngineRouter.decide(evidence: evidence)
            let vote = try #require(route.languageVote)
            outputs.append(.init(
                id: input.id, previousEngine: input.newEngine, engine: route.engine.rawValue,
                reason: route.reason.rawValue, qwenCoverage: route.scores.qwen,
                parakeetCoverage: route.scores.parakeet, uncovered: route.scores.whisper,
                windowCoverage: vote.windowPosteriors.map {
                    let score = ASREngineRouter.scores(from: $0)
                    return ["qwen": score.qwen, "parakeet": score.parakeet, "uncovered": score.whisper]
                }
            ))
            #expect(route.whisperHint == nil)
            if ["session-01", "session-06", "session-08", "session-09"].contains(input.id) {
                #expect(route.engine == .whisper)
            }
            if input.id == "session-07" { #expect(route.engine == .parakeet) }
            if ["session-14", "session-15", "mixed-en-zh"].contains(input.id) {
                #expect(route.engine == .qwen)
            }
            print("COVERAGE_REPLAY \(input.id) \(input.newEngine)->\(route.engine.rawValue) \(route.reason.rawValue)")
        }
        if let path = ProcessInfo.processInfo.environment["VOXSTUDIO_COVERAGE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(outputs).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private struct Input: Decodable {
        let id: String
        let newEngine: String
        let windows: [Window]
    }
    private struct Window: Decodable {
        let slices: [[Double]]
        let posterior: [String: Float]
    }
    private struct Output: Encodable {
        let id: String
        let previousEngine: String
        let engine: String
        let reason: String
        let qwenCoverage: Float
        let parakeetCoverage: Float
        let uncovered: Float
        let windowCoverage: [[String: Float]]
    }
}
