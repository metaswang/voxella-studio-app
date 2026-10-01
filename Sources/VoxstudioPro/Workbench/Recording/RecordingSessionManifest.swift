import AVFoundation
import Foundation

struct RecordingJournalSegment: Codable, Equatable, Sendable {
    var index: Int
    var path: String
    var globalStart: Double
    var localDuration: Double?
    var status: String
    var didAppendMedia: Bool
    var didAppendVideo: Bool
    var didAppendMicrophone: Bool
    var didAppendSystemAudio: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

struct RecordingRecoveredSession: Equatable, Sendable {
    var sessionID: String
    var urls: [URL]
    var status: String
    var manifest: RecordingSessionManifest
}

struct RecordingSessionManifest: Codable, Equatable, Sendable {
    var sessionID: String
    var startedAt: Date
    var outputPath: String
    var mode: String
    var backend: String
    var deviceID: String?
    var status: String
    var segments: [RecordingJournalSegment]?
    var includesVideo: Bool?
    var audioTrackCount: Int?
    var warnings: [String]?
    var journalPath: String?
    var trimPendingPath: String?
    var trimDiscardPaths: [String]?
    var trimStart: Double?
    var trimEnd: Double?
    var stopReason: String?

    static let capturing = "capturing"
    static let inProgress = "inProgress"
    static let pendingFinalize = "pendingFinalize"
    static let rawSaved = "rawSaved"
    static let pendingExport = "pendingExport"
    static let pendingReview = "pendingReview"
    static let pendingTrim = "pendingTrim"
    static let pendingImport = "pendingImport"
    static let registered = "registered"
    static let completed = "completed"
    static let failed = "failed"

    static let recoverableStatuses: Set<String> = [
        capturing, inProgress, pendingFinalize, rawSaved, pendingExport, pendingImport, pendingReview, pendingTrim, failed,
    ]

    var manifestURL: URL {
        journalPath.map { URL(fileURLWithPath: $0) } ?? Self.manifestURL(for: URL(fileURLWithPath: outputPath))
    }

    var outputURL: URL { URL(fileURLWithPath: outputPath) }

    static func manifestURL(for outputURL: URL) -> URL {
        outputURL.appendingPathExtension("recording.json")
    }

    static func uniqueOutputURL(directory: URL, capturesVideo: Bool, audioTrackCount: Int) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let ext: String
        if audioTrackCount >= 2 {
            ext = "mov"
        } else {
            ext = capturesVideo ? "mp4" : "m4a"
        }
        return directory.appendingPathComponent("Recording-\(stamp)-\(token).\(ext)")
    }

    @discardableResult
    static func write(_ manifest: RecordingSessionManifest) -> Bool {
        do {
            try writeThrowing(manifest)
            return true
        } catch {
            Log.recording.warning("recording manifest write failed error=\(Log.detail(error))")
            return false
        }
    }

    static func writeThrowing(_ manifest: RecordingSessionManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifest.manifestURL, options: .atomic)
    }

    static func remove(for outputURL: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: outputURL))
    }

    static func markRegistered(sessionID: String, in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for manifestURL in contents where manifestURL.pathExtension == "json"
            && manifestURL.lastPathComponent.hasSuffix(".recording.json") {
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data),
                  manifest.sessionID == sessionID,
                  recoverableStatuses.contains(manifest.status) else {
                continue
            }
            manifest.status = registered
            write(manifest)
        }
    }

    static func markRegistered(urls: [URL]) {
        for url in urls {
            let manifestURL = manifestURL(for: url)
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data) else {
                continue
            }
            manifest.status = registered
            write(manifest)
        }
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return Int64(capacity)
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }

    static func recoverInterruptedSessions(
        in directory: URL,
        includePendingImport: Bool = true
    ) -> [RecordingRecoveredSession] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var bySession: [String: RecordingSessionManifest] = [:]
        for manifestURL in contents where manifestURL.pathExtension == "json"
            && manifestURL.lastPathComponent.hasSuffix(".recording.json") {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data),
                  recoverableStatuses.contains(manifest.status) else {
                continue
            }
            if manifest.status == pendingImport, !includePendingImport {
                continue
            }
            if let existing = bySession[manifest.sessionID] {
                if manifest.startedAt >= existing.startedAt {
                    bySession[manifest.sessionID] = merged(existing, manifest)
                } else {
                    bySession[manifest.sessionID] = merged(manifest, existing)
                }
            } else {
                bySession[manifest.sessionID] = manifest
            }
        }

        var recovered: [RecordingRecoveredSession] = []
        for manifest in bySession.values {
            let urls = existingMediaURLs(for: manifest)
            guard !urls.isEmpty else {
                Log.recording.warning(
                    "recording interrupted session has no media id=\(manifest.sessionID) path=\(manifest.outputURL.lastPathComponent)"
                )
                continue
            }
            Log.recording.notice(
                "recording recovered interrupted session id=\(manifest.sessionID) status=\(manifest.status) files=\(urls.count)"
            )
            recovered.append(
                RecordingRecoveredSession(
                    sessionID: manifest.sessionID,
                    urls: urls,
                    status: manifest.status,
                    manifest: manifest
                )
            )
        }
        return recovered.sorted { lhs, rhs in
            lhs.manifest.startedAt > rhs.manifest.startedAt
        }
    }

    private static func merged(_ older: RecordingSessionManifest, _ newer: RecordingSessionManifest) -> RecordingSessionManifest {
        var result = newer
        var segments = older.segments ?? []
        for segment in newer.segments ?? [] where !segments.contains(where: { $0.path == segment.path }) {
            segments.append(segment)
        }
        result.segments = segments.sorted { $0.index < $1.index }
        return result
    }

    private static func existingMediaURLs(for manifest: RecordingSessionManifest) -> [URL] {
        if manifest.status == pendingImport || manifest.status == pendingReview || manifest.status == pendingTrim || manifest.status == rawSaved || manifest.status == pendingExport {
            let size = (try? manifest.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if FileManager.default.fileExists(atPath: manifest.outputURL.path), size > 0 {
                return [manifest.outputURL]
            }
        }
        var urls: [URL] = []
        let candidates = (manifest.segments?.map(\.url) ?? []) + [manifest.outputURL]
        for url in candidates where !urls.contains(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if FileManager.default.fileExists(atPath: url.path), size > 0 {
                urls.append(url)
            }
        }
        return urls
    }
}

enum RecordingMediaValidator {
    struct Inspection: Equatable, Sendable {
        var url: URL
        var exists: Bool
        var fileSize: Int64
        var isReadable: Bool
        var duration: TimeInterval?
        var hasAudio: Bool
        var hasVideo: Bool
    }

    /// Parallel inspections finish in arbitrary order; media stays chronological.
    static func readableURLs(in orderedURLs: [URL], inspections: [Inspection]) -> [URL] {
        let readable = Set(inspections.filter(\.isReadable).map(\.url))
        return orderedURLs.filter { readable.contains($0) }
    }

    static func inspect(_ url: URL) async -> Inspection {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard exists, size > 0 else {
            return Inspection(
                url: url,
                exists: exists,
                fileSize: size,
                isReadable: false,
                duration: nil,
                hasAudio: false,
                hasVideo: false
            )
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let readable = duration.isValid && duration.isNumeric && duration.seconds > 0
                && (!audioTracks.isEmpty || !videoTracks.isEmpty)
            return Inspection(
                url: url,
                exists: true,
                fileSize: size,
                isReadable: readable,
                duration: duration.isNumeric ? duration.seconds : nil,
                hasAudio: !audioTracks.isEmpty,
                hasVideo: !videoTracks.isEmpty
            )
        } catch {
            return Inspection(
                url: url,
                exists: true,
                fileSize: size,
                isReadable: false,
                duration: nil,
                hasAudio: false,
                hasVideo: false
            )
        }
    }
}
