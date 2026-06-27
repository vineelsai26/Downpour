import Foundation

/// How often automatic backups run.
enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case every6Hours
    case every12Hours
    case daily

    var id: String { rawValue }

    var label: String {
        switch self {
        case .every6Hours: return "Every 6 hours"
        case .every12Hours: return "Every 12 hours"
        case .daily: return "Daily"
        }
    }
}

/// Installs/removes the launchd agent that runs the app's headless `--backup`
/// mode on a schedule. Self-contained (writes the plist + calls launchctl), so
/// the shipping app doesn't need the shell scripts.
enum ScheduleManager {
    static let label = "dev.vstack.downpour"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Downpour", isDirectory: true)
    }

    static func install(frequency: ScheduleFrequency, hour: Int) throws {
        let binary = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let logDir = logDirectory
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "--backup"],
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": logDir.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("launchd.err.log").path,
        ]

        switch frequency {
        case .every6Hours:
            dict["StartInterval"] = 6 * 3600
        case .every12Hours:
            dict["StartInterval"] = 12 * 3600
        case .daily:
            dict["StartCalendarInterval"] = ["Hour": hour, "Minute": 0]
        }

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        reload()
    }

    static func uninstall() {
        run(["/bin/launchctl", "unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Trigger a run immediately (for "Run scheduled backup now" / testing).
    static func runNow() {
        run(["/bin/launchctl", "start", label])
    }

    private static func reload() {
        run(["/bin/launchctl", "unload", plistURL.path])
        run(["/bin/launchctl", "load", plistURL.path])
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
