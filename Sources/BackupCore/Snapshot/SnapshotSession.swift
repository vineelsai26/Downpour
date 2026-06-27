import Foundation

/// A single in-progress snapshot. Files may be placed into it concurrently;
/// shared mutable state is lock-protected. `SnapshotStore.finalize` is called
/// when done.
public final class SnapshotSession: @unchecked Sendable {
    unowned let store: SnapshotStore
    public let targetDir: URL
    public let previousDir: URL?
    public let snapshotName: String

    /// Relative paths placed during this run (used for mirror deletion pruning).
    /// Mutated from concurrent tasks, so guarded by a lock.
    private var _placedRelPaths: Set<String> = []
    private let lock = NSLock()

    private func markPlaced(_ relativePath: String) {
        lock.lock(); _placedRelPaths.insert(relativePath); lock.unlock()
    }

    /// Thread-safe snapshot of placed paths (read after the run, in finalize).
    var placedRelPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }; return _placedRelPaths
    }

    private let fm = FileManager.default

    init(store: SnapshotStore, targetDir: URL, previousDir: URL?, snapshotName: String) {
        self.store = store
        self.targetDir = targetDir
        self.previousDir = previousDir
        self.snapshotName = snapshotName
    }

    /// Place a file that lives on disk at `sourceURL` into the snapshot at
    /// `relativePath`, reusing the previous snapshot's copy when unchanged.
    public func placeFile(
        relativePath: String,
        sourceURL: URL,
        size: Int64,
        modified: TimeInterval,
        previousEntry: ManifestEntry?,
        verify: Bool
    ) throws -> PlaceResult {
        let dest = targetDir.appendingPathComponent(relativePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        markPlaced(relativePath)

        let unchanged = previousEntry?.matchesQuickSignature(size: size, modified: modified) ?? false

        switch store.strategy {
        case .hardlink:
            if unchanged, let prevDir = previousDir {
                let prevFile = prevDir.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: prevFile.path) {
                    try? fm.removeItem(at: dest)
                    do {
                        try fm.linkItem(at: prevFile, to: dest)
                        return PlaceResult(copied: false, bytes: size, sha256: previousEntry?.sha256)
                    } catch {
                        // Fall through to a fresh copy on link failure.
                    }
                }
            }
            return try copyFresh(from: sourceURL, to: dest, size: size, verify: verify)

        case .mirror:
            if unchanged, fm.fileExists(atPath: dest.path) {
                return PlaceResult(copied: false, bytes: size, sha256: previousEntry?.sha256)
            }
            return try copyFresh(from: sourceURL, to: dest, size: size, verify: verify)
        }
    }

    /// Reuse the previous snapshot's copy of `relativePath` without needing the
    /// source bytes, when an upstream signature says it's unchanged. Returns a
    /// `PlaceResult` on success, or nil if there's nothing to reuse (caller must
    /// then produce the bytes fresh). Used by the Photos path, where fetching a
    /// resource means downloading it from iCloud.
    public func reuseFromPrevious(relativePath: String) -> PlaceResult? {
        switch store.strategy {
        case .hardlink:
            guard let prevDir = previousDir else { return nil }
            let prevFile = prevDir.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: prevFile.path) else { return nil }
            let dest = targetDir.appendingPathComponent(relativePath)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.linkItem(at: prevFile, to: dest)
            } catch {
                return nil
            }
            markPlaced(relativePath)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return PlaceResult(copied: false, bytes: size, sha256: nil)

        case .mirror:
            let dest = targetDir.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: dest.path) else { return nil }
            markPlaced(relativePath)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return PlaceResult(copied: false, bytes: size, sha256: nil)
        }
    }

    /// Place a file we just produced in a temp location (e.g. a PhotoKit export)
    /// by moving it into the snapshot. Always counts as a copy.
    public func placeProducedFile(relativePath: String, tempURL: URL, verify: Bool) throws -> PlaceResult {
        let dest = targetDir.appendingPathComponent(relativePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        markPlaced(relativePath)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tempURL, to: dest)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let hash = verify ? FileHash.sha256(of: dest) : nil
        return PlaceResult(copied: true, bytes: size, sha256: hash)
    }

    private func copyFresh(from sourceURL: URL, to dest: URL, size: Int64, verify: Bool) throws -> PlaceResult {
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: sourceURL, to: dest)
        var hash: String? = nil
        if verify {
            hash = FileHash.sha256(of: dest)
            if let srcHash = FileHash.sha256(of: sourceURL), srcHash != hash {
                throw BackupError.underlying("Verification failed for \(dest.lastPathComponent)")
            }
        }
        return PlaceResult(copied: true, bytes: size, sha256: hash)
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        if full.hasPrefix(base) { return String(full.dropFirst(base.count)) }
        return url.lastPathComponent
    }
}
