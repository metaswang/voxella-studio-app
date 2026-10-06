import Foundation
import Testing
@testable import VoxstudioPro

/// `scripts/migrate-vxst-projects.py` converts legacy `.vxst` packages by renaming
/// `timeline.vxst`, `library.vxst` and `generations.vxst` to the current package files.
/// These tests pin the assumption that the legacy documents already match the current schema.
@Suite("Legacy vxst project migration")
struct LegacyVxstProjectTests {

    private static let timeline = """
    {"viewStates":{"T1":{"zoomScale":0.14,"playheadFrame":3054,"scrollOffsetX":0}},
     "activeTimelineId":"T1","openTimelineIds":["T1"],
     "speakers":[{"id":1,"name":"Speaker 1","color":[0,0.53,1,1],"centroid":[0.1,-0.2]}],
     "timelines":[{"id":"T1","name":"Timeline 1","width":1920,"height":1080,"fps":30,"settingsConfigured":false,
      "tracks":[
       {"id":"TR1","type":"video","muted":false,"hidden":false,"syncLocked":true,"displayHeight":44,"role":{"kind":"standard"},
        "clips":[{"id":"C1","mediaRef":"","mediaType":"text","sourceClipType":"text","startFrame":0,"durationFrames":31,
         "trimStartFrame":0,"trimEndFrame":0,"speed":1,"volume":1,"opacity":1,"fadeInFrames":0,"fadeOutFrames":0,
         "fadeInInterpolation":"linear","fadeOutInterpolation":"linear","edgeRounding":0,"edgeSoftness":0,
         "crop":{"top":0,"left":0,"right":0,"bottom":0},
         "transform":{"centerX":0.5,"centerY":0.9,"width":0.23,"height":0.058,"rotation":0,"flipHorizontal":false,"flipVertical":false},
         "captionGroupId":"G1","textContent":"If you have a lemon,",
         "wordTimings":[{"text":"If","startFrame":0,"endFrame":7},{"text":"lemon,","startFrame":14,"endFrame":31}],
         "textStyle":{"fontName":"Helvetica-Bold","fontSize":48,"fontScale":1,"isBold":true,"isItalic":false,"isUnderlined":false,
          "isStruckThrough":false,"isOverlined":false,"fontCase":"mixed","alignment":"center","tracking":0,"lineSpacing":0,
          "widthScale":1,"heightScale":1,"color":{"r":1,"g":1,"b":1,"a":1},
          "shadow":{"enabled":false,"blur":6,"offsetX":0,"offsetY":-2,"color":{"r":0,"g":0,"b":0,"a":0.6}},
          "border":{"enabled":false,"width":4,"color":{"r":0,"g":0,"b":0,"a":1}},
          "background":{"enabled":false,"paddingX":0,"paddingY":0,"offsetX":0,"offsetY":0,"cornerRadius":0,"outlineWidth":0,
           "color":{"r":0,"g":0,"b":0,"a":0.6},"outlineColor":{"r":0,"g":0,"b":0,"a":1}}}}]},
       {"id":"TR2","type":"video","muted":false,"hidden":false,"syncLocked":true,"displayHeight":44,"role":{"kind":"standard"},
        "clips":[{"id":"C2","mediaRef":"M1","mediaType":"video","sourceClipType":"video","sourceSessionId":"S1",
         "linkGroupId":"L1","startFrame":0,"durationFrames":3118,"trimStartFrame":0,"trimEndFrame":0,"speed":1,"volume":1,
         "opacity":1,"fadeInFrames":0,"fadeOutFrames":0,"fadeInInterpolation":"linear","fadeOutInterpolation":"linear",
         "edgeRounding":0,"edgeSoftness":0,"crop":{"top":0,"left":0,"right":0,"bottom":0},
         "transform":{"centerX":0.5,"centerY":0.5,"width":1,"height":1,"rotation":0,"flipHorizontal":false,"flipVertical":false}}]}
      ]}]}
    """

    private static let library = """
    {"version":2,"folders":[],"entries":[{"id":"M1","name":"demo","type":"video","duration":103.9,
     "source":{"external":{"absolutePath":"/tmp/demo.mp4"}},"sourceWidth":1920,"sourceHeight":1080,
     "sourceFPS":30,"hasAudio":true}]}
    """

    private static let generations = #"{"entries":[],"version":1}"#

    private func makeMigratedPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-vxst-\(UUID().uuidString).voxella", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(Self.timeline.utf8).write(to: package.appendingPathComponent(Project.timelineFilename))
        try Data(Self.library.utf8).write(to: package.appendingPathComponent(Project.manifestFilename))
        try Data(Self.generations.utf8).write(to: package.appendingPathComponent(Project.generationLogFilename))
        return package
    }

    @Test("Renamed legacy documents load with the current models")
    func renamedLegacyDocumentsLoad() throws {
        let package = try makeMigratedPackage()
        defer { try? FileManager.default.removeItem(at: package) }

        let contents = try VideoProject.readProjectPackage(at: package)

        #expect(contents.manifestUnreadable == false)
        #expect(contents.projectFile.activeTimelineId == "T1")
        #expect(contents.projectFile.timelines.first?.tracks.count == 2)
        #expect(contents.projectFile.timelines.first?.tracks.first?.clips.first?.textContent == "If you have a lemon,")
        #expect(contents.manifest?.entries.first?.source == .external(absolutePath: "/tmp/demo.mp4"))
        #expect(contents.generationLog?.entries.isEmpty == true)
    }

    /// Opt-in check over real packages after running the migration script:
    /// `VOXSTUDIO_VALIDATE_PROJECTS_DIR=<folder> swift test --filter LegacyVxstProjectTests`
    @Test("Migrated packages in VOXSTUDIO_VALIDATE_PROJECTS_DIR load",
          .enabled(if: ProcessInfo.processInfo.environment["VOXSTUDIO_VALIDATE_PROJECTS_DIR"] != nil))
    func migratedDirectoryLoads() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOXSTUDIO_VALIDATE_PROJECTS_DIR"]!)
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == Project.fileExtension }
        #expect(!packages.isEmpty)
        for package in packages {
            let contents = try VideoProject.readProjectPackage(at: package)
            #expect(contents.manifestUnreadable == false, "\(package.lastPathComponent): media.json unreadable")
            #expect(!contents.projectFile.timelines.isEmpty, "\(package.lastPathComponent): no timelines")
        }
    }
}
