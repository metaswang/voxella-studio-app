import Darwin
import Foundation
import os

/// Categorized logger + crash handler.
///
/// Uncaught exceptions and fatal signals are written to
/// `~/Library/Logs/VoxStudio/crash.log` with a backtrace.
/// Notice/warning/error logs are also appended to
/// `~/Library/Logs/VoxStudio/app.log` so a signed `.app` launch still
/// has a copy-pasteable diagnostic file.
enum Log {
    static let subsystem  = "com.voxella.studio"
    static let app        = CategoryLog("app")
    static let editor     = CategoryLog("editor")
    static let export     = CategoryLog("export")
    static let preview    = CategoryLog("preview")
    static let mcp        = CategoryLog("mcp")
    static let agent      = CategoryLog("agent")
    static let account    = CategoryLog("account")
    static let generation = CategoryLog("generation")
    static let project    = CategoryLog("project")
    static let transcription = CategoryLog("transcription")
    static let recording = CategoryLog("recording")
    static let llm        = CategoryLog("llm")
    static let search     = CategoryLog("search")
    static let knowledge  = CategoryLog("knowledge")

    static let crashLogURL = AppSupportPaths.logs().appendingPathComponent("crash.log")
    static let appLogURL = AppSupportPaths.logs().appendingPathComponent("app.log")

    /// Full NSError chain
    static func detail(_ error: Error) -> String {
        let ns = error as NSError
        var message = ns.localizedDescription
        if let reason = ns.localizedFailureReason, !message.contains(reason) {
            message += " — \(reason)"
        }
        var codes: [String] = []
        var current: NSError? = ns
        while let e = current {
            codes.append("\(e.domain) \(e.code)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(message) (\(codes.joined(separator: " → ")))"
    }

    /// Call once at launch, before `NSApplication.run()`.
    static func bootstrap() {
        CrashHandler.install()
        FileLog.prepare()
        app.notice("launch pid=\(ProcessInfo.processInfo.processIdentifier) log=\(appLogURL.path)")
    }
}

struct CategoryLog {
    let logger: Logger
    let category: String

    init(_ category: String) {
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        self.category = category
    }

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let value = message()
        persist("DEBUG", value)
        logger.debug("\(value, privacy: .public)")
        #endif
    }
    func info(_ m: String) { logger.info("\(m, privacy: .public)") }
    func notice(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        persist("NOTICE", m)
        logger.notice("\(m, privacy: .public)")
        if let telemetry {
            Telemetry.breadcrumb(telemetry, category: category, data: data)
        }
    }
    func warning(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        persist("WARN", m)
        logger.warning("\(m, privacy: .public)")
        Telemetry.logWarning(telemetry ?? m, category: category, data: data)
    }
    func error(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        persist("ERROR", m)
        logger.error("\(m, privacy: .public)")
        Telemetry.logError(telemetry ?? m, category: category, data: data)
    }
    func fault(_ m: String, telemetry: String? = nil, data: Telemetry.Payload? = nil) {
        persist("FAULT", m)
        logger.fault("\(m, privacy: .public)")
        Telemetry.logFault(telemetry ?? m, category: category, data: data)
    }

    private func persist(_ level: String, _ msg: String) {
        let line = "[\(category)] \(level): \(msg)"
        #if DEBUG
        FileHandle.standardError.write(Data("\(line)\n".utf8))
        #endif
        FileLog.append(line)
    }
}

/// Durable copy of notice/warning/error logs for machines launched as `.app`.
private enum FileLog {
    private static let lock = NSLock()
    private static let maxBytes: UInt64 = 2_000_000

    static func prepare() {
        let directory = Log.appLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = Log.appLogURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        } else if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  size.uint64Value > maxBytes {
            let backup = url.deletingLastPathComponent().appendingPathComponent("app.log.1")
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: url, to: backup)
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

// MARK: - Crash handler

private enum CrashHandler {
    /// File descriptor for `crash.log`, opened once at install. `-1` if unavailable.
    nonisolated(unsafe) static var fd: Int32 = -1

    static func install() {
        let url = Log.crashLogURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
    }
}

private let uncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exc in
    let stack = exc.callStackSymbols.joined(separator: "\n")
    let message = """
    === \(Date()) UNCAUGHT \(exc.name.rawValue) ===
    reason: \(exc.reason ?? "(none)")
    \(stack)

    """
    if CrashHandler.fd >= 0, let data = message.data(using: .utf8) {
        data.withUnsafeBytes { _ = write(CrashHandler.fd, $0.baseAddress, $0.count) }
    }
    Logger(subsystem: Log.subsystem, category: "crash")
        .fault("\(message, privacy: .public)")
}

/// Async-signal-safe: uses only `write`, `backtrace*`, `fsync`, `raise`.
private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    let target = CrashHandler.fd >= 0 ? CrashHandler.fd : STDERR_FILENO
    let header = "\n*** FATAL SIGNAL ***\n"
    header.withCString { _ = write(target, $0, strlen($0)) }
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
        let count = backtrace(frames.baseAddress, 64)
        backtrace_symbols_fd(frames.baseAddress, count, target)
    }
    fsync(target)
    signal(sig, SIG_DFL)
    raise(sig)
}
