import Foundation

enum KnowledgeBodyReader {
    /// Preserve native numeric cursor semantics for ordinary segments; split large
    /// segments and retain canonical offsets. MCP uses bounded retrieval units.
    static func nativeParts(_ body: KnowledgeTranscriptMaterial) -> [KnowledgeBodyChunker.Chunk] {
        let original = body.text as NSString
        var offset = 0, parts: [KnowledgeBodyChunker.Chunk] = []
        for segment in body.segments {
            let range = original.range(of: segment.text, options: [], range: NSRange(location: offset, length: original.length - offset))
            guard range.location != NSNotFound else { continue }
            var pageOffset = range.location
            for page in KnowledgeToolExecutor.textPages(segment.text, limit: 8_000) {
                let lower = pageOffset
                let upper = lower + (page as NSString).length
                parts.append(.init(text: page, context: "", lower: lower, upper: upper,
                                   spans: body.spans.filter { $0.lower < upper && $0.upper > lower }))
                pageOffset = upper
            }
            offset = NSMaxRange(range)
        }
        return parts
    }
}
