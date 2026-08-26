import AppKit
import CryptoKit
import Foundation
import Observation

#if BUNDLED_SPEECH
@preconcurrency import AudioCommon
import HuggingFace
#endif

enum LocalModelID: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen3ASR17B8Bit
    case parakeetTDT06Bv3
    case whisperLargeV3Turbo8Bit
    case whisperLargeV3TurboFP16
    case whisperSmall
    case spokenLanguageID
    case forcedAligner
    case sileroVAD
    case sortformerDiarization
    case pyannoteSegmentation
    case weSpeaker
    case qwenTTS06B
    case qwenTTS17B

    var id: String { rawValue }

    var isASRModel: Bool {
        asrEngine != nil
    }

    var isWhisperFallbackModel: Bool {
        switch self {
        case .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16: true
        default: false
        }
    }

    var asrEngine: ASREngine? {
        switch self {
        case .qwen3ASR17B8Bit: .qwen
        case .parakeetTDT06Bv3: .parakeet
        case .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16: .whisper
        default: nil
        }
    }
}

enum LocalASRPrecision: String, Codable, Sendable {
    case eightBit
    case fp16
}

struct LocalASRModelSpecification: Sendable {
    let precision: LocalASRPrecision
    let encoderLayers: Int
    let decoderLayers: Int
    let vocabularySize: Int
    let melBinCount: Int
    let quantizationBits: Int?
    let quantizationGroupSize: Int?
    let maximumWindowDuration: Double
    let boundaryContextDuration: Double
    let maximumMergeGap: Double
}

struct LocalModelArtifact: Codable, Hashable, Sendable {
    let filename: String
    let byteSize: Int64
    let sha256: String
}

struct LocalModelDescriptor: Identifiable, Sendable {
    let id: LocalModelID
    let title: String
    let purpose: String
    let repository: String
    let weightFilename: String
    let revision: String
    let weightByteSize: Int64
    let weightSHA256: String
    let byteSize: Int64
    let sizeLabel: String
    let license: String
    let licenseURL: URL?
    let requiresLicenseAcceptance: Bool
    let requiredFor: Set<LocalFeature>
    let isRecommended: Bool
    let isLegacy: Bool
    let asrSpecification: LocalASRModelSpecification?
    let requiredArtifacts: [LocalModelArtifact]

    init(
        id: LocalModelID,
        title: String,
        purpose: String,
        repository: String,
        weightFilename: String = "model.safetensors",
        revision: String,
        weightByteSize: Int64,
        weightSHA256: String,
        byteSize: Int64,
        sizeLabel: String,
        license: String,
        licenseURL: URL? = nil,
        requiresLicenseAcceptance: Bool = false,
        requiredFor: Set<LocalFeature>,
        isRecommended: Bool,
        isLegacy: Bool = false,
        asrSpecification: LocalASRModelSpecification? = nil,
        requiredArtifacts: [LocalModelArtifact] = []
    ) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.repository = repository
        self.weightFilename = weightFilename
        self.revision = revision
        self.weightByteSize = weightByteSize
        self.weightSHA256 = weightSHA256
        self.byteSize = byteSize
        self.sizeLabel = sizeLabel
        self.license = license
        self.licenseURL = licenseURL
        self.requiresLicenseAcceptance = requiresLicenseAcceptance
        self.requiredFor = requiredFor
        self.isRecommended = isRecommended
        self.isLegacy = isLegacy
        self.asrSpecification = asrSpecification
        self.requiredArtifacts = requiredArtifacts
    }

    enum LocalFeature: String, Sendable {
        case transcribe
        case dub
    }
}

private struct LocalModelInstallManifest: Codable, Sendable {
    let repository: String
    let revision: String
    let weightSHA256: String
    let installedAt: Date
    let dependencies: [String: String]
    let artifactSHA256: [String: String]?
}

enum LocalModelDownloadState: Equatable, Sendable {
    case notInstalled
    case queued
    case downloading(progress: Double, message: String)
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .queued, .downloading: true
        default: false
        }
    }
}

@Observable
@MainActor
final class LocalModelManager {
    static let shared = LocalModelManager()

    nonisolated static let defaultASRModelID: LocalModelID = .whisperLargeV3Turbo8Bit
    nonisolated static let defaultQwenASRModelID: LocalModelID = .qwen3ASR17B8Bit
    nonisolated static let defaultParakeetASRModelID: LocalModelID = .parakeetTDT06Bv3
    private nonisolated static let activeASRDefaultsKey = "voxella.local-model.active-asr"

    nonisolated static let ttsTokenizerRepository = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
    nonisolated static let ttsTokenizerRevision = "7dd38ad4e9bad454aae9cd937d0cd577604fe229"
    nonisolated static let ttsTokenizerByteSize: Int64 = 682_300_739
    nonisolated static let ttsTokenizerWeightByteSize: Int64 = 682_293_092
    nonisolated static let ttsTokenizerWeightSHA256 = "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"
    nonisolated static let whisperTokenizerRepository = "openai/whisper-small"
    nonisolated static let whisperTokenizerRevision = "973afd24965f72e36ca33b3055d56a652f456b4d"

    private nonisolated static let largeTurboSharedArtifacts: [LocalModelArtifact] = [
        .init(filename: "added_tokens.json", byteSize: 34_648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
        .init(filename: "generation_config.json", byteSize: 3_772, sha256: "cce11bfe3aaa6ae9e072ea2637caaec8795e68d9b67e655a5af16ee509681a4c"),
        .init(filename: "merges.txt", byteSize: 493_869, sha256: "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6"),
        .init(filename: "normalizer.json", byteSize: 52_666, sha256: "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd"),
        .init(filename: "preprocessor_config.json", byteSize: 340, sha256: "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711"),
        .init(filename: "special_tokens_map.json", byteSize: 2_186, sha256: "baea4ea09372eb4fca86b4e4346139fd73cb807d5087e9de0948e971739c3e74"),
        .init(filename: "tokenizer.json", byteSize: 2_710_337, sha256: "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
        .init(filename: "tokenizer_config.json", byteSize: 282_843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
        .init(filename: "vocab.json", byteSize: 1_036_558, sha256: "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387"),
    ]

    nonisolated static let catalog: [LocalModelDescriptor] = [
        .init(
            id: .qwen3ASR17B8Bit,
            title: "Qwen3-ASR 1.7B 8-bit",
            purpose: "East and Southeast Asian speech recognition, including Cantonese",
            repository: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
            weightByteSize: 2_463_307_541,
            weightSHA256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c",
            byteSize: 2_467_856_503,
            sizeLabel: "~ 2.47 GB",
            license: "Apache-2.0",
            licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-1.7B"),
            requiredFor: [.transcribe],
            isRecommended: true,
            requiredArtifacts: [
                .init(filename: "chat_template.json", byteSize: 1_161, sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
                .init(filename: "config.json", byteSize: 7_188, sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"),
                .init(filename: "generation_config.json", byteSize: 142, sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
                .init(filename: "merges.txt", byteSize: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                .init(filename: "model.safetensors.index.json", byteSize: 78_968, sha256: "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"),
                .init(filename: "preprocessor_config.json", byteSize: 330, sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
                .init(filename: "tokenizer_config.json", byteSize: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
                .init(filename: "vocab.json", byteSize: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ]
        ),
        .init(
            id: .parakeetTDT06Bv3,
            title: "Parakeet TDT 0.6B v3 INT8",
            purpose: "English and European speech recognition with native timestamps",
            repository: "sonic-speech/parakeet-tdt-0.6b-v3-int8",
            revision: "6d2686d9f29d98baa1e4c65a8701516e8e34919d",
            weightByteSize: 754_851_107,
            weightSHA256: "e3745e51e513494c60494ce2ff61d49961823b3ce0333ff983bc6f83ddbbca45",
            byteSize: 755_530_800,
            sizeLabel: "~ 756 MB",
            license: "CC-BY-4.0",
            licenseURL: URL(string: "https://huggingface.co/sonic-speech/parakeet-tdt-0.6b-v3-int8"),
            requiredFor: [.transcribe],
            isRecommended: true,
            requiredArtifacts: [
                .init(filename: "config.json", byteSize: 318_613, sha256: "9933d6badd8335b1524e9f4a515aa4ab89b4e8bf94dd8b60aa95c949e735d6ea"),
                .init(filename: "quantization_config.json", byteSize: 164, sha256: "17145c6de4aecdf2b2d57507e2101e7848b533fc3f008314b821a3f45d804282"),
                .init(filename: "tokenizer.model", byteSize: 360_916, sha256: "eacec2b0a77f336d4a2ca4a25a7047575d3c2b74de47e997f4c205126ed3135e"),
            ]
        ),
        .init(
            id: .whisperLargeV3Turbo8Bit,
            title: "Whisper Large v3 Turbo 8-bit",
            purpose: "Multilingual fallback speech recognition",
            repository: "mlx-community/whisper-large-v3-turbo-asr-8bit",
            revision: "f0fca477e0a885ef4a61088d6cbbc8fc25e53268",
            weightByteSize: 863_658_987,
            weightSHA256: "9564a6a5d66637e9207234f6c17ea583162c4edc35fd44a087e37768bf5ffc5b",
            byteSize: 868_348_406,
            sizeLabel: "~ 868 MB",
            license: "MIT",
            licenseURL: URL(string: "https://github.com/openai/whisper/blob/main/LICENSE"),
            requiredFor: [.transcribe],
            isRecommended: true,
            asrSpecification: .init(
                precision: .eightBit,
                encoderLayers: 32,
                decoderLayers: 4,
                vocabularySize: 51_866,
                melBinCount: 128,
                quantizationBits: 8,
                quantizationGroupSize: 64,
                maximumWindowDuration: 28,
                boundaryContextDuration: 0.75,
                maximumMergeGap: 0.75
            ),
            requiredArtifacts: largeTurboSharedArtifacts + [
                .init(filename: "config.json", byteSize: 1_506, sha256: "9a0fa244c2ddc59048da5da250655c20cdc5c161204feaae7298d98e9ed838bb"),
                .init(filename: "model.safetensors.index.json", byteSize: 68_118, sha256: "e7e2059e00a17e2964de92c47aaf1475bdc9edab8937a578bc21cb6a6f01d37a"),
            ]
        ),
        .init(
            id: .whisperLargeV3TurboFP16,
            title: "Whisper Large v3 Turbo FP16",
            purpose: "Maximum-quality multilingual fallback speech recognition",
            repository: "mlx-community/whisper-large-v3-turbo-asr-fp16",
            revision: "624c19c9af5603fa73b83bce14d4aeea96156d18",
            weightByteSize: 1_613_977_443,
            weightSHA256: "a76ee3af9c01b616ab7caf1eed663dceb7d68e9dc62c990dac48112db6e57e34",
            byteSize: 1_618_636_172,
            sizeLabel: "~ 1.62 GB",
            license: "MIT",
            licenseURL: URL(string: "https://github.com/openai/whisper/blob/main/LICENSE"),
            requiredFor: [.transcribe],
            isRecommended: false,
            asrSpecification: .init(
                precision: .fp16,
                encoderLayers: 32,
                decoderLayers: 4,
                vocabularySize: 51_866,
                melBinCount: 128,
                quantizationBits: nil,
                quantizationGroupSize: nil,
                maximumWindowDuration: 28,
                boundaryContextDuration: 0.75,
                maximumMergeGap: 0.75
            ),
            requiredArtifacts: largeTurboSharedArtifacts + [
                .init(filename: "config.json", byteSize: 1_301, sha256: "47ef28115e4b7e08c604546cc98eb1ead8ff72152cfaeb5d7bcb7ef1640a5bdd"),
                .init(filename: "model.safetensors.index.json", byteSize: 37_633, sha256: "9cf894da1061ccc1657c6dabf1fa19dfcf1f0603df4194ab4fb913a554da789d"),
            ]
        ),
        .init(
            id: .whisperSmall,
            title: "Whisper Small MLX FP16 (Legacy)",
            purpose: "Previous ASR model; no longer used for transcription",
            repository: "mlx-community/whisper-small-fp16",
            revision: "fa19eb05939653a9334d81bec7e053db81970170",
            weightByteSize: 481_215_362,
            weightSHA256: "7408174e70bffbff6a189cadc3621512be0d1d26bb8c9122d3eeace1652d1b54",
            byteSize: 481_215_628,
            sizeLabel: "~ 481 MB",
            license: "Apache-2.0",
            requiredFor: [],
            isRecommended: false,
            isLegacy: true
        ),
        .init(
            id: .spokenLanguageID,
            title: "VoxLingua107 ECAPA MLX",
            purpose: "Offline spoken-language detection for automatic ASR",
            repository: "beshkenadze/lang-id-voxlingua107-ecapa-mlx",
            weightFilename: "ecapa_tdnn_lid107.safetensors",
            revision: "ea8995c21cc571117f2dcddee39ac3b22f7fde83",
            weightByteSize: 85_172_012,
            weightSHA256: "bae5627c78e942e6ca15af87cbfd582915ead6ae2d8f839ad225504c946ddbc8",
            byteSize: 85_175_036,
            sizeLabel: "~ 85 MB",
            license: "Apache-2.0",
            requiredFor: [.transcribe],
            isRecommended: true
        ),
        .init(
            id: .forcedAligner,
            title: "Qwen3 Forced Aligner 0.6B",
            purpose: "Word-level timestamps and caption sync",
            repository: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
            revision: "f0e9f12a0ddbcb5f1e1b7f0339090628f1cede1d",
            weightByteSize: 978_674_048,
            weightSHA256: "8187bcb2ab9046cbb274559523d21f60249410ccc561682bc5860b07101c5568",
            byteSize: 983_146_386,
            sizeLabel: "~ 983 MB",
            license: "Apache-2.0",
            requiredFor: [.transcribe, .dub],
            isRecommended: true
        ),
        .init(
            id: .sileroVAD,
            title: "Silero VAD v5 MLX",
            purpose: "Speech-region detection",
            repository: "aufklarer/Silero-VAD-v5-MLX",
            revision: "01edc8ef8265d8f0039910ce471d26eed0b804db",
            weightByteSize: 1_237_580,
            weightSHA256: "704e4211eab4177b88dd7f2f0746f53cc737d49711d34c4a34d00950bb78201b",
            byteSize: 1_241_938,
            sizeLabel: "~ 1.2 MB",
            license: "MIT",
            requiredFor: [.transcribe],
            isRecommended: true
        ),
        .init(
            id: .sortformerDiarization,
            title: "Streaming Sortformer v2.1 MLX",
            purpose: "Streaming speaker diarization with overlap detection",
            repository: "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16",
            revision: "e23e6404bd9859e93edbf94a740eb1c7fc58f12e",
            weightByteSize: 236_108_132,
            weightSHA256: "3b60b8df29e59a8abaf8061ceeeae6e9284a68fbcd2e762c68f5e058bfceebfa",
            byteSize: 236_109_834,
            sizeLabel: "~ 236 MB",
            license: "NVIDIA Open Model License",
            licenseURL: URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/"),
            requiresLicenseAcceptance: true,
            requiredFor: [.transcribe],
            isRecommended: true
        ),
        .init(
            id: .pyannoteSegmentation,
            title: "Pyannote Segmentation MLX",
            purpose: "Speaker-turn segmentation",
            repository: "aufklarer/Pyannote-Segmentation-MLX",
            revision: "abef0110277063f0ea117a802832a3eba22af84c",
            weightByteSize: 5_960_404,
            weightSHA256: "d1630fa2c22f47e4c89034f8d5e3aff99884f55347d48ce70dd306328b4421f5",
            byteSize: 5_965_718,
            sizeLabel: "~ 6 MB",
            license: "MIT",
            requiredFor: [.transcribe],
            isRecommended: false
        ),
        .init(
            id: .weSpeaker,
            title: "WeSpeaker ResNet34 MLX",
            purpose: "Speaker embeddings and clustering",
            repository: "aufklarer/WeSpeaker-ResNet34-LM-MLX",
            revision: "26499ce11ad1b48ac96aacc8d6fa433f941bdc96",
            weightByteSize: 26_526_952,
            weightSHA256: "f56204883f2de969f584af7893e5373575556b422190c14c206a5fd94f3d7fe6",
            byteSize: 26_532_037,
            sizeLabel: "~ 27 MB",
            license: "MIT",
            requiredFor: [.transcribe],
            isRecommended: false
        ),
        .init(
            id: .qwenTTS06B,
            title: "Qwen3-TTS Small 0.6B 4-bit",
            purpose: "Legacy local dubbing model",
            repository: "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit",
            revision: "e382c6ec904317f408fdaaad7e0d6fc9741f0e2f",
            weightByteSize: 1_024_490_700,
            weightSHA256: "07dcb37b323614af64624af687876edd5c9a8b442da2a7b549d62f9ba2770ec1",
            byteSize: 1_029_032_584,
            sizeLabel: "~ 1.03 GB",
            license: "Apache-2.0",
            requiredFor: [.dub],
            isRecommended: false,
            isLegacy: true
        ),
        .init(
            id: .qwenTTS17B,
            title: "Qwen3-TTS 1.7B 8-bit",
            purpose: "Local dubbing and voice cloning",
            repository: "aufklarer/Qwen3-TTS-12Hz-1.7B-Base-MLX-8bit",
            revision: "87d008f1e1a20d265bee01c7ccb0a78f5b8d1132",
            weightByteSize: 2_417_320_525,
            weightSHA256: "b965c581ccf6aa852a4124feeb7a8a111542ee7b213139368b4cc7ba7fd4728b",
            byteSize: 2_421_856_575,
            sizeLabel: "~ 2.42 GB",
            license: "Apache-2.0",
            requiredFor: [.dub],
            isRecommended: true
        ),
    ]

    var states: [LocalModelID: LocalModelDownloadState] = [:]
    private(set) var activeASRModelID: LocalModelID
    private var activeDownloads: [LocalModelID: Task<Void, Never>] = [:]
    private var pendingASRActivation: Set<LocalModelID> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private init() {
        activeASRModelID = Self.preferredASRModelID()
        refreshInstallationStates()
    }

    func presentManager() {
        refreshInstallationStates()
        LocalModelManagerWindowController.shared.show()
    }

    func descriptor(for id: LocalModelID) -> LocalModelDescriptor {
        Self.catalog.first { $0.id == id }!
    }

    func state(for id: LocalModelID) -> LocalModelDownloadState {
        states[id] ?? .notInstalled
    }

    func models(for feature: LocalModelDescriptor.LocalFeature) -> [LocalModelDescriptor] {
        Self.catalog.filter { !$0.isLegacy && $0.requiredFor.contains(feature) }
    }

    var installedLegacyModels: [LocalModelDescriptor] {
        Self.catalog.filter { $0.isLegacy && state(for: $0.id).isInstalled }
    }

    nonisolated static func preferredWhisperFallbackModelID() -> LocalModelID {
        guard let rawValue = UserDefaults.standard.string(forKey: activeASRDefaultsKey),
              let id = LocalModelID(rawValue: rawValue),
              id.isWhisperFallbackModel else { return defaultASRModelID }
        return id
    }

    nonisolated static func preferredASRModelID() -> LocalModelID {
        preferredWhisperFallbackModelID()
    }

    nonisolated static func modelID(for engine: ASREngine) -> LocalModelID {
        ASREngineLanguagePolicy.modelID(for: engine, whisperFallback: preferredWhisperFallbackModelID())
    }

    @discardableResult
    func useASRModel(_ id: LocalModelID) -> Bool {
        guard id.isWhisperFallbackModel else { return false }
        guard state(for: id).isInstalled else {
            if let model = Self.catalog.first(where: { $0.id == id }) {
                states[id] = .failed("Download and verify \(model.title) before selecting it.")
            }
            return false
        }
        activeASRModelID = id
        UserDefaults.standard.set(id.rawValue, forKey: Self.activeASRDefaultsKey)
        return true
    }

    func isActiveASRModel(_ id: LocalModelID) -> Bool {
        id.isWhisperFallbackModel && activeASRModelID == id
    }

    func hasRequiredModels(for feature: LocalModelDescriptor.LocalFeature) -> Bool {
        if feature == .transcribe {
            return hasRequiredTranscriptionModels(languageCode: nil, speakerCount: nil)
        }
        return models(for: feature).filter(\.isRecommended).allSatisfy { state(for: $0.id).isInstalled }
    }

    func hasRequiredTranscriptionModels(languageCode: String?, speakerCount: Int?) -> Bool {
        let required = LocalModelInstallPlan.requiredModelIDs(
            languageCode: languageCode,
            speakerCount: speakerCount,
            whisperFallbackModelID: activeASRModelID
        )
        return required.allSatisfy { state(for: $0).isInstalled }
    }

    func hasRequiredDubModels(modelID: LocalModelID) -> Bool {
        state(for: modelID).isInstalled && state(for: .forcedAligner).isInstalled
    }

    func refreshInstallationStates() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let catalog = Self.catalog
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let installed = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, Self.isInstalled($0)) })
            }.value
            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            for model in catalog where self.activeDownloads[model.id] == nil {
                self.states[model.id] = installed[model.id] == true ? .installed : .notInstalled
            }
        }
    }

    func download(_ id: LocalModelID) {
        download(id, activateWhenInstalled: false)
    }

    func downloadAndUseASRModel(_ id: LocalModelID) {
        guard id.isWhisperFallbackModel else {
            download(id)
            return
        }
        download(id, activateWhenInstalled: true)
    }

    private func download(_ id: LocalModelID, activateWhenInstalled: Bool) {
        guard activeDownloads[id] == nil else { return }
        let model = descriptor(for: id)
        guard !model.requiresLicenseAcceptance || isLicenseAccepted(id) else {
            states[id] = .failed("Review and accept the model license before downloading.")
            return
        }
        if activateWhenInstalled { pendingASRActivation.insert(id) }
        states[id] = .queued
        activeDownloads[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(id)
                let model = self.descriptor(for: id)
                let installed = await Task.detached(priority: .utility) {
                    Self.isInstalled(model)
                }.value
                guard installed else {
                    throw LocalAIError.incompleteModel(model.title)
                }
                self.states[id] = .installed
                if self.pendingASRActivation.remove(id) != nil {
                    self.useASRModel(id)
                }
            } catch is CancellationError {
                self.pendingASRActivation.remove(id)
                let model = self.descriptor(for: id)
                let installed = await Task.detached(priority: .utility) {
                    Self.isInstalled(model)
                }.value
                self.states[id] = installed ? .installed : .notInstalled
            } catch {
                self.pendingASRActivation.remove(id)
                self.states[id] = .failed(error.localizedDescription)
            }
            self.activeDownloads[id] = nil
        }
    }

    func downloadRecommended() {
        Task {
            for model in Self.catalog where model.isRecommended && !state(for: model.id).isInstalled {
                download(model.id)
                while state(for: model.id).isBusy {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if case .failed = state(for: model.id) { break }
            }
        }
    }

    func cancel(_ id: LocalModelID) {
        pendingASRActivation.remove(id)
        activeDownloads[id]?.cancel()
    }

    func isLicenseAccepted(_ id: LocalModelID) -> Bool {
        UserDefaults.standard.bool(forKey: "voxella.local-model-license.\(id.rawValue)")
    }

    func acceptLicense(_ id: LocalModelID) {
        UserDefaults.standard.set(true, forKey: "voxella.local-model-license.\(id.rawValue)")
    }

    func remove(_ id: LocalModelID) {
        guard !isActiveASRModel(id) else {
            states[id] = .failed("Select another speech recognition model before removing this one.")
            return
        }
        cancel(id)
        let model = descriptor(for: id)
        states[id] = .queued
        Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try Self.directory(for: model)
                try await Self.removeDirectoryIfPresent(directory)
                self.states[id] = .notInstalled
            } catch {
                self.states[id] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func directory(for id: LocalModelID) throws -> URL {
        guard let model = catalog.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try directory(for: model)
    }

    nonisolated static func directory(for model: LocalModelDescriptor) throws -> URL {
        #if BUNDLED_SPEECH
        return try HuggingFaceDownloader.getCacheDirectory(for: model.repository)
        #else
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxella Studio/Models", isDirectory: true)
        return base.appendingPathComponent(model.repository.replacingOccurrences(of: "/", with: "_"))
        #endif
    }

    nonisolated static func isInstalled(_ model: LocalModelDescriptor) -> Bool {
        guard let directory = try? directory(for: model),
              weightFileSize(in: directory, filename: model.weightFilename) == model.weightByteSize,
              let modelManifest = manifest(in: directory),
              modelManifest.repository == model.repository,
              modelManifest.revision == model.revision,
              modelManifest.weightSHA256 == model.weightSHA256 else { return false }
        if !model.requiredArtifacts.isEmpty {
            let expectedHashes = artifactHashes(for: model)
            guard modelManifest.artifactSHA256 == expectedHashes,
                  model.requiredArtifacts.allSatisfy({ artifact in
                      weightFileSize(in: directory, filename: artifact.filename) == artifact.byteSize
                  }) else { return false }
        }
        if model.id == .whisperSmall {
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
                && modelManifest.dependencies[whisperTokenizerRepository] == whisperTokenizerRevision
        }
        if model.id == .qwenTTS06B || model.id == .qwenTTS17B {
            #if BUNDLED_SPEECH
            guard let tokenizer = try? HuggingFaceDownloader.getCacheDirectory(for: ttsTokenizerRepository) else {
                return false
            }
            guard let tokenizerManifest = manifest(in: tokenizer) else { return false }
            return weightFileSize(in: tokenizer) == ttsTokenizerWeightByteSize
                && tokenizerManifest.repository == ttsTokenizerRepository
                && tokenizerManifest.revision == ttsTokenizerRevision
                && tokenizerManifest.weightSHA256 == ttsTokenizerWeightSHA256
            #else
            return false
            #endif
        }
        return true
    }

    private nonisolated static func hasWeights(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 { return true }
        }
        return false
    }

    private nonisolated static func weightFileSize(
        in directory: URL,
        filename: String = "model.safetensors"
    ) -> Int64? {
        let url = directory.appendingPathComponent(filename)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private nonisolated static func manifest(in directory: URL) -> LocalModelInstallManifest? {
        let url = directory.appendingPathComponent(".voxella-model.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalModelInstallManifest.self, from: data)
    }

    private func performDownload(_ id: LocalModelID) async throws {
        #if BUNDLED_SPEECH
        let model = descriptor(for: id)
        var directory = try Self.directory(for: model)
        let initialDirectory = directory
        var mainWeightVerified = await Task.detached(priority: .utility) {
            Self.coreFilesExist(for: id, in: initialDirectory)
        }.value
        if mainWeightVerified {
            mainWeightVerified = await Self.verifyWeight(
                in: initialDirectory,
                filename: model.weightFilename,
                expectedBytes: model.weightByteSize,
                expectedSHA256: model.weightSHA256
            )
        }
        let statusDirectory = directory
        let cacheStatus = await Task.detached(priority: .utility) {
            (hasWeights: Self.hasWeights(in: statusDirectory), installed: Self.isInstalled(model))
        }.value
        if cacheStatus.hasWeights, !cacheStatus.installed, !mainWeightVerified {
            try await Self.removeDirectoryIfPresent(directory)
            directory = try Self.directory(for: model)
        }
        let mainRange: ClosedRange<Double> = if id.isASRModel {
            0...0.92
        } else if id == .whisperSmall || id == .qwenTTS06B || id == .qwenTTS17B {
            0...0.82
        } else {
            0...1
        }
        if !mainWeightVerified {
            states[id] = .downloading(progress: 0, message: "Downloading pinned model revision…")
            try await Self.downloadPinnedSnapshot(
                repository: model.repository,
                revision: model.revision,
                to: directory,
                matching: Self.weightGlobs(additionalFiles: Self.additionalFiles(for: id))
            ) { [weak self] fraction in
                self?.updateProgress(
                    id: id,
                    fraction: fraction,
                    range: mainRange,
                    message: "Downloading \(model.title)…"
                )
            }
            states[id] = .downloading(progress: mainRange.upperBound, message: "Verifying model checksum…")
            let weightVerified = await Self.verifyWeight(
                in: directory,
                filename: model.weightFilename,
                expectedBytes: model.weightByteSize,
                expectedSHA256: model.weightSHA256
            )
            let downloadedDirectory = directory
            let coreFilesVerified = await Task.detached(priority: .utility) {
                Self.coreFilesExist(for: id, in: downloadedDirectory)
            }.value
            mainWeightVerified = weightVerified && coreFilesVerified
        } else {
            states[id] = .downloading(progress: mainRange.upperBound, message: "Verified cached model…")
        }
        guard mainWeightVerified else {
            throw LocalAIError.incompleteModel(model.title)
        }
        if !model.requiredArtifacts.isEmpty || model.asrSpecification != nil || id.asrEngine != nil {
            states[id] = .downloading(progress: 0.94, message: "Verifying pinned model artifacts…")
            let artifactsValid: Bool
            if model.requiredArtifacts.isEmpty {
                artifactsValid = true
            } else {
                artifactsValid = await Self.verifyArtifacts(model.requiredArtifacts, in: directory)
            }
            let configurationValid: Bool
            if let specification = model.asrSpecification {
                configurationValid = await Self.validateASRConfiguration(in: directory, specification: specification)
            } else if id == .qwen3ASR17B8Bit {
                configurationValid = await Self.validateQwenASRConfiguration(in: directory)
            } else if id == .parakeetTDT06Bv3 {
                configurationValid = await Self.validateParakeetConfiguration(in: directory)
            } else {
                configurationValid = true
            }
            guard artifactsValid, configurationValid else {
                throw LocalAIError.incompleteModel(model.title)
            }
            states[id] = .downloading(progress: 0.98, message: "Finalizing verified model…")
        }
        try Task.checkCancellation()

        if id == .whisperSmall {
            states[id] = .downloading(progress: 0.82, message: "Installing Whisper tokenizer…")
            try await Self.downloadPinnedSnapshot(
                repository: Self.whisperTokenizerRepository,
                revision: Self.whisperTokenizerRevision,
                to: directory,
                matching: Self.whisperTokenizerFiles
            ) { [weak self] fraction in
                self?.updateProgress(
                    id: id,
                    fraction: fraction,
                    range: 0.82...1,
                    message: "Installing Whisper tokenizer…"
                )
            }
        }

        if id == .qwenTTS06B || id == .qwenTTS17B {
            let tokenizer = try HuggingFaceDownloader.getCacheDirectory(for: Self.ttsTokenizerRepository)
            states[id] = .downloading(progress: 0.82, message: "Installing Qwen speech codec…")
            var tokenizerVerified = await Self.verifyWeight(
                in: tokenizer,
                expectedBytes: Self.ttsTokenizerWeightByteSize,
                expectedSHA256: Self.ttsTokenizerWeightSHA256
            )
            if await Task.detached(priority: .utility, operation: {
                Self.hasWeights(in: tokenizer)
            }).value, !tokenizerVerified {
                try await Self.removeDirectoryIfPresent(tokenizer)
            }
            let tokenizerDirectory = try HuggingFaceDownloader.getCacheDirectory(for: Self.ttsTokenizerRepository)
            let tokenizerManifest = await Task.detached(priority: .utility) {
                Self.manifest(in: tokenizerDirectory)
            }.value
            let tokenizerManifestValid = tokenizerManifest?.repository == Self.ttsTokenizerRepository
                && tokenizerManifest?.revision == Self.ttsTokenizerRevision
                && tokenizerManifest?.weightSHA256 == Self.ttsTokenizerWeightSHA256
            if !tokenizerVerified {
                try await Self.downloadPinnedSnapshot(
                    repository: Self.ttsTokenizerRepository,
                    revision: Self.ttsTokenizerRevision,
                    to: tokenizerDirectory,
                    matching: Self.weightGlobs(additionalFiles: [])
                ) { [weak self] fraction in
                    self?.updateProgress(
                        id: id,
                        fraction: fraction,
                        range: 0.82...1,
                        message: "Installing Qwen speech codec…"
                    )
                }
                tokenizerVerified = await Self.verifyWeight(
                    in: tokenizerDirectory,
                    expectedBytes: Self.ttsTokenizerWeightByteSize,
                    expectedSHA256: Self.ttsTokenizerWeightSHA256
                )
                guard tokenizerVerified else {
                    throw LocalAIError.incompleteModel("Qwen speech codec")
                }
                try await Self.writeManifest(
                    repository: Self.ttsTokenizerRepository,
                    revision: Self.ttsTokenizerRevision,
                    weightSHA256: Self.ttsTokenizerWeightSHA256,
                    dependencies: [:],
                    artifactSHA256: nil,
                    to: tokenizerDirectory
                )
            } else if !tokenizerManifestValid {
                try await Self.writeManifest(
                    repository: Self.ttsTokenizerRepository,
                    revision: Self.ttsTokenizerRevision,
                    weightSHA256: Self.ttsTokenizerWeightSHA256,
                    dependencies: [:],
                    artifactSHA256: nil,
                    to: tokenizerDirectory
                )
            }
        }
        let dependencies: [String: String] = switch id {
        case .whisperSmall: [Self.whisperTokenizerRepository: Self.whisperTokenizerRevision]
        case .qwenTTS06B, .qwenTTS17B: [Self.ttsTokenizerRepository: Self.ttsTokenizerRevision]
        default: [:]
        }
        try await Self.writeManifest(
            repository: model.repository,
            revision: model.revision,
            weightSHA256: model.weightSHA256,
            dependencies: dependencies,
            artifactSHA256: model.requiredArtifacts.isEmpty ? nil : Self.artifactHashes(for: model),
            to: directory
        )
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    private nonisolated static func additionalFiles(for id: LocalModelID) -> [String] {
        switch id {
        case .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16,
             .qwen3ASR17B8Bit, .parakeetTDT06Bv3:
            catalog.first(where: { $0.id == id })?.requiredArtifacts.map(\.filename) ?? []
        case .whisperSmall:
            ["config.json", "generation_config.json"]
        case .forcedAligner:
            ["vocab.json", "merges.txt", "tokenizer_config.json", "quantize_config.json"]
        case .qwenTTS06B, .qwenTTS17B:
            ["vocab.json", "merges.txt", "tokenizer_config.json"]
        case .spokenLanguageID, .sileroVAD, .sortformerDiarization,
             .pyannoteSegmentation, .weSpeaker:
            []
        }
    }

    private nonisolated static func coreFilesExist(for id: LocalModelID, in directory: URL) -> Bool {
        let files = additionalFiles(for: id)
        let required = ["config.json"] + (id.isASRModel ? files : files.filter { $0 != "generation_config.json" })
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static let whisperTokenizerFiles = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "vocab.json",
        "merges.txt",
        "normalizer.json",
        "generation_config.json",
    ]

    private nonisolated static func weightGlobs(additionalFiles: [String]) -> [String] {
        var globs = ["config.json", "*.safetensors", "model.safetensors.index.json"]
        for file in additionalFiles where !globs.contains(file) { globs.append(file) }
        return globs
    }

    private nonisolated static func downloadPinnedSnapshot(
        repository: String,
        revision: String,
        to directory: URL,
        matching globs: [String],
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        #if BUNDLED_SPEECH
        guard let repositoryID = Repo.ID(rawValue: repository) else {
            throw URLError(.badURL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transferCache = directory.appendingPathComponent(".voxella-download-cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: transferCache) }
        let client = HubClient(cache: HubCache(cacheDirectory: transferCache))
        _ = try await client.downloadSnapshot(
            of: repositoryID,
            kind: .model,
            to: directory,
            revision: revision,
            matching: globs,
            maxConcurrentDownloads: 4
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    private func updateProgress(
        id: LocalModelID,
        fraction: Double,
        range: ClosedRange<Double>,
        message: String
    ) {
        let normalized = min(max(fraction, 0), 1)
        states[id] = .downloading(
            progress: range.lowerBound + normalized * (range.upperBound - range.lowerBound),
            message: message
        )
    }

    private nonisolated static func writeManifest(
        repository: String,
        revision: String,
        weightSHA256: String,
        dependencies: [String: String],
        artifactSHA256: [String: String]?,
        to directory: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let manifest = LocalModelInstallManifest(
                repository: repository,
                revision: revision,
                weightSHA256: weightSHA256,
                installedAt: Date(),
                dependencies: dependencies,
                artifactSHA256: artifactSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: directory.appendingPathComponent(".voxella-model.json"), options: .atomic)
        }.value
    }

    private nonisolated static func verifyWeight(
        in directory: URL,
        filename: String = "model.safetensors",
        expectedBytes: Int64,
        expectedSHA256: String
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let url = directory.appendingPathComponent(filename)
            guard weightFileSize(in: directory, filename: filename) == expectedBytes,
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }

            var hasher = SHA256()
            do {
                while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: data)
                }
            } catch {
                return false
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == expectedSHA256
        }.value
    }

    private nonisolated static func artifactHashes(for model: LocalModelDescriptor) -> [String: String] {
        var hashes = Dictionary(uniqueKeysWithValues: model.requiredArtifacts.map { ($0.filename, $0.sha256) })
        hashes[model.weightFilename] = model.weightSHA256
        return hashes
    }

    private nonisolated static func verifyArtifacts(
        _ artifacts: [LocalModelArtifact],
        in directory: URL
    ) async -> Bool {
        for artifact in artifacts {
            guard await verifyWeight(
                in: directory,
                filename: artifact.filename,
                expectedBytes: artifact.byteSize,
                expectedSHA256: artifact.sha256
            ) else { return false }
        }
        return true
    }

    private struct WhisperConfiguration: Decodable {
        struct Quantization: Decodable {
            let groupSize: Int
            let bits: Int

            enum CodingKeys: String, CodingKey {
                case groupSize = "group_size"
                case bits
            }
        }

        let vocabularySize: Int
        let melBinCount: Int
        let encoderLayers: Int
        let decoderLayers: Int
        let quantization: Quantization?

        enum CodingKeys: String, CodingKey {
            case vocabularySize = "vocab_size"
            case melBinCount = "num_mel_bins"
            case encoderLayers = "encoder_layers"
            case decoderLayers = "decoder_layers"
            case quantization
        }
    }

    nonisolated static func validateASRConfiguration(
        _ data: Data,
        specification: LocalASRModelSpecification
    ) -> Bool {
        guard let configuration = try? JSONDecoder().decode(WhisperConfiguration.self, from: data),
              configuration.vocabularySize == specification.vocabularySize,
              configuration.melBinCount == specification.melBinCount,
              configuration.encoderLayers == specification.encoderLayers,
              configuration.decoderLayers == specification.decoderLayers else { return false }
        switch specification.precision {
        case .eightBit:
            return configuration.quantization?.bits == specification.quantizationBits
                && configuration.quantization?.groupSize == specification.quantizationGroupSize
        case .fp16:
            return configuration.quantization == nil
        }
    }

    private nonisolated static func validateASRConfiguration(
        in directory: URL,
        specification: LocalASRModelSpecification
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")) else {
                return false
            }
            return validateASRConfiguration(data, specification: specification)
        }.value
    }

    private nonisolated static func validateQwenASRConfiguration(in directory: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["model_type"] as? String == "qwen3_asr" else {
                return false
            }
            return true
        }.value
    }

    private nonisolated static func validateParakeetConfiguration(in directory: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let quantizationURL = directory.appendingPathComponent("quantization_config.json")
            guard let data = try? Data(contentsOf: quantizationURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["bits"] as? Int == 8 else {
                return false
            }
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("tokenizer.model").path
            )
        }.value
    }

    private nonisolated static func removeDirectoryIfPresent(_ directory: URL) async throws {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }.value
    }

}

enum LocalAIError: LocalizedError {
    case modelsUnavailable
    case missingModels(String)
    case incompleteModel(String)
    case emptyTranscript
    case noAudioSamples
    case audioTooQuiet
    case vadNoSpeech
    case asrNoSpeech
    case noAudioOutput

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            "This build does not include the local MLX speech runtime."
        case .missingModels(let names):
            "Download the required local models first: \(names)."
        case .incompleteModel(let name):
            "The downloaded \(name) files failed local integrity checks. Try downloading the model again."
        case .emptyTranscript:
            "No speech was recognized in this file."
        case .noAudioSamples:
            "The audio file contains no readable audio samples."
        case .audioTooQuiet:
            "The audio level is too low or silent for transcription. Increase the recording level and try again."
        case .vadNoSpeech:
            "Speech detection found no usable speech regions in this file."
        case .asrNoSpeech:
            "Speech recognition did not produce a transcript from the detected audio."
        case .noAudioOutput:
            "The speech model did not produce audio."
        }
    }
}
