import Foundation

/// User-facing configuration for a backup run.
public struct BackupConfig: Codable, Sendable, Equatable {
    /// Root folder on the external disk, e.g. `/Volumes/Backup/Downpour`.
    public var destinationRoot: URL

    /// Which sources to include in this run.
    public var sources: Set<BackupSource>

    /// Root of the local iCloud container tree to back up. Defaults to the
    /// whole `~/Library/Mobile Documents` so app containers are included.
    public var driveSourceRoot: URL

    /// Keep at most this many snapshots per source. `nil` keeps all.
    public var snapshotRetention: Int?

    /// When true, the engine verifies copied files by hash after writing.
    public var verifyAfterCopy: Bool

    /// Photos: include video assets (and Live Photo videos).
    public var includePhotoVideos: Bool

    /// Photos: include assets the user has marked as Hidden.
    public var includeHiddenPhotos: Bool

    /// How many files/assets to download & copy concurrently.
    public var maxConcurrency: Int

    public init(
        destinationRoot: URL,
        sources: Set<BackupSource> = [.drive, .photos],
        driveSourceRoot: URL = BackupConfig.defaultDriveSourceRoot,
        snapshotRetention: Int? = 10,
        verifyAfterCopy: Bool = false,
        includePhotoVideos: Bool = true,
        includeHiddenPhotos: Bool = false,
        maxConcurrency: Int = 6
    ) {
        self.destinationRoot = destinationRoot
        self.sources = sources
        self.driveSourceRoot = driveSourceRoot
        self.snapshotRetention = snapshotRetention
        self.verifyAfterCopy = verifyAfterCopy
        self.includePhotoVideos = includePhotoVideos
        self.includeHiddenPhotos = includeHiddenPhotos
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// `~/Library/Mobile Documents` — the iCloud container tree.
    ///
    /// Finder's "iCloud Drive" is a *merged* view of `com~apple~CloudDocs`
    /// (Drive proper) plus every per-app container that lives beside it
    /// (`iCloud~md~obsidian`, `com~apple~Pages`, …). Rooting here lets the Drive
    /// backup reproduce that merged view — see `ICloudDriveBackup.collectItems`.
    public static var defaultDriveSourceRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    /// Destination subfolder for a given source.
    public func destination(for source: BackupSource) -> URL {
        destinationRoot.appendingPathComponent(source.directoryName, isDirectory: true)
    }
}
