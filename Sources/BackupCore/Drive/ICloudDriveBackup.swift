import Foundation

/// Backs up the local iCloud container tree (`~/Library/Mobile Documents`),
/// reproducing Finder's merged "iCloud Drive" view (Drive proper plus each
/// visible app's documents — see `collectItems`), forcing placeholder
/// downloads and
/// writing into an incremental snapshot. Files are downloaded & copied
/// concurrently (bounded by `config.maxConcurrency`).
public struct ICloudDriveBackup: SourceBackup {
    public let source: BackupSource = .drive
    private let downloader = ICloudDownloader()

    /// Names skipped entirely. `.DS_Store`/`.localized` are system cruft;
    /// `.Trash` is iCloud's recycle bin (deleted items, not the live tree).
    private let skipNames: Set<String> = [".DS_Store", ".localized", ".Trash"]

    /// iCloud Drive "proper". Its contents are flattened to the snapshot root,
    /// because Finder shows them at the top of iCloud Drive, not nested.
    private let cloudDocsContainer = "com~apple~CloudDocs"

    /// Display names for app containers whose Finder label differs from the
    /// last segment of their container id. Everything else falls back to that
    /// last `~`-segment (capitalized), which already matches Finder for
    /// Pages / Keynote / Numbers / Preview / TextEdit / Automator / iMovie …
    private static let containerDisplayNames: [String: String] = [
        "iCloud~md~obsidian": "Obsidian",
        "iCloud~is~workflow~my~workflows": "Shortcuts",
        "F3LWYJ7GM7~com~apple~mobilegarageband": "GarageBand for iOS",
    ]

    public init() {}

    /// One file to back up: its path relative to the Drive root, and the real
    /// on-disk URL to read bytes from.
    private struct DriveItem: Sendable {
        let rel: String
        let url: URL
    }

    private struct DriveResult: Sendable {
        let rel: String
        var entry: ManifestEntry?
        var copied: Bool = false
        var reused: Bool = false
        var bytes: Int64 = 0
        var warning: String?
    }

    // MARK: Scan

    /// Builds the file list so the snapshot mirrors Finder's "iCloud Drive".
    /// On disk the root holds one folder per iCloud *container*; Finder merges
    /// them into a single view:
    ///   • `com~apple~CloudDocs` is Drive proper — its contents sit at the top.
    ///   • every visible app stores user files under `<container>/Documents`,
    ///     shown under the app's display name.
    /// So we flatten CloudDocs to the root and map each app container's
    /// `Documents` subfolder to its friendly name. Containers without a
    /// `Documents` folder (app-internal state like Mail/Messages) are skipped,
    /// exactly as Finder hides them.
    ///
    /// Each subtree `walk` **follows directory symlinks** (Desktop & Documents)
    /// with cycle protection and resolves `.icloud` placeholders.
    private func collectItems(under sourceRoot: URL) -> [DriveItem] {
        let fm = FileManager.default
        var items: [DriveItem] = []
        var visitedDirs = Set<String>()
        var seenFiles = Set<String>()
        visitedDirs.insert(sourceRoot.resolvingSymlinksInPath().standardizedFileURL.path)

        guard let containers = try? fm.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return items }

        for container in containers {
            if Task.isCancelled { return items }
            let name = container.lastPathComponent
            if skipNames.contains(name) { continue }
            guard (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            if name == cloudDocsContainer {
                walk(dir: container, prefix: "",
                     items: &items, visitedDirs: &visitedDirs, seenFiles: &seenFiles)
            } else {
                let docs = container.appendingPathComponent("Documents", isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: docs.path, isDirectory: &isDir), isDir.boolValue else { continue }
                walk(dir: docs, prefix: displayName(forContainer: name),
                     items: &items, visitedDirs: &visitedDirs, seenFiles: &seenFiles)
            }
        }
        return items
    }

    /// Finder display name for an app container id (last `~`-segment,
    /// capitalized, unless a known override applies).
    private func displayName(forContainer id: String) -> String {
        if let known = Self.containerDisplayNames[id] { return known }
        let last = id.split(separator: "~").last.map(String.init) ?? id
        guard let first = last.first, first.isLowercase else { return last }
        return first.uppercased() + last.dropFirst()
    }

    private func walk(
        dir: URL, prefix: String,
        items: inout [DriveItem], visitedDirs: inout Set<String>, seenFiles: inout Set<String>
    ) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .nameKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }

        for entry in entries {
            if Task.isCancelled { return }
            let name = entry.lastPathComponent
            if skipNames.contains(name) { continue }

            let vals = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if vals?.isSymbolicLink == true {
                let resolved = entry.resolvingSymlinksInPath()
                let resolvedIsDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if resolvedIsDir {
                    let key = resolved.standardizedFileURL.path
                    if visitedDirs.insert(key).inserted {
                        walk(dir: resolved, prefix: childPrefix(prefix, name),
                             items: &items, visitedDirs: &visitedDirs, seenFiles: &seenFiles)
                    }
                } else if fm.fileExists(atPath: resolved.path) {
                    addFile(realURL: resolved, name: name, prefix: prefix, items: &items, seenFiles: &seenFiles)
                }
            } else if vals?.isDirectory == true {
                walk(dir: entry, prefix: childPrefix(prefix, name),
                     items: &items, visitedDirs: &visitedDirs, seenFiles: &seenFiles)
            } else {
                let realURL = downloader.realItemURL(for: entry)
                addFile(realURL: realURL, name: realURL.lastPathComponent, prefix: prefix, items: &items, seenFiles: &seenFiles)
            }
        }
    }

    private func childPrefix(_ prefix: String, _ name: String) -> String {
        prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    private func addFile(realURL: URL, name: String, prefix: String, items: inout [DriveItem], seenFiles: inout Set<String>) {
        if skipNames.contains(name) { return }
        let key = realURL.standardizedFileURL.path
        guard seenFiles.insert(key).inserted else { return }
        items.append(DriveItem(rel: childPrefix(prefix, name), url: realURL))
    }

    // MARK: Run

    public func run(_ context: BackupRunContext) async throws -> SourceSummary {
        let fm = FileManager.default
        let sourceRoot = context.config.driveSourceRoot
        guard fm.fileExists(atPath: sourceRoot.path) else {
            throw BackupError.sourceMissing(.drive, sourceRoot)
        }

        let reporter = context.reporter
        let destRoot = context.config.destination(for: .drive)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let previousManifest = Manifest.load(for: .drive, in: context.config.destinationRoot)
        var newManifest = Manifest(source: .drive)

        let store = SnapshotStore(sourceRoot: destRoot, supportsHardlinks: context.filesystem.supportsHardlinks)
        let session = try store.beginSession(timestamp: context.timestamp)

        reporter.report(.phaseChanged(source: .drive, phase: "Scanning iCloud Drive"))
        let items = collectItems(under: sourceRoot)

        var summary = SourceSummary(source: .drive)
        summary.filesConsidered = items.count
        summary.snapshotPath = session.targetDir.path
        reporter.report(.phaseChanged(source: .drive, phase: "Backing up \(items.count) files"))

        let previous = previousManifest.entries           // read-only, shared across tasks
        let verify = context.config.verifyAfterCopy
        let snapshotName = session.snapshotName
        var completed = 0

        await processConcurrently(
            items,
            maxConcurrency: context.config.maxConcurrency,
            process: { _, item in
                await processItem(item, previous: previous, session: session, verify: verify, snapshotName: snapshotName)
            },
            record: { result in
                completed += 1
                if let warning = result.warning {
                    summary.warnings += 1
                    reporter.report(.warning(source: .drive, message: warning))
                } else if let entry = result.entry {
                    newManifest.entries[result.rel] = entry
                    if result.copied {
                        summary.filesCopied += 1
                        summary.bytesCopied += result.bytes
                    } else {
                        summary.filesReused += 1
                    }
                    reporter.report(.itemBackedUp(source: .drive, name: result.rel, bytes: result.bytes, reused: result.reused))
                }
                reporter.report(.progress(
                    source: .drive, completed: completed, total: items.count,
                    bytes: summary.bytesCopied, currentItem: result.rel
                ))
            }
        )

        if Task.isCancelled { throw BackupError.cancelled }

        try store.finalize(session: session, retention: context.config.snapshotRetention)
        try newManifest.save(to: context.config.destinationRoot)

        reporter.report(.sourceFinished(summary))
        return summary
    }

    private func processItem(
        _ item: DriveItem, previous: [String: ManifestEntry],
        session: SnapshotSession, verify: Bool, snapshotName: String
    ) async -> DriveResult {
        do {
            try await downloader.ensureDownloaded(item.url)
            let values = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                return DriveResult(rel: item.rel, entry: nil)  // skip non-files (e.g. symlinks)
            }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0

            let result = try session.placeFile(
                relativePath: item.rel, sourceURL: item.url,
                size: size, modified: modified,
                previousEntry: previous[item.rel], verify: verify
            )
            return DriveResult(
                rel: item.rel,
                entry: ManifestEntry(relativePath: item.rel, size: size, modified: modified, sha256: result.sha256, snapshotName: snapshotName),
                copied: result.copied,
                reused: !result.copied,
                bytes: result.bytes
            )
        } catch {
            return DriveResult(rel: item.rel, entry: nil, warning: "\(item.rel): \(error.localizedDescription)")
        }
    }
}
