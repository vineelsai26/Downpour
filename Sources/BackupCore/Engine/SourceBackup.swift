import Foundation

/// Context passed to each source backup for a single run.
public struct BackupRunContext: Sendable {
    public let config: BackupConfig
    public let filesystem: FilesystemInfo
    public let timestamp: Date
    public let reporter: BackupReporter

    public init(config: BackupConfig, filesystem: FilesystemInfo, timestamp: Date, reporter: BackupReporter) {
        self.config = config
        self.filesystem = filesystem
        self.timestamp = timestamp
        self.reporter = reporter
    }
}

/// A backup implementation for one source (Drive, Photos, ...).
public protocol SourceBackup: Sendable {
    var source: BackupSource { get }
    func run(_ context: BackupRunContext) async throws -> SourceSummary
}
