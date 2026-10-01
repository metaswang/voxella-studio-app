import Testing
@testable import VoxstudioPro

@Suite("File I/O naming")
struct FileIOTests {
    @Test func temporaryFilesUseVoxStudioPrefix() {
        let URL = FileIO.temporaryFileURL(pathExtension: "wav")

        #expect(URL.lastPathComponent.hasPrefix("voxstudio-stage-"))
        #expect(!URL.lastPathComponent.contains("palmier"))
    }
}
