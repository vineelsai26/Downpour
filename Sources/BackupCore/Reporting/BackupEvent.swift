import Foundation

/// A progress/log event emitted during a backup run.
public enum BackupEvent: Sendable {
    /// A source began a named phase (e.g. "Scanning", "Downloading", "Copying").
    case phaseChanged(source: BackupSource, phase: String)
    /// Incremental progress within the current source.
    case progress(source: BackupSource, completed: Int, total: Int, bytes: Int64, currentItem: String?)
    /// A single item was backed up (new or changed).
    case itemBackedUp(source: BackupSource, name: String, bytes: Int64, reused: Bool)
    /// Non-fatal problem; the run continues.
    case warning(source: BackupSource?, message: String)
    /// Free-form log line.
    case log(String)
    /// A source finished with a summary.
    case sourceFinished(SourceSummary)
    /// The whole run finished.
    case runFinished(RunSummary)
}

public struct SourceSummary: Sendable, Codable {
    public var source: BackupSource
    public var filesConsidered: Int
    public var filesCopied: Int
    public var filesReused: Int
    public var bytesCopied: Int64
    public var warnings: Int
    public var snapshotPath: String?

    public init(
        source: BackupSource,
        filesConsidered: Int = 0,
        filesCopied: Int = 0,
        filesReused: Int = 0,
        bytesCopied: Int64 = 0,
        warnings: Int = 0,
        snapshotPath: String? = nil
    ) {
        self.source = source
        self.filesConsidered = filesConsidered
        self.filesCopied = filesCopied
        self.filesReused = filesReused
        self.bytesCopied = bytesCopied
        self.warnings = warnings
        self.snapshotPath = snapshotPath
    }
}

public struct RunSummary: Sendable, Codable {
    public var startedAt: Date
    public var finishedAt: Date
    public var sources: [SourceSummary]
    public var succeeded: Bool
    public var errorMessage: String?

    public init(
        startedAt: Date,
        finishedAt: Date,
        sources: [SourceSummary],
        succeeded: Bool,
        errorMessage: String? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sources = sources
        self.succeeded = succeeded
        self.errorMessage = errorMessage
    }

    public var totalBytesCopied: Int64 { sources.reduce(0) { $0 + $1.bytesCopied } }
    public var totalFilesCopied: Int { sources.reduce(0) { $0 + $1.filesCopied } }
}

/// Receives events from the engine. Implementations must be safe to call from
/// any task/thread.
public protocol BackupReporter: Sendable {
    func report(_ event: BackupEvent)
}

/// A reporter backed by a closure.
public struct ClosureReporter: BackupReporter {
    private let handler: @Sendable (BackupEvent) -> Void
    public init(_ handler: @escaping @Sendable (BackupEvent) -> Void) {
        self.handler = handler
    }
    public func report(_ event: BackupEvent) { handler(event) }
}

/// A reporter that discards all events.
public struct NullReporter: BackupReporter {
    public init() {}
    public func report(_ event: BackupEvent) {}
}
