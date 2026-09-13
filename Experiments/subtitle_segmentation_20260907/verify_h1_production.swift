import Foundation

@main
struct VerifyH1Production {
    struct Fixture: Decodable {
        var id: String
        var text: String
        var advice: [String]
        var dense: Bool
        var minimum: Int
        var preferred: Int
        var maximum: Int
    }
    struct Row: Encodable {
        var id: String
        var lines: [String]
        var offsets: [Int]
        var matchedLines: Int
        var skippedLines: Int
        var resyncs: Int
        var exact: Bool
        var forcedBoundaries: Int
        var mode: String
    }
    static func main() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var rows: [Row] = []
        for fixture in fixtures {
            let result = try SubtitleBoundaryOptimizer.optimize(
                sourceText: fixture.text, proposedLines: fixture.advice, dense: fixture.dense,
                minimum: fixture.minimum, preferred: fixture.preferred, maximum: fixture.maximum
            )
            precondition(result.lines.allSatisfy {
                (fixture.dense ? $0.filter { !$0.isWhitespace }.count : $0.count) <= fixture.maximum
            })
            let projection = result.projection
            rows.append(Row(id: fixture.id, lines: result.lines, offsets: projection.offsets,
                            matchedLines: projection.matchedLines, skippedLines: projection.skippedLines,
                            resyncs: projection.resyncs, exact: projection.exact,
                            forcedBoundaries: result.forcedBoundaries, mode: result.mode))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Swift H1 replay passed for \(rows.count) fixtures.")
    }
}
