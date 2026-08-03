enum ClipType: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case dub
    case image
    case text
    case lottie
    case sequence

    var sfSymbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .dub: "waveform.badge.mic"
        case .image: "photo"
        case .text: "textformat"
        case .lottie: "sparkles"
        case .sequence: "film.stack"
        }
    }

    var trackLabel: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .dub: "Dub"
        case .image: "Image"
        case .text: "Text"
        case .lottie: "Lottie"
        case .sequence: "Video"
        }
    }

    var trackLabelPrefix: String { String(trackLabel.prefix(1)) }

    var isVisual: Bool {
        !isAudio
    }

    var isAudio: Bool {
        self == .audio || self == .dub
    }

    func isCompatible(with other: ClipType) -> Bool {
        self == other || (self.isAudio && other.isAudio) || (self.isVisual && other.isVisual)
    }

    init?(fileExtension ext: String) {
        switch ext {
        case "mov", "mp4", "m4v": self = .video
        case "mp3", "wav", "aac", "m4a", "aiff", "aif", "aifc", "caf", "flac": self = .audio
        case "png", "jpg", "jpeg", "tiff", "heic", "webp": self = .image
        case "json", "lottie": self = .lottie
        default: return nil
        }
    }
}
