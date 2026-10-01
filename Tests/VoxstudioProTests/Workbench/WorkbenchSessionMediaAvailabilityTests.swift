import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Workbench session media availability")
struct WorkbenchSessionMediaAvailabilityTests {
    @Test func existingSourceMediaIsAvailable() throws {
        let url = temporaryFileURL()
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!WorkbenchSession.isSourceMediaMissing(at: url))
    }

    @Test func missingSourceMediaIsDetected() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        #expect(WorkbenchSession.isSourceMediaMissing(at: url))
    }

    @Test func remoteOnlySessionWithoutLocalSourceIsNotMarkedMissing() {
        #expect(!WorkbenchSession.isSourceMediaMissing(at: nil))
    }

    private func temporaryFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("source-\(UUID().uuidString).m4a")
    }
}
