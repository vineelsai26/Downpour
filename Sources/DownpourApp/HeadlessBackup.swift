import Foundation
import AppKit
import BackupCore

/// Runs a backup with no window, using saved settings, then exits. Invoked via
/// `--backup` by the launchd agent. Runs inside the app bundle so it inherits
/// the bundle's Photos (TCC) authorization granted earlier in the GUI.
///
/// Exit codes:  0 success · 1 finished with errors · 75 skipped (no config /
/// destination disk not connected — EX_TEMPFAIL, so launchd retries later).
enum HeadlessBackup {
    static func run() {
        let logURL = logFileURL()
        BackupLogger.shared.attachFile(at: logURL)
        BackupLogger.shared.info("Headless backup starting")

        guard let config = AppSettings.loadConfig() else {
            BackupLogger.shared.warn("No destination configured; skipping.")
            exit(75)
        }

        // If the destination volume isn't mounted, skip quietly so launchd retries.
        let volumeRoot = firstExistingAncestor(of: config.destinationRoot)
        if FilesystemInfo.inspect(volumeRoot) == nil || !destinationReachable(config.destinationRoot) {
            BackupLogger.shared.warn("Destination not reachable (\(config.destinationRoot.path)); is the disk connected? Skipping.")
            notify(title: "Downpour skipped", body: "Backup disk not connected.")
            exit(75)
        }

        let reporter = ClosureReporter { event in
            switch event {
            case .warning(_, let message): BackupLogger.shared.warn(message)
            case .sourceFinished(let s):
                BackupLogger.shared.info("\(s.source.displayName): \(s.filesCopied) copied, \(s.filesReused) reused, \(ByteFormat.string(s.bytesCopied)), \(s.warnings) warnings")
            case .log(let message): BackupLogger.shared.info(message)
            default: break
            }
        }

        let engine = BackupEngine()
        Task.detached(priority: .utility) {
            var code: Int32 = 0
            var summaryText = ""
            do {
                let summary = try await engine.run(config: config, reporter: reporter)
                code = summary.succeeded ? 0 : 1
                summaryText = "\(summary.totalFilesCopied) files · \(ByteFormat.string(summary.totalBytesCopied))"
            } catch {
                code = 1
                summaryText = error.localizedDescription
                BackupLogger.shared.error(error.localizedDescription)
            }
            BackupLogger.shared.info("Headless backup finished (code \(code))")
            notify(
                title: code == 0 ? "Downpour complete" : "Downpour finished with errors",
                body: summaryText
            )
            exit(code)
        }

        // Keep the process alive for PhotoKit callbacks until the task calls exit().
        RunLoop.main.run()
    }

    // MARK: Helpers

    private static func destinationReachable(_ url: URL) -> Bool {
        // Reachable if it exists, or its parent exists and is writable (we can create it).
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return fm.isWritableFile(atPath: url.path) }
        let parent = url.deletingLastPathComponent()
        return fm.fileExists(atPath: parent.path) && fm.isWritableFile(atPath: parent.path)
    }

    private static func firstExistingAncestor(of url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }

    private static func logFileURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Downpour", isDirectory: true)
        return base.appendingPathComponent("backup.log")
    }

    /// Post a user notification via osascript (works from a headless bundle
    /// without UNUserNotificationCenter setup).
    private static func notify(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "'")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "'")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }
}
