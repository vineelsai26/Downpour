import Foundation
import BackupCore

// downpour --dest <path> [--drive] [--photos] [--retention N] [--verify] [--dry-run]
//
// Headless entry point used for testing the engine and by the launchd agent.

struct CLIOptions {
    var destination: URL?
    var driveSource: URL?
    var sources: Set<BackupSource> = []
    var retention: Int? = 10
    var verify = false
    var showHelp = false
}

func parseArgs(_ args: [String]) -> CLIOptions {
    var opts = CLIOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--dest", "-d":
            i += 1
            if i < args.count { opts.destination = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath) }
        case "--drive-source":
            i += 1
            if i < args.count { opts.driveSource = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath) }
        case "--drive":
            opts.sources.insert(.drive)
        case "--photos":
            opts.sources.insert(.photos)
        case "--retention":
            i += 1
            if i < args.count { opts.retention = Int(args[i]) }
        case "--verify":
            opts.verify = true
        case "--help", "-h":
            opts.showHelp = true
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
        }
        i += 1
    }
    if opts.sources.isEmpty { opts.sources = [.drive, .photos] }
    return opts
}

let usage = """
downpour — back up iCloud Drive & Photos to an external disk

USAGE:
  downpour --dest <path> [options]

OPTIONS:
  -d, --dest <path>   Destination root on the external disk (required)
      --drive         Back up iCloud Drive (default: both)
      --photos        Back up iCloud Photos (default: both)
      --drive-source <path>  Override the Drive source folder (default: iCloud Drive)
      --retention N   Keep at most N snapshots (default: 10)
      --verify        Verify each copied file by hash
  -h, --help          Show this help
"""

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

if opts.showHelp {
    print(usage)
    exit(0)
}

guard let destination = opts.destination else {
    FileHandle.standardError.write(Data("error: --dest is required\n\n\(usage)\n".utf8))
    exit(2)
}

var config = BackupConfig(
    destinationRoot: destination,
    sources: opts.sources,
    snapshotRetention: opts.retention,
    verifyAfterCopy: opts.verify
)
if let driveSource = opts.driveSource {
    config.driveSourceRoot = driveSource
}

let reporter = ClosureReporter { event in
    switch event {
    case .phaseChanged(let source, let phase):
        print("[\(source.displayName)] \(phase)")
    case .progress(let source, let completed, let total, let bytes, let item):
        let pct = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
        let name = item.map { ($0 as NSString).lastPathComponent } ?? ""
        FileHandle.standardError.write(Data("\r[\(source.displayName)] \(completed)/\(total) (\(pct)%) \(ByteFormat.string(bytes)) — \(name)\u{001B}[K".utf8))
    case .warning(_, let message):
        FileHandle.standardError.write(Data("\n  ⚠️  \(message)\n".utf8))
    case .log(let message):
        print(message)
    case .sourceFinished(let s):
        print("\n[\(s.source.displayName)] done — \(s.filesCopied) copied, \(s.filesReused) reused, \(ByteFormat.string(s.bytesCopied)), \(s.warnings) warnings")
    case .runFinished(let summary):
        let dur = summary.finishedAt.timeIntervalSince(summary.startedAt)
        print(String(format: "\nRun %@ in %.1fs — %d files, %@ copied",
                     summary.succeeded ? "succeeded" : "finished with errors",
                     dur, summary.totalFilesCopied, ByteFormat.string(summary.totalBytesCopied)))
        if let err = summary.errorMessage { print("Errors:\n\(err)") }
    case .itemBackedUp:
        break
    }
}

let engine = BackupEngine()
do {
    let summary = try await engine.run(config: config, reporter: reporter)
    exit(summary.succeeded ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("\nfatal: \(error.localizedDescription)\n".utf8))
    exit(1)
}
