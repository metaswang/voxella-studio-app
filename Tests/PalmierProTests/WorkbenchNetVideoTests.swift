import Testing
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
}
