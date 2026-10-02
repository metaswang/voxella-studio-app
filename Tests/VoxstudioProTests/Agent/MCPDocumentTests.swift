import Foundation
import Testing
@testable import VoxstudioPro

@Suite("MCP document editing")
struct MCPDocumentTests {
    @Test(arguments: ["srt", "vtt"])
    func unchangedBytesAndExtendedBlocks(_ format: String) throws {
        let header = format == "vtt" ? "WEBVTT\r\n\r\nNOTE 中文备注\r\nkeep me\r\n\r\nSTYLE\r\n::cue { color: lime; }\r\n\r\n" : ""
        let timing = format == "vtt" ? "00:00:01.000 --> 00:00:02.000 align:start" : "00:00:01,000 --> 00:00:02,000"
        let original = Data([0xef,0xbb,0xbf]) + Data((header + "1\r\n" + timing + "\r\n<b>你好，世界！</b>\r\n第二行\r\n").utf8)
        let decoded = try MCPDocumentCodec.decode(original)
        #expect(try MCPDocumentCodec.encode(MCPDocumentCodec.normalized(decoded.text), original: original) == original)
        let cues = try MCPDocumentCodec.cues(decoded.text, format: format)
        #expect(cues.count == 1)
        #expect(cues[0].text == "<b>你好，世界！</b>\n第二行")
        #expect(cues[0].start_ms == 1000)
    }
    @Test func malformedSubtitleDoesNotDropBlocks() {
        #expect(throws: (any Error).self) { try MCPDocumentCodec.cues("1\n00:00:01,000 --> 00:00:02,000\nvalid\n\n2\ninvalid\ntext", format: "srt") }
    }
    @Test func jsonSchemaAndOverlaps() throws {
        let cues = [MCPDocumentCue(id: 1,start_ms: 0,end_ms: 2000,text: "一",speaker: nil), .init(id: 2,start_ms: 1000,end_ms: 3000,text: "二",speaker: nil)]
        let data = try MCPDocumentCodec.export(cues, format: "json", language: "zh")
        #expect(try MCPDocumentCodec.cues(String(decoding: data, as: UTF8.self), format: "json") == cues)
        try MCPDocumentCodec.validate("{\"arbitrary\": true}", format: "json")
        #expect(throws: (any Error).self) { try MCPDocumentCodec.cues("{\"arbitrary\": true}", format: "json") }
    }
    @Test func durableCommitConflictAndIdempotency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDocumentStore(root: root)
        let original = try await store.create(name: "测试.txt", bytes: Data("original\r\n".utf8), owner: "a")
        let saved = try await store.commit(original.id, owner: "a", expected: original.revision, text: "new\n", requestID: "one")
        #expect(saved.bytes == Data("new\r\n".utf8))
        #expect(try await store.commit(original.id, owner: "a", expected: original.revision, text: "new\n", requestID: "one").revision == saved.revision)
        do { _ = try await store.commit(original.id, owner: "a", expected: original.revision, text: "lost", requestID: "two"); Issue.record("Stale revision overwritten") } catch {}
        do { _ = try await store.read(original.id, owner: "b"); Issue.record("Owner isolation failed") } catch {}
        let reopened = MCPDocumentStore(root: root)
        #expect(try await reopened.read(original.id, owner: "a").revision == saved.revision)
        let fileRoot = root.appendingPathComponent("file"); try Data().write(to: fileRoot)
        do { _ = try await MCPDocumentStore(root: fileRoot).create(name: "fail.txt", bytes: Data("x".utf8), owner: nil); Issue.record("Write failure claimed success") } catch {}
    }
}
