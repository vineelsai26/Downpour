import Foundation

/// One tracked item in a source's manifest.
public struct ManifestEntry: Codable, Sendable, Equatable {
    /// Path relative to the source's snapshot directory.
    public var relativePath: String
    public var size: Int64
    /// File modification time, seconds since 1970.
    public var modified: TimeInterval
    /// Optional content hash (computed when verifying or for content-addressed dedup).
    public var sha256: String?
    /// Name of the snapshot directory whose copy these bytes currently live in.
    public var snapshotName: String

    public init(
        relativePath: String,
        size: Int64,
        modified: TimeInterval,
        sha256: String? = nil,
        snapshotName: String
    ) {
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.sha256 = sha256
        self.snapshotName = snapshotName
    }

    /// Cheap change check: same size and (near-)identical mtime.
    public func matchesQuickSignature(size: Int64, modified: TimeInterval) -> Bool {
        return self.size == size && abs(self.modified - modified) < 1.0
    }
}

/// Persisted incremental state for one backup source.
public struct Manifest: Codable, Sendable {
    public var version: Int
    public var source: BackupSource
    public var updatedAt: Date
    /// Keyed by a stable item key (relative path for Drive, asset/resource key for Photos).
    public var entries: [String: ManifestEntry]

    public init(source: BackupSource) {
        self.version = 1
        self.source = source
        self.updatedAt = Date(timeIntervalSince1970: 0)
        self.entries = [:]
    }

    private static func url(for source: BackupSource, in destinationRoot: URL) -> URL {
        destinationRoot
            .appendingPathComponent(source.directoryName, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    public static func load(for source: BackupSource, in destinationRoot: URL) -> Manifest {
        let url = Self.url(for: source, in: destinationRoot)
        guard
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder.backup.decode(Manifest.self, from: data)
        else {
            return Manifest(source: source)
        }
        return manifest
    }

    public func save(to destinationRoot: URL) throws {
        var copy = self
        copy.updatedAt = Date()
        let url = Self.url(for: source, in: destinationRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.backup.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var backup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var backup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
