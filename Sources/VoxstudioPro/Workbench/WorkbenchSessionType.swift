import Foundation

/// Source identity is independent of the media's container and processing tasks.
/// Keep wire values compatible with existing local snapshots and Cloud sessions.
enum WorkbenchSessionType: String, Sendable {
    case upload
    case netVideo = "net_video"
    case record
    case screenRecord = "screen_record"
    case live
    case meetingRecord = "meeting_record"
    case googleMeet = "google_meet"
    case dub

    init(sourceType: String?, isDub: Bool = false, capturesVideo: Bool? = nil) {
        if isDub { self = .dub; return }
        let normalized = sourceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "file", "import", "upload": self = .upload
        case "url", "youtube", "net_video": self = .netVideo
        case "meeting", "meeting_record": self = .meetingRecord
        case "audio_record", "record": self = capturesVideo == true ? .screenRecord : .record
        case "screen", "screen_record": self = .screenRecord
        default: self = Self(rawValue: normalized) ?? .upload
        }
    }

    var label: String {
        switch self {
        case .upload: "Import"
        case .netVideo: "Online video"
        case .record: "Audio recording"
        case .screenRecord: "Screen recording"
        case .live: "Live recording"
        case .meetingRecord, .googleMeet: "Meeting"
        case .dub: "Voiceover"
        }
    }

    var navGlyph: WorkbenchNavGlyph {
        switch self {
        case .upload: .bookType
        case .netVideo: .squarePlay
        case .record: .system("mic")
        case .screenRecord: .system("display")
        case .live: .system("dot.radiowaves.left.and.right")
        case .meetingRecord, .googleMeet: .system("person.2")
        case .dub: .voiceover
        }
    }

    var showsRecentListLabel: Bool { true }
}

enum RecordingPurpose: String, Codable, Sendable {
    case recording
    case meeting
}

enum WorkbenchRecordingKind: String, Codable, Sendable {
    case audio
    case screen
    case meeting

    var sessionType: WorkbenchSessionType {
        switch self {
        case .audio: .record
        case .screen: .screenRecord
        case .meeting: .meetingRecord
        }
    }

    /// Older captures did not persist purpose. Use their journal's mode when
    /// available; never infer a meeting from a filename or an application name.
    static func recordedSource(at url: URL) -> Self {
        if let data = try? Data(contentsOf: RecordingSessionManifest.manifestURL(for: url)),
           let manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data) {
            if let kind = manifest.recordingKind { return kind }
            if let mode = RecordingCaptureMode(rawValue: manifest.mode) {
                return mode.capturesVideo ? .screen : .audio
            }
            if let includesVideo = manifest.includesVideo { return includesVideo ? .screen : .audio }
        }
        return ClipType(fileExtension: url.pathExtension) == .video ? .screen : .audio
    }
}

extension WorkbenchTranscriptionJob {
    var sessionType: WorkbenchSessionType {
        if let recordingKind { return recordingKind.sessionType }
        if isRecordedCapture { return .record }
        return netVideoSourceURL == nil ? .upload : .netVideo
    }
}
