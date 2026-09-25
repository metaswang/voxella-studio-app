import Testing
import Foundation
import Network
@testable import PalmierPro

@Suite("Workbench net video")
struct WorkbenchNetVideoTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ?t=12", "dQw4w9WgXcQ"),
        ("https://www.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("youtube.com/live/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ])
    func extractsVideoID(url: String, expected: String) {
        #expect(YouTubeURL.videoID(from: url) == expected)
    }

    @Test(arguments: [
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=short",
        "not a URL",
    ])
    func rejectsUnsupportedURLs(url: String) {
        #expect(YouTubeURL.videoID(from: url) == nil)
    }

    @Test
    func choosesDefaultVideoResolution() {
        #expect(YouTubeAudioImporter.defaultVideoResolution(from: [1440, 1080, 720]) == 1080)
        #expect(YouTubeAudioImporter.defaultVideoResolution(from: [720, 480]) == 720)
        #expect(YouTubeAudioImporter.defaultVideoResolution(from: [2160, 1440]) == 1440)
    }

    @Test
    func downloadReportsTransferredBytes() async throws {
        let payload = Data(repeating: 0x5a, count: 512 * 1024)
        let queue = DispatchQueue(label: "net-video-progress-test")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let recorder = NetVideoProgressRecorder()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await YouTubeAudioImporter.download(
            URL(string: "http://127.0.0.1:\(port.rawValue)/video")!,
            bitrate: 128_000,
            to: destination,
            media: "video"
        ) { update in
            if case .downloading(let snapshot) = update {
                recorder.record(snapshot)
            }
        }

        #expect((try Data(contentsOf: destination)) == payload)
        #expect(recorder.snapshots.contains { $0.bytesWritten > 0 })
        #expect(recorder.snapshots.contains { ($0.fraction ?? 0) > 0 })
    }
}

private final class NetVideoProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [YouTubeAudioDownloadProgress] = []

    var snapshots: [YouTubeAudioDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ snapshot: YouTubeAudioDownloadProgress) {
        lock.lock()
        values.append(snapshot)
        lock.unlock()
    }
}
