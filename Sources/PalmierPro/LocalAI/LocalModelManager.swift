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
    case spokenLanguageID
    case forcedAligner
    case sileroVAD
    case mossFormer2SE
    case sortformerDiarization
    case weSpeaker
    case qwenTTS17B
    case weMMEmbedding2B4Bit
    case qwen3Reranker06B4Bit

    var id: String { rawValue }

    /// Product-facing capability name. Keep catalog titles and raw IDs private
    /// to download, diagnostics, and persistence code.
    var userFacingTitle: String {
        switch self {
        case .qwen3ASR17B8Bit, .parakeetTDT06Bv3, .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16:
            "Speech recognition"
        case .spokenLanguageID:
            "Language detection"
        case .forcedAligner:
            "Caption timing"
        case .sileroVAD:
            "Speech detection"
        case .mossFormer2SE:
            "Audio enhancement"
        case .sortformerDiarization, .weSpeaker:
            "Speaker identification"
        case .qwenTTS17B:
            "Voice generation"
        case .weMMEmbedding2B4Bit:
            "Smart search"
        case .qwen3Reranker06B4Bit:
            "Knowledge search"
        }
    }

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

enum LocalModelStorage: Sendable, Equatable {
    case safetensors
    case coreMLBundle(directoryName: String)
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
    let storage: LocalModelStorage

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
        requiredArtifacts: [LocalModelArtifact] = [],
        storage: LocalModelStorage = .safetensors
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
        self.storage = storage
    }

    func needsLicenseAcceptance(accepted: Bool) -> Bool {
        requiresLicenseAcceptance && !accepted
    }

    var userFacingTitle: String { id.userFacingTitle }

    enum LocalFeature: String, Sendable {
        case transcribe
        case dub
        case search
        case knowledgeRanking
        case audioEnhancement
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
    case verifying(progress: Double, message: String)
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .queued, .downloading, .verifying: true
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
            title: "Whisper Large v3 Turbo FP16 (Legacy)",
            purpose: "Previously installed multilingual fallback speech recognition",
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
            isLegacy: true,
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
            title: "Silero VAD v6 Core ML",
            purpose: "Speech detection on CPU Core ML",
            repository: "FluidInference/silero-vad-coreml",
            weightFilename: LocalSpeechVAD.coreMLBundleName,
            revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
            weightByteSize: 0,
            weightSHA256: "",
            byteSize: 1_070_000,
            sizeLabel: "~ 1.1 MB",
            license: "MIT",
            licenseURL: URL(string: "https://huggingface.co/FluidInference/silero-vad-coreml"),
            requiredFor: [.transcribe],
            isRecommended: true,
            storage: .coreMLBundle(directoryName: LocalSpeechVAD.coreMLBundleName)
        ),
        .init(
            id: .mossFormer2SE,
            title: "MossFormer2-SE FP16",
            purpose: "On-device speech enhancement and denoising",
            repository: "starkdmi/MossFormer2-SE-fp16",
            revision: "dd04b1b736b9f49951433b7f051cd8d32eb024b6",
            weightByteSize: 110_652_628,
            weightSHA256: "61e63484df9c2be7e1111ca0346d431422a98b263331021a67c2d7ddb2f67a85",
            byteSize: 110_652_884,
            sizeLabel: "~ 106 MB",
            license: "Apache-2.0",
            licenseURL: URL(string: "https://huggingface.co/starkdmi/MossFormer2-SE-fp16"),
            requiredFor: [.audioEnhancement],
            isRecommended: true,
            requiredArtifacts: [
                .init(
                    filename: "config.json",
                    byteSize: 256,
                    sha256: "b30e89a3309031630e219cae6afc695727b961d3fec542824502b80a2dbbd217"
                ),
            ]
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
        .init(
            id: .weMMEmbedding2B4Bit,
            title: "WeMM Embedding 2B 4-bit",
            purpose: "On-device semantic search over sessions, videos, and images",
            repository: "hfadam/WeMM-Embedding-2B-MLX-4bit",
            revision: "5ce6966e8b62135f771f22104bf9c0d1b6a4c075",
            weightByteSize: 2_007_778_681,
            weightSHA256: "5564d76ebb9ec4cb1f4c28454d04dcab923d54ce834a58c58e38682a0583fd80",
            byteSize: 2_027_856_761,
            sizeLabel: "~ 2.03 GB",
            license: "Apache-2.0",
            licenseURL: URL(string: "https://huggingface.co/tencent/WeMM-Embedding-2B/blob/main/LICENSE"),
            requiredFor: [.search, .knowledgeRanking],
            isRecommended: true,
            requiredArtifacts: [
                .init(filename: "config.json", byteSize: 3_537, sha256: "c5abba86ba31264a074383cd164e23627f0dce1a22bdc6c23c96237af8bd3839"),
                .init(filename: "embedding_chat_template.jinja", byteSize: 1_086, sha256: "7c3df2aab83ab9096428ec27b6b99ad87c4790418b830d119957634f28c677ba"),
                .init(filename: "tokenizer.json", byteSize: 19_990_378, sha256: "40e444c744512f423da4c8443c47c21e22ff76056ba4e9796a81c04c13a9daf0"),
                .init(filename: "tokenizer_config.json", byteSize: 1_171, sha256: "b34b3377d4a32eda1a4898aea3f738a98e51aaf8038cc4f465b015d11298c8d1"),
                .init(filename: "model.safetensors.index.json", byteSize: 81_908, sha256: "fbb49af67f30c6ebf7a2a260403b5759c16f29ce6670c90389467d6bedd059f8"),
            ]
        ),
        .init(
            id: .qwen3Reranker06B4Bit,
            title: "Qwen3 Reranker 0.6B 4-bit",
            purpose: "On-device relevance ranking for knowledge-base evidence",
            repository: "mlx-community/Qwen3-Reranker-0.6B-4bit",
            revision: "5f324548f1d20c2b5a450f126fc6ef2fb1126524",
            weightByteSize: 335_296_756,
            weightSHA256: "1d212560a5b1c36186787fdae19f11f20fecfc29bef91522e12a8e0d118f4545",
            byteSize: 346_711_934,
            sizeLabel: "~ 347 MB",
            license: "Apache-2.0",
            licenseURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-Reranker-0.6B-4bit"),
            requiredFor: [.knowledgeRanking],
            isRecommended: true,
            requiredArtifacts: [
                .init(filename: "config.json", byteSize: 1_021, sha256: "09adff58b65e9305009c9caa4923b3365b18dd2f84135b44168aaf869278bea4"),
                .init(filename: "generation_config.json", byteSize: 214, sha256: "81051cd3f6e77013827148d0b8a6ead93f8ac390d5ab805f849199f0af6a08db"),
                .init(filename: "model.safetensors.index.json", byteSize: 49_770, sha256: "90d82744cdb6b7d093f0b812fc21a49b6ffa9d0084a45428f0cfd01eb4adbe12"),
                .init(filename: "tokenizer.json", byteSize: 11_422_650, sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
                .init(filename: "tokenizer_config.json", byteSize: 377, sha256: "1689852cc9c45010de040c8302a8acdc0d2c4c6c740dd7e9dd0a8c704e16eada"),
            ]
        ),
    ]

    var states: [LocalModelID: LocalModelDownloadState] = [:]
    private(set) var activeASRModelID: LocalModelID
    private(set) var hasLoadedInstallationStates = false
    private var activeDownloads: [LocalModelID: Task<Void, Never>] = [:]
    private var queuedEntries: [(id: LocalModelID, lane: LocalModelDownloadDemand)] = []
    private var nextLaneCursor = 0
    private var downloadDemand: [LocalModelID: Set<LocalModelDownloadDemand>] = [:]
    private var authorizationRequests: [LocalModelID: UUID] = [:]
    private var authorizationRevocations: [LocalModelID: Task<Void, Never>] = [:]
    private let authorizationStore: LocalModelDownloadAuthorizationStore
    private(set) var cancelledFeatures: Set<LocalPreparationFeature> = []
    private var transferMetrics: [LocalModelID: LocalModelTransferProgress] = [:]
    private var lastProgressRefresh: [LocalModelID: ContinuousClock.Instant] = [:]
    private var waiters: [LocalModelID: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var preparationObservers: [UUID: (ids: [LocalModelID], handler: (String) -> Void)] = [:]
    private var pendingASRActivation: Set<LocalModelID> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var removals: [LocalModelID: Task<Void, Never>] = [:]
    private var searchModelGeneration = 0

    init(restoreDownloads: Bool = true,
         authorizationStore: LocalModelDownloadAuthorizationStore = .shared) {
        self.authorizationStore = authorizationStore
        activeASRModelID = Self.preferredASRModelID()
        guard restoreDownloads else { return }
        refreshInstallationStates()
        Task { [weak self] in
            await self?.restoreAuthorizedDownloads()
        }
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
            states[id] = .failed("Prepare speech recognition before selecting it.")
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
        return required.allSatisfy { id in
            state(for: id).isInstalled
        }
    }

    func ensureTranscriptionModels(
        languageCode: String?,
        speakerCount: Int?,
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        let required = LocalModelInstallPlan.requiredModelIDs(
            languageCode: languageCode,
            speakerCount: speakerCount,
            whisperFallbackModelID: activeASRModelID
        )
        try await ensureModels(required, onProgress: onProgress)
    }

    func ensureDubModels(
        modelID: LocalModelID,
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        try await ensureModels([modelID, .forcedAligner], onProgress: onProgress)
    }

    func ensureKnowledgeQAModels(
        answerModelID: LocalModelID? = nil,
        includeReranker: Bool = false,
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        let ids = LocalModelInstallPlan.knowledgeQARequiredIDs(
            answerModelID: answerModelID,
            includeReranker: includeReranker
        )
        try await ensureModels(ids, onProgress: onProgress)
    }

    func ensureAudioEnhancementModel(
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        try await ensureModels([.mossFormer2SE], onProgress: onProgress)
    }

    private func transcriptionDownloadProgress(for ids: [LocalModelID]) -> Double {
        guard !ids.isEmpty else { return 1 }
        let sum = ids.reduce(0.0) { partial, id in
            switch state(for: id) {
            case .installed:
                return partial + 1
            case .downloading(let progress, _), .verifying(let progress, _):
                return partial + min(max(progress, 0), 1)
            default:
                return partial
            }
        }
        return sum / Double(ids.count)
    }

    private func ensureModels(
        _ ids: [LocalModelID],
        onProgress: ((String) -> Void)?
    ) async throws {
        let required = Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
        let missing = required.filter { !state(for: $0).isInstalled }
        guard !missing.isEmpty else { return }
        for id in missing {
            acceptRequiredLicenseIfNeeded(id)
        }

        let observerID = UUID()
        if let onProgress {
            preparationObservers[observerID] = (required, onProgress)
            notifyPreparationObserver(observerID)
        }
        defer { preparationObservers.removeValue(forKey: observerID) }

        for id in missing {
            try Task.checkCancellation()
            // Task demand must survive cancellation of the optional setup feature.
            download(id, demand: .explicit)
        }
        for id in missing {
            try Task.checkCancellation()
            try await waitForModel(id)
        }
    }

    private func waitForModel(_ id: LocalModelID) async throws {
        if state(for: id).isInstalled { return }
        if case .failed(let message) = state(for: id) {
            throw LocalAIError.modelPreparationFailed(message)
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if state(for: id).isInstalled {
                    continuation.resume()
                } else if case .failed(let message) = state(for: id) {
                    continuation.resume(throwing: LocalAIError.modelPreparationFailed(message))
                } else if !state(for: id).isBusy {
                    continuation.resume(throwing: LocalAIError.speechModelsDownloadFailed)
                } else {
                    waiters[id, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, for: id)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for id: LocalModelID) {
        guard let continuation = waiters[id]?.removeValue(forKey: waiterID) else { return }
        if waiters[id]?.isEmpty == true { waiters[id] = nil }
        continuation.resume(throwing: CancellationError())
    }

    private func settleWaiters(for id: LocalModelID) {
        guard let continuations = waiters.removeValue(forKey: id)?.values else { return }
        let result: Result<Void, Error>
        switch state(for: id) {
        case .installed:
            result = .success(())
        case .failed(let message):
            result = .failure(LocalAIError.modelPreparationFailed(message))
        default:
            result = .failure(CancellationError())
        }
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func notifyPreparationObservers() {
        for id in preparationObservers.keys {
            notifyPreparationObserver(id)
        }
    }

    private func notifyPreparationObserver(_ observerID: UUID) {
        guard let observer = preparationObservers[observerID] else { return }
        observer.handler(preparationStatus(for: observer.ids).userFacingMessage)
    }

    private func restoreAuthorizedDownloads() async {
        LocalModelChunkStore.shared.pruneExpired()
        let records: [LocalModelDownloadAuthorizationStore.Record]
        do {
            records = try await authorizationStore.records()
        } catch {
            Log.transcription.error("model download recovery failed error=\(error.localizedDescription)")
            return
        }
        let recoveredModels = records.compactMap { record in
            Self.catalog.first { $0.id == record.id }
        }
        let installedIDs = await Task.detached(priority: .utility) {
            Set(recoveredModels.filter { Self.isInstalled($0) }.map(\.id))
        }.value
        var valid: [LocalModelDownloadAuthorizationStore.Record] = []
        for record in records {
            guard let model = Self.catalog.first(where: { $0.id == record.id }),
                  model.revision == record.revision,
                  !installedIDs.contains(record.id) else { continue }
            acceptRequiredLicenseIfNeeded(record.id)
            valid.append(record)
        }
        try? await authorizationStore.replace(with: valid)
        for record in valid {
            let features = LocalPreparationFeature.allCases.filter {
                OnboardingState.shared.selectedFeatures.contains($0)
                    && $0.requiredIDs(asrModelID: activeASRModelID).contains(record.id)
            }
            let demands: [LocalModelDownloadDemand] = features.isEmpty ? [.explicit]
                : features.filter { !cancelledFeatures.contains($0) }.map { .feature($0) }
            guard let lane = demands.first else { continue }
            for demand in demands { addDemand(record.id, demand) }
            enqueueAuthorizedDownload(record.id, lane: lane)
        }
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
                Self.pruneUnusedCachedModels()
                return Dictionary(
                    catalog.map { ($0.id, Self.isInstalled($0)) },
                    uniquingKeysWith: { current, _ in current }
                )
            }.value
            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            let searchWasInstalled = self.state(for: SearchIndexConfig.modelID).isInstalled
            if self.removals[SearchIndexConfig.modelID] == nil,
               self.activeDownloads[SearchIndexConfig.modelID] == nil,
               !searchWasInstalled,
               installed[SearchIndexConfig.modelID] == true {
                await WeMMEmbeddingProvider.shared.resume(generation: self.nextSearchModelGeneration())
            }
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            for model in catalog
                where self.activeDownloads[model.id] == nil && !self.isQueued(model.id)
                    && self.authorizationRequests[model.id] == nil
                    && self.removals[model.id] == nil {
                self.states[model.id] = installed[model.id] == true ? .installed : .notInstalled
            }
            self.hasLoadedInstallationStates = true
            if !searchWasInstalled, self.state(for: SearchIndexConfig.modelID).isInstalled {
                SearchIndexCoordinator.sweepAll()
            }
        }
    }

    func waitForInstallationRefresh() async {
        await refreshTask?.value
    }

    private func nextSearchModelGeneration() -> Int {
        searchModelGeneration += 1
        return searchModelGeneration
    }

    func download(_ id: LocalModelID) {
        download(id, demand: .explicit)
    }

    func download(_ id: LocalModelID, demand: LocalModelDownloadDemand) {
        authorizeAndQueue(id, activateWhenInstalled: false, lane: demand)
    }

    func downloadAndUseASRModel(_ id: LocalModelID) {
        guard id.isWhisperFallbackModel else {
            download(id)
            return
        }
        authorizeAndQueue(id, activateWhenInstalled: true, lane: .explicit)
    }

    private func authorizeAndQueue(
        _ id: LocalModelID,
        activateWhenInstalled: Bool,
        lane: LocalModelDownloadDemand
    ) {
        guard removals[id] == nil else { return }
        guard !state(for: id).isInstalled else {
            if activateWhenInstalled { _ = useASRModel(id) }
            return
        }
        let model = descriptor(for: id)
        acceptRequiredLicenseIfNeeded(id)
        addDemand(id, lane)
        if activateWhenInstalled { pendingASRActivation.insert(id) }
        // Register pending work synchronously so it can be cancelled before authorization finishes.
        guard authorizationRequests[id] == nil else { return }
        if let active = activeDownloads[id], !active.isCancelled { return }
        guard !isQueued(id) else { return }
        let request = UUID()
        authorizationRequests[id] = request
        states[id] = .queued
        let previousDownload = activeDownloads[id]
        let revocation = authorizationRevocations[id]
        Task { [weak self] in
            guard let self else { return }
            await previousDownload?.value
            await revocation?.value
            guard self.authorizationRequests[id] == request else { return }
            do {
                try await self.authorizationStore.authorize(
                    .init(id: id, revision: model.revision)
                )
                guard self.authorizationRequests[id] == request else { return }
                self.authorizationRequests[id] = nil
                guard let currentLane = self.downloadDemand[id]?.first else { return }
                self.enqueueAuthorizedDownload(id, lane: currentLane)
            } catch {
                guard self.authorizationRequests[id] == request else { return }
                self.authorizationRequests[id] = nil
                Log.transcription.error("resource authorization failed id=\(id.rawValue) error=\(error.localizedDescription)")
                self.states[id] = .failed("The resource could not be authorized. Try again.")
                self.pendingASRActivation.remove(id)
                self.settleWaiters(for: id)
                self.notifyPreparationObservers()
            }
        }
    }

    private func addDemand(_ id: LocalModelID, _ demand: LocalModelDownloadDemand) {
        downloadDemand[id, default: []].insert(demand)
    }

    private func isQueued(_ id: LocalModelID) -> Bool {
        queuedEntries.contains { $0.id == id }
    }

    private func enqueueAuthorizedDownload(_ id: LocalModelID, lane: LocalModelDownloadDemand) {
        guard removals[id] == nil, !state(for: id).isInstalled else { return }
        if activeDownloads[id] != nil || isQueued(id) { return }
        states[id] = .queued
        queuedEntries.append((id, lane))
        notifyPreparationObservers()
        startNextDownloadIfNeeded()
    }

    private func dequeueFair() -> LocalModelID? {
        guard !queuedEntries.isEmpty else { return nil }
        var lanes: [LocalModelDownloadDemand] = []
        for entry in queuedEntries where !lanes.contains(entry.lane) {
            lanes.append(entry.lane)
        }
        guard !lanes.isEmpty else { return nil }
        let start = nextLaneCursor % lanes.count
        for offset in 0..<lanes.count {
            let lane = lanes[(start + offset) % lanes.count]
            if let index = queuedEntries.firstIndex(where: { $0.lane == lane }) {
                let id = queuedEntries[index].id
                queuedEntries.removeAll { $0.id == id }
                nextLaneCursor = start + offset + 1
                return id
            }
        }
        return nil
    }

    private func startNextDownloadIfNeeded() {
        while activeDownloads.count < LocalModelDownloadLimits.maximumConcurrentModels {
            guard let id = dequeueFair() else { return }
            startDownload(id)
        }
    }

    private func startDownload(_ id: LocalModelID) {
        activeDownloads[id] = Task { [weak self] in
            guard let self else { return }
            let model = self.descriptor(for: id)
            let resourceKey = "\(model.repository)@\(model.revision)"
            do {
                try await LocalModelResourceLock.shared.withLock(for: resourceKey) { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.performDownload(id)
                }
                let installed = await Task.detached(priority: .utility) {
                    Self.isInstalled(model)
                }.value
                guard installed else {
                    throw LocalAIError.incompleteModel(model.userFacingTitle)
                }
                try Task.checkCancellation()
                if id == SearchIndexConfig.modelID {
                    await WeMMEmbeddingProvider.shared.resume(generation: self.nextSearchModelGeneration())
                    try Task.checkCancellation()
                }
                self.states[id] = .installed
                self.transferMetrics[id] = nil
                self.downloadDemand[id] = nil
                if self.pendingASRActivation.remove(id) != nil {
                    self.useASRModel(id)
                }
                if id == .weMMEmbedding2B4Bit {
                    SessionIndexCoordinator.shared.resumeEmbeddings()
                    SearchIndexCoordinator.sweepAll()
                }
                try? await self.authorizationStore.revoke(id)
                LocalModelChunkStore.shared.remove(repository: model.repository, revision: model.revision)
            } catch let error where error is CancellationError || Task.isCancelled
                || (error as? URLError)?.code == .cancelled {
                self.pendingASRActivation.remove(id)
                let installed = await Task.detached(priority: .utility) {
                    Self.isInstalled(model)
                }.value
                if self.removals[id] == nil {
                    self.states[id] = installed ? .installed
                        : (self.authorizationRequests[id] == nil ? .notInstalled : .queued)
                }
                self.transferMetrics[id] = nil
                LocalModelChunkStore.shared.markCancelled(repository: model.repository, revision: model.revision)
                try? await self.authorizationStore.revoke(id)
            } catch {
                self.pendingASRActivation.remove(id)
                let message = Self.userFacingDownloadError(error)
                Log.transcription.error(
                    "local model download failed id=\(id.rawValue) error=\(message)"
                )
                self.states[id] = .failed(message)
                self.transferMetrics[id] = nil
            }
            self.activeDownloads[id] = nil
            if self.authorizationRequests[id] == nil { self.settleWaiters(for: id) }
            self.notifyPreparationObservers()
            self.startNextDownloadIfNeeded()
        }
    }

    func downloadRecommended() {
        Task { [weak self] in
            guard let self else { return }
            let ids = Self.catalog.filter(\.isRecommended).map(\.id)
            try? await self.ensureModels(ids, onProgress: nil)
        }
    }

    func cancel(_ id: LocalModelID) {
        pendingASRActivation.remove(id)
        downloadDemand[id] = nil
        authorizationRequests[id] = nil
        transferMetrics[id] = nil
        let model = descriptor(for: id)
        let hadTransfer = activeDownloads[id] != nil || isQueued(id)
        queuedEntries.removeAll { $0.id == id }
        activeDownloads[id]?.cancel()
        if !state(for: id).isInstalled { states[id] = .notInstalled }
        settleWaiters(for: id)
        notifyPreparationObservers()
        if hadTransfer {
            LocalModelChunkStore.shared.markCancelled(repository: model.repository, revision: model.revision)
        }
        authorizationRevocations[id] = Task {
            try? await self.authorizationStore.revoke(id)
        }
        startNextDownloadIfNeeded()
    }

    func beginPreparingFeature(_ feature: LocalPreparationFeature) {
        cancelledFeatures.remove(feature)
    }

    func cancelFeature(_ feature: LocalPreparationFeature) {
        cancelledFeatures.insert(feature)
        // Release only this feature's requests, including authorization and queued work.
        // Shared resources keep downloading for their remaining consumers.
        let ids = Set(feature.requiredIDs(asrModelID: activeASRModelID)).union(
            downloadDemand.keys.filter { downloadDemand[$0]?.contains(.feature(feature)) == true }
        )
        for id in ids {
            if downloadDemand[id]?.contains(.feature(feature)) == true {
                downloadDemand[id]?.remove(.feature(feature))
                if downloadDemand[id]?.isEmpty == true { cancel(id) }
            }
        }
    }

    func isLicenseAccepted(_ id: LocalModelID) -> Bool {
        UserDefaults.standard.bool(forKey: "voxella.local-model-license.\(id.rawValue)")
    }

    func acceptLicense(_ id: LocalModelID) {
        UserDefaults.standard.set(true, forKey: "voxella.local-model-license.\(id.rawValue)")
    }

    private func acceptRequiredLicenseIfNeeded(_ id: LocalModelID) {
        let model = descriptor(for: id)
        guard model.needsLicenseAcceptance(accepted: isLicenseAccepted(id)) else { return }
        acceptLicense(id)
    }

    func remove(_ id: LocalModelID) {
        guard removals[id] == nil else { return }
        guard !isActiveASRModel(id) else {
            states[id] = .failed("Choose another speech recognition option before removing this one.")
            return
        }
        cancel(id)
        let model = descriptor(for: id)
        let download = activeDownloads[id]
        let searchGeneration = id == SearchIndexConfig.modelID ? nextSearchModelGeneration() : 0
        refreshGeneration += 1
        states[id] = .queued
        removals[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.removals[id] = nil }
            await download?.value
            do {
                if id == SearchIndexConfig.modelID {
                    try await WeMMEmbeddingProvider.shared.suspend(generation: searchGeneration)
                    await SearchIndexCoordinator.resetAll()
                }
                try await LocalModelResourceLock.shared.withLock(for: "\(model.repository)@\(model.revision)") {
                    try await LocalModelInstallationGate.shared.withPermit {
                        try await Self.removeModelFiles(model)
                    }
                }
                LocalModelChunkStore.shared.remove(repository: model.repository, revision: model.revision)
                self.states[id] = .notInstalled
            } catch {
                Log.transcription.error("resource removal failed id=\(id.rawValue) error=\(error.localizedDescription)")
                self.states[id] = .failed("The resource could not be removed. Try again.")
            }
        }
    }

    @concurrent private static func removeModelFiles(_ model: LocalModelDescriptor) async throws {
        let directory = try directory(for: model)
        try await removeDirectoryIfPresent(directory)
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
        let base = AppSupportPaths.caches()
            .appendingPathComponent("Models", isDirectory: true)
        return base.appendingPathComponent(model.repository.replacingOccurrences(of: "/", with: "_"))
        #endif
    }

    nonisolated static func isInstalled(_ model: LocalModelDescriptor) -> Bool {
        guard let directory = try? directory(for: model),
              let modelManifest = manifest(in: directory),
              modelManifest.repository == model.repository,
              modelManifest.revision == model.revision else { return false }
        if case .coreMLBundle(let directoryName) = model.storage {
            return coreMLBundleIsValid(in: directory, directoryName: directoryName)
        }
        guard weightFileSize(in: directory, filename: model.weightFilename) == model.weightByteSize,
              modelManifest.weightSHA256 == model.weightSHA256 else { return false }
        if !model.requiredArtifacts.isEmpty {
            let expectedHashes = artifactHashes(for: model)
            guard modelManifest.artifactSHA256 == expectedHashes,
                  model.requiredArtifacts.allSatisfy({ artifact in
                      weightFileSize(in: directory, filename: artifact.filename) == artifact.byteSize
                  }) else { return false }
        }
        if model.id == .qwenTTS17B {
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

    nonisolated static func isInstalled(_ id: LocalModelID) -> Bool {
        guard let model = catalog.first(where: { $0.id == id }) else { return false }
        return isInstalled(model)
    }

    private nonisolated static func hasWeights(in directory: URL) -> Bool {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(LocalSpeechVAD.coreMLBundleName).path
        ) {
            return true
        }
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
        if mainWeightVerified, model.storage == .safetensors {
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
        } else if id == .qwenTTS17B {
            0...0.82
        } else {
            0...1
        }
        if !mainWeightVerified {
            try Task.checkCancellation()
            states[id] = .downloading(progress: 0, message: "Downloading \(model.userFacingTitle.lowercased()) resources…")
            try await Self.downloadPinnedSnapshot(
                repository: model.repository,
                revision: model.revision,
                to: directory,
                matching: Self.snapshotGlobs(for: id),
                modelID: id,
                estimatedBytes: model.byteSize
            ) { [weak self] progress in
                self?.updateTransferProgress(
                    id: id,
                    progress: progress,
                    range: mainRange,
                    messagePrefix: "Downloading \(model.userFacingTitle.lowercased())"
                )
            }
            try Task.checkCancellation()
            states[id] = .verifying(progress: mainRange.upperBound, message: "Verifying downloaded resources…")
            let downloadedDirectory = directory
            mainWeightVerified = try await LocalModelInstallationGate.shared.withPermit {
                let weightVerified: Bool
                if case .coreMLBundle(let directoryName) = model.storage {
                    weightVerified = await Task.detached(priority: .utility) {
                        Self.coreMLBundleIsValid(
                            in: downloadedDirectory,
                            directoryName: directoryName
                        )
                    }.value
                } else {
                    weightVerified = await Self.verifyWeight(
                        in: downloadedDirectory,
                        filename: model.weightFilename,
                        expectedBytes: model.weightByteSize,
                        expectedSHA256: model.weightSHA256
                    )
                }
                let coreFilesVerified = await Task.detached(priority: .utility) {
                    Self.coreFilesExist(for: id, in: downloadedDirectory)
                }.value
                return weightVerified && coreFilesVerified
            }
        } else {
            try Task.checkCancellation()
            states[id] = .downloading(progress: mainRange.upperBound, message: "Downloaded resources are ready…")
        }
        guard mainWeightVerified else {
            throw LocalAIError.incompleteModel(model.userFacingTitle)
        }
        if !model.requiredArtifacts.isEmpty || model.asrSpecification != nil || id.asrEngine != nil {
            try Task.checkCancellation()
            states[id] = .verifying(progress: 0.94, message: "Verifying feature resources…")
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
                throw LocalAIError.incompleteModel(model.userFacingTitle)
            }
            try Task.checkCancellation()
            states[id] = .downloading(progress: 0.98, message: "Finishing setup…")
        }
        try Task.checkCancellation()

        if id == .qwenTTS17B {
            let tokenizer = try HuggingFaceDownloader.getCacheDirectory(for: Self.ttsTokenizerRepository)
            try Task.checkCancellation()
            states[id] = .downloading(progress: 0.82, message: "Finishing voice resources…")
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
                    matching: Self.weightGlobs(additionalFiles: []),
                    modelID: id,
                    estimatedBytes: Self.ttsTokenizerWeightByteSize
                ) { [weak self] progress in
                    self?.updateTransferProgress(
                        id: id,
                        progress: progress,
                        range: 0.82...1,
                        messagePrefix: "Finishing voice resources"
                    )
                }
                tokenizerVerified = await Self.verifyWeight(
                    in: tokenizerDirectory,
                    expectedBytes: Self.ttsTokenizerWeightByteSize,
                    expectedSHA256: Self.ttsTokenizerWeightSHA256
                )
                guard tokenizerVerified else {
                    throw LocalAIError.incompleteModel("Voice generation")
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
        case .qwenTTS17B: [Self.ttsTokenizerRepository: Self.ttsTokenizerRevision]
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

    private nonisolated static func snapshotGlobs(for id: LocalModelID) -> [String] {
        let extras = additionalFiles(for: id)
        guard let model = catalog.first(where: { $0.id == id }),
              case .coreMLBundle = model.storage else {
            return weightGlobs(additionalFiles: extras)
        }
        return extras
    }

    private nonisolated static func pruneUnusedCachedModels() {
        let retained = Set(catalog.map(\.repository)).union([ttsTokenizerRepository])
        let modelsRoot = speechCacheRoot().appendingPathComponent("models", isDirectory: true)
        let fileManager = FileManager.default
        guard let owners = try? fileManager.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var removed: [String] = []
        for owner in owners {
            guard let repos = try? fileManager.contentsOfDirectory(
                at: owner,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for repoDirectory in repos {
                let repository = "\(owner.lastPathComponent)/\(repoDirectory.lastPathComponent)"
                guard !retained.contains(repository) else { continue }
                try? fileManager.removeItem(at: repoDirectory)
                removed.append(repository)
            }
            if let remaining = try? fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil),
               remaining.isEmpty {
                try? fileManager.removeItem(at: owner)
            }
        }
        if !removed.isEmpty {
            Log.transcription.notice(
                "pruned unused local model caches repos=\(removed.sorted().joined(separator: ","))"
            )
        }
    }

    private nonisolated static func speechCacheRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["QWEN3_CACHE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech", isDirectory: true)
    }

    private nonisolated static func additionalFiles(for id: LocalModelID) -> [String] {
        switch id {
        case .whisperLargeV3Turbo8Bit, .whisperLargeV3TurboFP16,
             .qwen3ASR17B8Bit, .parakeetTDT06Bv3, .weMMEmbedding2B4Bit,
             .qwen3Reranker06B4Bit:
            catalog.first(where: { $0.id == id })?.requiredArtifacts.map(\.filename) ?? []
        case .forcedAligner:
            ["vocab.json", "merges.txt", "tokenizer_config.json", "quantize_config.json"]
        case .qwenTTS17B:
            ["vocab.json", "merges.txt", "tokenizer_config.json"]
        case .sileroVAD:
            LocalSpeechVAD.requiredBundleFiles.map { "\(LocalSpeechVAD.coreMLBundleName)/\($0)" }
        case .mossFormer2SE:
            catalog.first(where: { $0.id == id })?.requiredArtifacts.map(\.filename) ?? []
        case .spokenLanguageID, .sortformerDiarization, .weSpeaker:
            []
        }
    }

    private nonisolated static func coreFilesExist(for id: LocalModelID, in directory: URL) -> Bool {
        if let model = catalog.first(where: { $0.id == id }),
           case .coreMLBundle(let directoryName) = model.storage {
            return coreMLBundleIsValid(in: directory, directoryName: directoryName)
        }
        let files = additionalFiles(for: id)
        let required = ["config.json"] + (id.isASRModel ? files : files.filter { $0 != "generation_config.json" })
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private nonisolated static func coreMLBundleIsValid(
        in directory: URL,
        directoryName: String
    ) -> Bool {
        let bundle = directory.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { return false }
        return LocalSpeechVAD.requiredBundleFiles.allSatisfy { relative in
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent(relative).path)
        }
    }

    private nonisolated static func weightGlobs(additionalFiles: [String]) -> [String] {
        var globs = ["config.json", "*.safetensors", "model.safetensors.index.json"]
        for file in additionalFiles where !globs.contains(file) { globs.append(file) }
        return globs
    }

    @concurrent
    private static func downloadPinnedSnapshot(
        repository: String,
        revision: String,
        to directory: URL,
        matching globs: [String],
        modelID: LocalModelID,
        estimatedBytes: Int64,
        progressHandler: @escaping @MainActor @Sendable (LocalModelTransferProgress) -> Void
    ) async throws {
        #if BUNDLED_SPEECH
        guard let repositoryID = Repo.ID(rawValue: repository) else {
            throw URLError(.badURL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await LocalModelDownload.transferSnapshot(
            repository: repositoryID,
            revision: revision,
            to: directory,
            matching: globs,
            modelID: modelID,
            estimatedBytes: estimatedBytes,
            progressHandler: progressHandler
        )
        #else
        throw LocalAIError.modelsUnavailable
        #endif
    }

    private nonisolated static func userFacingDownloadError(_ error: Error) -> String {
        LocalModelDownload.message(for: error)
    }

    private func updateTransferProgress(
        id: LocalModelID,
        progress: LocalModelTransferProgress,
        range: ClosedRange<Double>,
        messagePrefix: String
    ) {
        guard activeDownloads[id]?.isCancelled != true else { return }
        let now = ContinuousClock.now
        if let last = lastProgressRefresh[id], now - last < LocalModelDownloadLimits.progressRefreshInterval, progress.fraction < 1 {
            return
        }
        lastProgressRefresh[id] = now
        transferMetrics[id] = progress
        let bytes = "\(LocalModelInstallPlan.formatBytes(progress.completedBytes)) of \(LocalModelInstallPlan.formatBytes(progress.totalBytes))"
        let speed: String
        if let rate = progress.bytesPerSecond, rate > 1 {
            speed = " · \(LocalModelInstallPlan.formatBytes(Int64(rate)))/s"
        } else {
            speed = ""
        }
        let normalized = progress.fraction
        states[id] = .downloading(
            progress: range.lowerBound + normalized * (range.upperBound - range.lowerBound),
            message: "\(messagePrefix)… \(bytes)\(speed)"
        )
        notifyPreparationObservers()
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
        var hashes = Dictionary(
            model.requiredArtifacts.map { ($0.filename, $0.sha256) },
            uniquingKeysWith: { current, _ in current }
        )
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
    case speechModelsDownloadFailed
    case modelPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            "Local speech processing is unavailable in this build. Install the full app to use this feature."
        case .missingModels:
            "Local transcription is not ready. Retry to download the required resources."
        case .incompleteModel:
            "Downloaded speech resources could not be verified. Download them again."
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
            "Voice generation did not produce audio."
        case .speechModelsDownloadFailed:
            "Speech resources could not be downloaded. Check the network and retry."
        case .modelPreparationFailed:
            "The local feature could not be prepared. Try again."
        }
    }
}
