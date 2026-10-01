import CoreGraphics

struct RecordingWindowCandidate: Sendable {
    var id: CGWindowID
    var bundleIdentifier: String?
    var isOnScreen: Bool
    var layer: Int
    var frame: CGRect
}

enum RecordingWindowSelection {
    static func unambiguousWindowID(
        in windows: [RecordingWindowCandidate], bundleIdentifier: String
    ) -> CGWindowID? {
        let eligible = windows.filter {
            $0.bundleIdentifier == bundleIdentifier && $0.isOnScreen && $0.layer == 0
                && $0.frame.width >= 280 && $0.frame.height >= 180
        }
        // Size cannot distinguish a meeting from a chat or home window.
        return eligible.count == 1 ? eligible[0].id : nil
    }
}
