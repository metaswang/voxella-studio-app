import Foundation
import Testing
@testable import PalmierPro

@Suite("Local model install plan")
struct LocalModelInstallPlanTests {
    @Test func automaticLanguageAndSpeakersIncludeLanguageIDAndDiarization() {
        let catalog = Self.catalog
        let plan = LocalModelInstallPlan.plan(
            languageCode: nil,
            speakerCount: nil,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [
            .whisperLargeV3Turbo8Bit,
            .forcedAligner,
            .sileroVAD,
            .spokenLanguageID,
            .sortformerDiarization,
        ])
        let expectedBytes = plan.items.reduce(Int64(0)) { $0 + $1.byteSize }
        #expect(plan.additionalBytes == expectedBytes)
        #expect(plan.additionalDiskSpaceLabel == "Additional disk space for models: \(LocalModelInstallPlan.formatBytes(expectedBytes))")
        #expect(plan.requiresLicenseAcceptance)
    }

    @Test func specifiedLanguageAndSingleSpeakerOmitOptionalModels() {
        let plan = LocalModelInstallPlan.plan(
            languageCode: "en",
            speakerCount: 1,
            asrModelID: .whisperSmall,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(plan.items.map(\.id) == [.whisperSmall, .forcedAligner, .sileroVAD])
        #expect(plan.missingItems.contains { $0.id == .spokenLanguageID } == false)
        #expect(plan.missingItems.contains { $0.id == .sortformerDiarization } == false)
    }

    @Test func installedModelsAreExcludedFromAdditionalDiskSpace() {
        let installed: Set<LocalModelID> = [.whisperLargeV3Turbo8Bit, .forcedAligner, .sileroVAD]
        let plan = LocalModelInstallPlan.plan(
            languageCode: nil,
            speakerCount: 2,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { installed.contains($0) }
        )
        #expect(plan.missingItems.map(\.id) == [.spokenLanguageID, .sortformerDiarization])
        #expect(plan.additionalBytes == 400_000_000)
        #expect(plan.additionalDiskSpaceLabel.contains("~400 MB"))
    }

    @Test func higherASRPrecisionChangesThePlanSize() {
        let eightBit = LocalModelInstallPlan.plan(
            languageCode: "en",
            speakerCount: 1,
            asrModelID: .whisperLargeV3Turbo8Bit,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        let fp16 = LocalModelInstallPlan.plan(
            languageCode: "en",
            speakerCount: 1,
            asrModelID: .whisperLargeV3TurboFP16,
            catalog: Self.catalog,
            isInstalled: { _ in false }
        )
        #expect(fp16.additionalBytes > eightBit.additionalBytes)
        #expect(fp16.asrModelID == .whisperLargeV3TurboFP16)
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
        let expected = LocalModelInstallPlan.requiredModelIDs(
            languageCode: nil,
            speakerCount: nil,
            asrModelID: .whisperLargeV3Turbo8Bit
        ).compactMap { id in catalog.first { $0.id == id }?.byteSize }
            .reduce(Int64(0), +)
        #expect(plan.additionalBytes == expected)
        #expect(plan.additionalBytes > 0)
    }

    private static var catalog: [LocalModelDescriptor] {
        [
            descriptor(.whisperLargeV3Turbo8Bit, bytes: 1_600_000_000, license: true),
            descriptor(.whisperLargeV3TurboFP16, bytes: 3_000_000_000, license: true),
            descriptor(.whisperSmall, bytes: 500_000_000, license: false),
            descriptor(.forcedAligner, bytes: 80_000_000, license: false),
            descriptor(.sileroVAD, bytes: 10_000_000, license: false),
            descriptor(.spokenLanguageID, bytes: 80_000_000, license: false),
            descriptor(.sortformerDiarization, bytes: 320_000_000, license: false),
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
