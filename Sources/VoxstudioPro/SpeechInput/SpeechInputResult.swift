import Foundation

struct SpeechInputResult: Equatable, Sendable {
    static let maximumDuration: Double = 10
    static let maximumTokens = 512

    let text: String
    let languageCode: String?
    let engine: ASREngine
}

enum SpeechInputPurpose: Sendable {
    case referenceAudio
    case quickInput
}

enum SpeechInputError: LocalizedError {
    case recognitionLimit
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .recognitionLimit:
            "Couldn’t finish recognizing this recording after retrying shorter sections. Try recording again."
        case .invalidAudioFormat:
            "The audio format is not supported. Choose another recording."
        }
    }
}
