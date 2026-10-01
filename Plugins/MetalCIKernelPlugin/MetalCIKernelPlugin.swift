import Foundation
import PackagePlugin

/// Compiles Core Image Metal kernels (`Metal/*.metal`) into `.metallib` resources.
@main
struct MetalCIKernelPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let metalDir = context.package.directoryURL.appending(path: "Metal")
        let builder = context.package.directoryURL.appending(path: "scripts/build_metal.py")
        let plist = context.package.directoryURL.appending(path: "Sources/VoxstudioPro/Resources/Info.plist")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: metalDir.path()))?
            .filter { $0.hasSuffix(".metal") } ?? []

        return names.map { file in
            let stem = (file as NSString).deletingPathExtension
            let metal = metalDir.appending(path: file)
            let metallib = context.pluginWorkDirectoryURL.appending(path: "\(stem).metallib")
            return .buildCommand(
                displayName: "Compile CI kernel \(file)",
                executable: URL(filePath: "/usr/bin/python3"),
                arguments: [
                    builder.path(), "ci", "--source", metal.path(), "--output", metallib.path(),
                ],
                inputFiles: names.map { metalDir.appending(path: $0) } + [builder, plist],
                outputFiles: [metallib])
        }
    }
}
