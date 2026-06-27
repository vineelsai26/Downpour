import Foundation

/// Information about the filesystem backing a destination path, used to decide
/// whether hardlink-based incremental snapshots are possible.
public struct FilesystemInfo: Sendable {
    public var volumeURL: URL
    public var typeName: String        // e.g. "apfs", "hfs", "exfat", "msdos"
    public var supportsHardlinks: Bool
    public var isCaseSensitive: Bool
    public var freeBytes: Int64
    public var totalBytes: Int64

    /// Filesystems that support multiple hardlinks to a file. exFAT/FAT do not.
    static let hardlinkCapableTypes: Set<String> = ["apfs", "hfs", "hfsx", "ufs"]

    public static func inspect(_ url: URL) -> FilesystemInfo? {
        let fm = FileManager.default
        // Resolve to an existing ancestor so we can stat a real path.
        var probe = url
        while !fm.fileExists(atPath: probe.path) && probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }

        let keys: Set<URLResourceKey> = [
            .volumeURLKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeSupportsCaseSensitiveNamesKey,
        ]
        let values = try? probe.resourceValues(forKeys: keys)
        let volumeURL = values?.volume ?? probe

        // statfs gives the concrete filesystem type name.
        var stat = statfs()
        let typeName: String
        if statfs(probe.path, &stat) == 0 {
            typeName = withUnsafePointer(to: &stat.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }.lowercased()
        } else {
            typeName = "unknown"
        }

        let free: Int64
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            free = Int64(important)
        } else {
            free = Int64(values?.volumeAvailableCapacity ?? 0)
        }

        return FilesystemInfo(
            volumeURL: volumeURL,
            typeName: typeName,
            supportsHardlinks: hardlinkCapableTypes.contains(typeName),
            isCaseSensitive: values?.volumeSupportsCaseSensitiveNames ?? false,
            freeBytes: free,
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0)
        )
    }
}
