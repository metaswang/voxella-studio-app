import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Local model install plan")
struct LocalModelInstallPlanTests {
    @Test func automaticLanguageRequiresLanguageIDWithoutDiarization() {
        let catalog = Self.catalog
        let plan = LocalModelInstallPlan.plan(
            languageCode: nil,
            speakerCount: nil,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [
            .sileroVAD,
            .qwen3ASR17B8Bit,
            .parakeetTDT06Bv3,
            .whisperLargeV3Turbo8Bit,
            .forcedAligner,
            .spokenLanguageID,
        ])
        let expectedBytes = plan.items.reduce(Int64(0)) { $0 + $1.byteSize }
        #expect(plan.additionalBytes == expectedBytes)
        #expect(plan.additionalDiskSpaceLabel == "Additional disk space for models: \(LocalModelInstallPlan.formatBytes(expectedBytes))")
        #expect(plan.requiresLicenseAcceptance)
    }

    @Test func englishLocksToParakeetWithoutAlignerOrLanguageID() {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "en",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [.sileroVAD, .parakeetTDT06Bv3])
        #expect(plan.missingItems.contains { $0.id == .spokenLanguageID } == false)
        #expect(plan.missingItems.contains { $0.id == .forcedAligner } == false)
        #expect(plan.missingItems.contains { $0.id == .nemotron3Diarization } == false)
    }

    @Test func japaneseLocksToQwenWithoutParakeetOrLanguageID() {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "ja",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [.sileroVAD, .qwen3ASR17B8Bit, .forcedAligner])
        #expect(plan.missingItems.contains { $0.id == .parakeetTDT06Bv3 } == false)
        #expect(plan.missingItems.contains { $0.id == .spokenLanguageID } == false)
    }

    @Test func cantoneseLocksToQwen() {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "yue-CN",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [.sileroVAD, .qwen3ASR17B8Bit, .forcedAligner])
    }

    @Test func installedModelsAreExcludedFromAdditionalDiskSpace() {
        let installed: Set<LocalModelID> = [
            .whisperLargeV3Turbo8Bit, .forcedAligner, .sileroVAD,
            .qwen3ASR17B8Bit, .parakeetTDT06Bv3,
        ]
        let plan = LocalModelInstallPlan.plan(
            languageCode: nil,
            speakerCount: 2,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { installed.contains($0) }
        )
        #expect(plan.missingItems.map(\.id) == [.spokenLanguageID])
        #expect(plan.additionalBytes == 80_000_000)
        #expect(plan.additionalDiskSpaceLabel.contains("~80 MB"))
    }

    @Test func higherWhisperFallbackPrecisionChangesWhisperDomainPlanSize() {
        let eightBit = LocalModelInstallPlan.plan(
            languageCode: "iw",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        let fp16 = LocalModelInstallPlan.plan(
            languageCode: "iw",
            speakerCount: 1,
            asrModelID: .whisperLargeV3TurboFP16,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(fp16.additionalBytes > eightBit.additionalBytes)
        #expect(fp16.asrModelID == .whisperLargeV3TurboFP16)
        #expect(eightBit.items.map(\.id) == [.sileroVAD, .whisperLargeV3Turbo8Bit, .forcedAligner])
    }

    @Test func liveCatalogComputesAutomaticDefaultFromInstalledState() {
        let catalog = LocalModelManager.catalog
        let plan = LocalModelInstallPlan.plan(
            languageCode: nil,
            speakerCount: nil,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.first?.id == .sileroVAD)
        #expect(plan.additionalBytes == plan.items.reduce(Int64(0)) { $0 + $1.byteSize })
        #expect(plan.additionalBytes > 0)
    }

    @Test func installedVADsSatisfyTheRequiredInstallSlots() {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "en",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: LocalModelManager.catalog,
            isInstalled: { $0 == .sileroVAD }
        )
        #expect(plan.items.first?.id == .sileroVAD)
        #expect(plan.items.first?.isInstalled == true)
        #expect(plan.missingItems.contains { $0.id == .sileroVAD } == false)
    }

    @Test func knowledgeQAPlanAlwaysIncludesWeMMEvenForCloudAnswer() {
        let catalog = [
            Self.descriptor(.weMMEmbedding2B4Bit, bytes: 2_000_000_000, license: false),
            Self.descriptor(.qwenTTS17B, bytes: 2_400_000_000, license: false),
            Self.descriptor(.qwen3Reranker06B4Bit, bytes: 350_000_000, license: false),
        ]
        let cloudAnswer = LocalModelInstallPlan.knowledgeQAPlan(
            answerModelID: nil,
            includeReranker: false,
            catalog: catalog,
            isInstalled: { _ in false }
        )
        #expect(cloudAnswer.items.map(\.id) == [.weMMEmbedding2B4Bit])
        #expect(cloudAnswer.missingItems.map(\.id) == [.weMMEmbedding2B4Bit])

        let localAnswer = LocalModelInstallPlan.knowledgeQAPlan(
            answerModelID: .qwenTTS17B,
            includeReranker: true,
            catalog: catalog,
            isInstalled: { $0 == .weMMEmbedding2B4Bit }
        )
        #expect(localAnswer.items.map(\.id) == [.weMMEmbedding2B4Bit, .qwenTTS17B, .qwen3Reranker06B4Bit])
        #expect(localAnswer.missingItems.map(\.id) == [.qwenTTS17B, .qwen3Reranker06B4Bit])
        #expect(
            LocalModelInstallPlan.knowledgeQARequiredIDs(answerModelID: nil, includeReranker: true)
                == [.weMMEmbedding2B4Bit, .qwen3Reranker06B4Bit]
        )
    }

    @Test func dubbingPlanIncludesSelectedVoiceModelAndAlignerWithPinnedRevisions() {
        let plan = LocalModelInstallPlan.dubPlan(
            modelID: .qwenTTS17B,
            catalog: [
                Self.descriptor(.qwenTTS17B, bytes: 2_400_000_000, license: false),
                Self.descriptor(.forcedAligner, bytes: 980_000_000, license: false),
            ],
            isInstalled: { $0 == .forcedAligner }
        )

        #expect(plan.items.map(\.id) == [.qwenTTS17B, .forcedAligner])
        #expect(plan.missingItems.map(\.id) == [.qwenTTS17B])
        #expect(plan.items.allSatisfy { !$0.revision.isEmpty })
        #expect(plan.additionalBytes == 2_400_000_000)
    }

    private static var catalog: [LocalModelDescriptor] {
        [
            descriptor(.qwen3ASR17B8Bit, bytes: 2_80_000_000, license: false),
            descriptor(.parakeetTDT06Bv3, bytes: 750_000_000, license: false),
            descriptor(.whisperLargeV3Turbo8Bit, bytes: 1_600_000_000, license: true),
            descriptor(.whisperLargeV3TurboFP16, bytes: 3_000_000_000, license: true),
            descriptor(.forcedAligner, bytes: 80_000_000, license: false),
            descriptor(.sileroVAD, bytes: 10_000_000, license: false),
            descriptor(.spokenLanguageID, bytes: 80_000_000, license: false),
            descriptor(.nemotron3Diarization, bytes: 320_000_000, license: false),
        ]
    }

    private static func descriptor(
        _ id: LocalModelID,
        bytes: Int64,
        license: Bool
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            title: id.rawValue,
            purpose: "test",
            repository: id.rawValue,
            revision: String(repeating: "a", count: 40),
            weightByteSize: bytes,
            weightSHA256: String(repeating: "b", count: 64),
            byteSize: bytes,
            sizeLabel: "\(bytes)",
            license: license ? "Proprietary" : "MIT",
            requiresLicenseAcceptance: license,
            requiredFor: [.transcribe],
            isRecommended: true
        )
    }
}
