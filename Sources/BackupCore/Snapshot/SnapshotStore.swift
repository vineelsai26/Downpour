import Foundation

/// Result of placing a single file into a snapshot session.
public struct PlaceResult: Sendable {
    public var copied: Bool      // true = bytes were written; false = hardlinked/unchanged
    public var bytes: Int64
    public var sha256: String?
}

/// Manages the on-disk snapshot layout for one source:
///
///   <sourceRoot>/snapshots/<timestamp>/...     (hardlink strategy)
///   <sourceRoot>/latest -> snapshots/<timestamp>
///   <sourceRoot>/current/...                    (mirror strategy, e.g. exFAT)
///
/// On APFS/HFS+ each run creates a new timestamped snapshot where unchanged
/// files are hardlinked from the previous snapshot (cheap history). On
/// filesystems without hardlink support it maintains a single mirror.
public final class SnapshotStore {
    public enum Strategy: Sendable { case hardlink, mirror }

    public let sourceRoot: URL
    public let strategy: Strategy
    private let fm = FileManager.default

    public init(sourceRoot: URL, supportsHardlinks: Bool) {
        self.sourceRoot = sourceRoot
        self.strategy = supportsHardlinks ? .hardlink : .mirror
    }

    private var snapshotsDir: URL { sourceRoot.appendingPathComponent("snapshots", isDirectory: true) }
    private var latestLink: URL { sourceRoot.appendingPathComponent("latest", isDirectory: false) }
    private var currentDir: URL { sourceRoot.appendingPathComponent("current", isDirectory: true) }

    /// Resolve the directory holding the most recent snapshot's files, if any.
    private func previousDirectory() -> URL? {
        switch strategy {
        case .mirror:
            return fm.fileExists(atPath: currentDir.path) ? currentDir : nil
        case .hardlink:
            if let dest = try? fm.destinationOfSymbolicLink(atPath: latestLink.path) {
                let resolved = snapshotsDir.appendingPathComponent((dest as NSString).lastPathComponent)
                if fm.fileExists(atPath: resolved.path) { return resolved }
            }
            // Fallback: newest timestamp directory.
            let dirs = (try? fm.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []
            if let newest = dirs.sorted().last {
                return snapshotsDir.appendingPathComponent(newest)
            }
            return nil
        }
    }

    public func beginSession(timestamp: Date) throws -> SnapshotSession {
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let previous = previousDirectory()
        let target: URL
        let name: String
        switch strategy {
        case .mirror:
            target = currentDir
            name = "current"
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        case .hardlink:
            // Ensure a unique directory even when runs land in the same second,
            // so the new snapshot never collides with the one we're linking from.
            let base = Self.timestampFormatter.string(from: timestamp)
            var candidate = base
            var suffix = 2
            while fm.fileExists(atPath: snapshotsDir.appendingPathComponent(candidate).path) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            name = candidate
            target = snapshotsDir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return SnapshotSession(store: self, targetDir: target, previousDir: previous, snapshotName: name)
    }

    /// Update `latest` symlink (hardlink strategy) and prune old snapshots.
    public func finalize(session: SnapshotSession, retention: Int?) throws {
        switch strategy {
        case .mirror:
            try pruneDeleted(in: session)
        case .hardlink:
            // Point `latest` at the new snapshot.
            try? fm.removeItem(at: latestLink)
            try fm.createSymbolicLink(
                atPath: latestLink.path,
                withDestinationPath: "snapshots/\(session.snapshotName)"
            )
            if let keep = retention { try prune(keeping: keep) }
        }
    }

    /// Discard a failed or cancelled hardlink session. Mirror sessions mutate
    /// their existing current directory and therefore cannot be safely removed.
    public func discard(session: SnapshotSession) {
        guard strategy == .hardlink else { return }
        let target = session.targetDir.standardizedFileURL
        let root = snapshotsDir.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(root) else { return }
        try? fm.removeItem(at: target)
    }

    /// Mirror mode: delete files in `current/` no longer present in the source.
    private func pruneDeleted(in session: SnapshotSession) throws {
        guard let enumerator = fm.enumerator(at: session.targetDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        var toRemove: [URL] = []
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let rel = SnapshotSession.relativePath(of: url, under: session.targetDir)
            if !session.placedRelPaths.contains(rel) {
                toRemove.append(url)
            }
        }
        for url in toRemove { try? fm.removeItem(at: url) }
    }

    private func prune(keeping count: Int) throws {
        guard count > 0 else { return }
        let dirs = ((try? fm.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []).sorted()
        guard dirs.count > count else { return }
        for name in dirs.prefix(dirs.count - count) {
            try? fm.removeItem(at: snapshotsDir.appendingPathComponent(name))
        }
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
