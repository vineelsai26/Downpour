import Foundation
import os

/// Lightweight logging wrapper. Logs to the unified logging system and,
/// optionally, appends to a file on disk for the launchd/headless path.
public final class BackupLogger: @unchecked Sendable {
    public static let shared = BackupLogger()

    private let osLog = os.Logger(subsystem: "dev.vstack.downpour", category: "engine")
    private let queue = DispatchQueue(label: "dev.vstack.downpour.log")
    private var fileHandle: FileHandle?

    public init() {}

    /// Begin appending log lines to `url` in addition to the unified log.
    public func attachFile(at url: URL) {
        queue.sync {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
    }

    public func info(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    public func warn(_ message: String) {
        osLog.warning("\(message, privacy: .public)")
        write("WARN", message)
    }

    public func error(_ message: String) {
        osLog.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private func write(_ level: String, _ message: String) {
        queue.async { [weak self] in
            guard let handle = self?.fileHandle else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) [\(level)] \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}
