import Foundation
import Testing
@testable import PalmierPro

@Suite("AppSupportPaths legacy migrate")
struct AppSupportPathsTests {
    private let fileManager = FileManager.default

    @Test func prefersCurrentWhenItHasUsableWorkbench() throws {
        let base = try makeTempBase()
        defer { try? fileManager.removeItem(at: base) }

        let current = base.appendingPathComponent(AppSupportPaths.folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(AppSupportPaths.legacyFolderName, isDirectory: true)
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":7,"transcriptions":[],"dubs":[]}"#.utf8)
            .write(to: current.appendingPathComponent("workbench.json"))
        try Data(#"{"schemaVersion":7,"transcriptions":[{"id":"legacy"}],"dubs":[]}"#.utf8)
            .write(to: legacy.appendingPathComponent("workbench.json"))

        let resolved = AppSupportPaths.resolved(in: base)
        #expect(resolved.path == current.path)
        let data = try Data(contentsOf: current.appendingPathComponent("workbench.json"))
        #expect(String(data: data, encoding: .utf8)?.contains("\"transcriptions\":[]") == true)
    }

    @Test func migratesWhenCurrentExistsWithoutWorkbenchAndLegacyHasOne() throws {
        let base = try makeTempBase()
        defer { try? fileManager.removeItem(at: base) }

        let current = base.appendingPathComponent(AppSupportPaths.folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(AppSupportPaths.legacyFolderName, isDirectory: true)
        try fileManager.createDirectory(at: current.appendingPathComponent("KnowledgeChat", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: current.appendingPathComponent("Search", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy.appendingPathComponent("Recordings", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy.appendingPathComponent("Dubs", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy.appendingPathComponent("Search", isDirectory: true), withIntermediateDirectories: true)
        try Data("legacy-recording".utf8)
            .write(to: legacy.appendingPathComponent("Recordings/clip.mov"))
        try Data("legacy-search-index".utf8)
            .write(to: legacy.appendingPathComponent("Search/index.db"))
        try Data("current-search-only".utf8)
            .write(to: current.appendingPathComponent("Search/other.db"))
        let legacyWorkbench = Data(#"{"schemaVersion":7,"transcriptions":[{"n":24}],"dubs":[{"n":5}]}"#.utf8)
        try legacyWorkbench.write(to: legacy.appendingPathComponent("workbench.json"))

        let resolved = AppSupportPaths.resolved(in: base)
        #expect(resolved.path == current.path)
        #expect(AppSupportPaths.hasUsableWorkbench(in: current))

        let migrated = try Data(contentsOf: current.appendingPathComponent("workbench.json"))
        #expect(migrated == legacyWorkbench)
        #expect(fileManager.fileExists(atPath: current.appendingPathComponent("Recordings/clip.mov").path))
        #expect(fileManager.fileExists(atPath: current.appendingPathComponent("Dubs").path))
        // Merge Search: keep existing current file, copy missing legacy child
        #expect(fileManager.fileExists(atPath: current.appendingPathComponent("Search/other.db").path))
        #expect(fileManager.fileExists(atPath: current.appendingPathComponent("Search/index.db").path))
        // Legacy must remain untouched (copy, not move/delete)
        #expect(fileManager.fileExists(atPath: legacy.appendingPathComponent("workbench.json").path))
        #expect(fileManager.fileExists(atPath: legacy.appendingPathComponent("Recordings/clip.mov").path))
    }

    @Test func returnsLegacyWhenOnlyLegacyExists() throws {
        let base = try makeTempBase()
        defer { try? fileManager.removeItem(at: base) }

        let legacy = base.appendingPathComponent(AppSupportPaths.legacyFolderName, isDirectory: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":7}"#.utf8)
            .write(to: legacy.appendingPathComponent("workbench.json"))

        let resolved = AppSupportPaths.resolved(in: base)
        #expect(resolved.path == legacy.path)
    }

    @Test func returnsCurrentPathWhenNeitherExists() throws {
        let base = try makeTempBase()
        defer { try? fileManager.removeItem(at: base) }

        let resolved = AppSupportPaths.resolved(in: base)
        #expect(resolved.lastPathComponent == AppSupportPaths.folderName)
        #expect(!fileManager.fileExists(atPath: resolved.path))
    }

    @Test func emptyWorkbenchFileIsNotUsable() throws {
        let base = try makeTempBase()
        defer { try? fileManager.removeItem(at: base) }
        let dir = base.appendingPathComponent("probe", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("workbench.json"))
        #expect(!AppSupportPaths.hasUsableWorkbench(in: dir))
    }

    private func makeTempBase() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("AppSupportPathsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("WorkbenchPersistenceGuard")
struct WorkbenchPersistenceGuardTests {
    @Test func deniesOverwriteOnlyAfterCorruptLoad() {
        #expect(WorkbenchPersistenceGuard.denyOverwrite(after: .corrupt))
        #expect(!WorkbenchPersistenceGuard.denyOverwrite(after: .missing))
        #expect(!WorkbenchPersistenceGuard.denyOverwrite(after: .loaded))
    }
}
