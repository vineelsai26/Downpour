import Foundation

/// Orchestrates a full backup run across the configured sources.
public final class BackupEngine: @unchecked Sendable {
    public init() {}

    /// Run the backup. Per-source failures are recorded but do not abort the
    /// remaining sources; setup failures (bad destination) throw.
    public func run(config: BackupConfig, reporter: BackupReporter) async throws -> RunSummary {
        let fm = FileManager.default
        let startedAt = Date()

        // Validate / prepare destination.
        do {
            try fm.createDirectory(at: config.destinationRoot, withIntermediateDirectories: true)
        } catch {
            throw BackupError.destinationUnavailable(config.destinationRoot)
        }
        guard isWritable(config.destinationRoot) else {
            throw BackupError.destinationNotWritable(config.destinationRoot)
        }
        guard let filesystem = FilesystemInfo.inspect(config.destinationRoot) else {
            throw BackupError.destinationUnavailable(config.destinationRoot)
        }
        let runLock = try BackupRunLock(destinationRoot: config.destinationRoot)
        defer { _ = runLock }

        if !filesystem.supportsHardlinks {
            reporter.report(.warning(
                source: nil,
                message: "Destination filesystem is \(filesystem.typeName.uppercased()), which can't hardlink. Falling back to a single mirror (no snapshot history). Format the disk as APFS for versioned snapshots."
            ))
        }
        reporter.report(.log("Destination \(config.destinationRoot.path) — \(filesystem.typeName), \(ByteFormat.string(filesystem.freeBytes)) free"))

        let context = BackupRunContext(
            config: config,
            filesystem: filesystem,
            timestamp: startedAt,
            reporter: reporter
        )

        var summaries: [SourceSummary] = []
        var errors: [String] = []

        for source in BackupSource.allCases where config.sources.contains(source) {
            if Task.isCancelled {
                errors.append(BackupError.cancelled.localizedDescription)
                break
            }
            let impl = backup(for: source)
            do {
                let summary = try await impl.run(context)
                summaries.append(summary)
            } catch {
                errors.append("\(source.displayName): \(error.localizedDescription)")
                reporter.report(.warning(source: source, message: error.localizedDescription))
            }
        }

        let summary = RunSummary(
            startedAt: startedAt,
            finishedAt: Date(),
            sources: summaries,
            succeeded: errors.isEmpty,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
        persist(summary, to: config.destinationRoot)
        reporter.report(.runFinished(summary))
        return summary
    }

    private func backup(for source: BackupSource) -> SourceBackup {
        switch source {
        case .drive: return ICloudDriveBackup()
        case .photos: return PhotosBackup()
        }
    }

    private func isWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".write-probe-\(ProcessInfo.processInfo.globallyUniqueString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("ok".utf8)) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    private func persist(_ summary: RunSummary, to destinationRoot: URL) {
        let runsDir = destinationRoot.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let stamp = SnapshotStore.timestampFormatter.string(from: summary.startedAt)
        if let data = try? JSONEncoder.backup.encode(summary) {
            try? data.write(to: runsDir.appendingPathComponent("\(stamp).json"), options: .atomic)
            try? data.write(to: destinationRoot.appendingPathComponent("last-run.json"), options: .atomic)
        }
    }

    /// Load the most recent run summary, if any.
    public static func lastRun(in destinationRoot: URL) -> RunSummary? {
        let url = destinationRoot.appendingPathComponent("last-run.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.backup.decode(RunSummary.self, from: data)
    }
}
