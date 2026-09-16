import Foundation

enum AppIdentity {
    static let productName = "VoxStudio"
}

enum AppSupportPaths {
    static let folderName = "VoxStudio"
    static let legacyFolderName = "Voxella Studio"
    /// Relative items copied from legacy Application Support when the new folder
    /// exists but has no usable workbench (empty rename stub must not orphan data).
    static let migratableRelativeItems: [String] = [
        "workbench.json",
        "Clips",
        "Dubs",
        "Recordings",
        "Search",
        "VoiceLibrary",
        "NetVideo",
        "Diagnostics",
        "ModelDownloads",
        "KnowledgeChat",
        "Samples",
    ]

    private static let migrateLock = NSLock()

    nonisolated static func applicationSupport() -> URL {
        resolved(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    nonisolated static func caches() -> URL {
        resolved(in: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    nonisolated static func documents() -> URL {
        resolved(in: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    nonisolated static func logs() -> URL {
        resolved(
            in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs", isDirectory: true)
        )
    }

    /// Prefer `VoxStudio` when present. If it exists without a usable workbench but
    /// legacy `Voxella Studio` has `workbench.json`, one-shot **copy** migrate into
    /// `VoxStudio` (legacy left intact), then return the current folder.
    nonisolated static func resolved(in base: URL) -> URL {
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let fileManager = FileManager.default
        let currentExists = fileManager.fileExists(atPath: current.path)
        let legacyExists = fileManager.fileExists(atPath: legacy.path)

        if currentExists {
            if legacyExists {
                migrateLegacyWorkbenchIfNeeded(from: legacy, to: current, fileManager: fileManager)
            }
            return current
        }
        if legacyExists {
            return legacy
        }
        return current
    }

    /// Exposed for tests: true when `workbench.json` exists and is non-empty.
    nonisolated static func hasUsableWorkbench(in directory: URL, fileManager: FileManager = .default) -> Bool {
        let url = directory.appendingPathComponent("workbench.json")
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    /// Copy-only migrate when current lacks usable workbench and legacy has one.
    /// Never deletes or moves legacy data.
    nonisolated static func migrateLegacyWorkbenchIfNeeded(
        from legacy: URL,
        to current: URL,
        fileManager: FileManager = .default
    ) {
        migrateLock.lock()
        defer { migrateLock.unlock() }

        guard !hasUsableWorkbench(in: current, fileManager: fileManager),
              hasUsableWorkbench(in: legacy, fileManager: fileManager) else {
            return
        }

        do {
            try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        } catch {
            return
        }

        for relative in migratableRelativeItems {
            let source = legacy.appendingPathComponent(relative)
            let destination = current.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            copyMissingItem(from: source, to: destination, fileManager: fileManager)
        }
    }

    /// Copy `source` to `destination` when missing; if both are directories, merge
    /// by copying only missing children (never overwrite existing destination files).
    nonisolated static func copyMissingItem(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) {
        var isSourceDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isSourceDir) else { return }

        if !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.copyItem(at: source, to: destination)
            return
        }

        guard isSourceDir.boolValue else { return }

        var isDestDir: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDestDir),
              isDestDir.boolValue else {
            return
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            let destChild = destination.appendingPathComponent(child.lastPathComponent)
            copyMissingItem(from: child, to: destChild, fileManager: fileManager)
        }
    }
}

enum Layout {
    // Media panel
    static var mediaPanelDefault: CGFloat { AppTheme.zoomed(500) }
    static var mediaPanelMin: CGFloat { AppTheme.zoomed(280) + AppTheme.GenerationPanel.minimumWidthAdjustment }

    // Inspector
    static var inspectorDefault: CGFloat { AppTheme.EditorPanel.defaultWidth }
    static var inspectorMin: CGFloat { AppTheme.EditorPanel.minimumWidth }

    // Agent panel
    static var agentPanelMin: CGFloat { AppTheme.zoomed(240) }
    static var agentPanelMax: CGFloat { AppTheme.zoomed(640) }
    static var chatColumnMax: CGFloat { AppTheme.zoomed(640) }

    // Headers & toolbars
    static var panelHeaderHeight: CGFloat { AppTheme.zoomed(28) }
    static var toolbarHeight: CGFloat { AppTheme.zoomed(38) }

    static var panelGap: CGFloat { AppTheme.zoomed(5) }

    // Timeline
    static let timelineMinHeight: CGFloat = 100
    static let timelineDefaultHeightFraction: CGFloat = 0.25
    static let trackHeight: CGFloat = TrackSize.defaultHeight
    static let rulerHeight: CGFloat = 24
    static let trackHeaderWidth: CGFloat = 100
    static let dropZoneHeight: CGFloat = 60
    static let insertThreshold: CGFloat = 10
    static let dragThreshold: CGFloat = 3

    // Preview
    static var previewMinWidth: CGFloat { AppTheme.zoomed(400) }
    static var previewMinHeight: CGFloat { AppTheme.zoomed(320) }
}

enum Defaults {
    static let pixelsPerFrame: Double = 4.0
    static let imageDurationSeconds: Double = 5.0
    static let audioTTSDurationSeconds: Double = 10.0
    static let audioMusicDurationSeconds: Double = 60.0
    static let textDurationSeconds: Double = 3.0
    static let aspectTolerance: Double = 0.02
}

enum Snap {
    static let thresholdPixels: Double = 8.0
    static let stickyMultiplier: Double = 1.5
    static let playheadMultiplier: Double = 1.5
}

enum TrackSize {
    static let defaultHeight: CGFloat = 44
    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 200
    static let resizeHandleZone: CGFloat = 6
}

enum Zoom {
    static let min: Double = 0.05
    static let floor: Double = 0.0001
    static let max: Double = 40.0
    static let toolbarStepFactor: Double = 1.25
    static let scrollSensitivity: Double = 0.04
    static let magnifySensitivity: Double = 1.5 
    static let panSpeed: Double = 5.0
    static let fitAllBuffer: Double = 3.0
}

enum TimelineAutoScroll {
    static let edgeZoneWidth: CGFloat = 56
    static let maxZoneFraction: CGFloat = 0.5
    static let minStep: CGFloat = 4
    static let maxStep: CGFloat = 28
    static let interval: TimeInterval = 1.0 / 60.0
}

enum Trim {
    static let handleWidth: CGFloat = 4.0
    static let clipCornerRadius: CGFloat = AppTheme.Radius.xsSm
}

enum Project {
    static let fileExtension = "voxella"
    static let legacyFileExtension = "palmier"
    static let registryFilename = "project-registry.json"
    static let typeIdentifier = "com.voxella.studio.project"
    static let legacyTypeIdentifier = "io.palmier.project"
    static let defaultProjectName = "Untitled Project"
    static let timelineFilename = "project.json"
    static let manifestFilename = "media.json"
    static let generationLogFilename = "generation-log.json"
    static let thumbnailFilename = "thumbnail.jpg"
    static let mediaDirectoryName = "media"

    static var storageDirectory: URL {
        AppSupportPaths.documents()
    }

    nonisolated static func ensureStorageDirectory() {
        let url = storageDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}
