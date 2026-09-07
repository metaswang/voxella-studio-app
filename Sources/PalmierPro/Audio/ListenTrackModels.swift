import Foundation

/// Role of a session audio file in the dual-track post-record design.
/// Master is ASR source-of-truth; listen is human playback/export.
enum SessionAudioTrackRole: String, Codable, Sendable {
    case master
    case listen
}

enum ListenEnhanceState: String, Codable, Sendable, Equatable {
    case idle
    case pending
    case ready
    case failed
    case skipped

    var isReady: Bool { self == .ready }
}

struct ListenTrackPaths: Equatable, Sendable {
    var masterURL: URL
    var listenURL: URL?

    /// Playback/export prefer listen when present; ASR always uses master.
    var playbackURL: URL { listenURL ?? masterURL }
    var asrURL: URL { masterURL }
}

enum ListenTrackLocator {
    /// Sidecar beside the master recording: `Recording-….listen.m4a`.
    static func sidecarURL(forMaster masterURL: URL) -> URL {
        let directory = masterURL.deletingLastPathComponent()
        let stem = masterURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem).listen.m4a")
    }

    static func cacheURL(forMaster masterURL: URL, cache: DiskCache = ListenTrackEnhancer.cache) -> URL {
        let tag = DiskCache.sizeMtimeTag(for: masterURL)
        return cache.directory.appendingPathComponent("\(tag)_listen.m4a")
    }

    /// Prefer an existing sidecar, then a size/mtime cache entry.
    static func existingListenURL(forMaster masterURL: URL) -> URL? {
        let fm = FileManager.default
        let sidecar = sidecarURL(forMaster: masterURL)
        if fm.fileExists(atPath: sidecar.path) { return sidecar }
        let cached = cacheURL(forMaster: masterURL)
        if fm.fileExists(atPath: cached.path) { return cached }
        return nil
    }
}
