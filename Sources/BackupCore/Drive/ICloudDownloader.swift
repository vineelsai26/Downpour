import Foundation

/// Forces iCloud Drive items that are not materialized locally ("Optimize Mac
/// Storage" placeholders) to download so their bytes can be copied.
public final class ICloudDownloader: @unchecked Sendable {
    private var fm: FileManager { .default }
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(timeout: TimeInterval = 600, pollInterval: TimeInterval = 0.25) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// Given any enumerated URL, return the *real* item URL. iCloud represents
    /// not-yet-downloaded files either as a dataless file at the real path, or
    /// as a hidden `.<name>.icloud` placeholder. This collapses the latter to
    /// the real path.
    public func realItemURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return url }
        let inner = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(inner)
    }

    public func isPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud")
    }

    /// Whether the item at `url` still needs downloading.
    ///
    /// We key off whether the file is actually **dataless** (no local bytes),
    /// not off `ubiquitousItemDownloadingStatus`: that status is unreliable and
    /// can report `.notDownloaded` for files whose bytes are fully present, which
    /// made the poll loop wait forever. The `SF_DATALESS` flag is authoritative.
    private func needsDownload(_ url: URL) -> Bool {
        if !fm.fileExists(atPath: url.path) { return true }
        return isDataless(url)
    }

    /// True if the file has the dataless flag set (a placeholder with no local
    /// bytes that must be fetched from iCloud before it can be read).
    private func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        let SF_DATALESS: UInt32 = 0x4000_0000
        return (info.st_flags & SF_DATALESS) != 0
    }

    /// Ensure the item at `realURL` is fully downloaded. Throws on timeout.
    /// Returns once the bytes are present locally.
    public func ensureDownloaded(_ realURL: URL) async throws {
        if !needsDownload(realURL) { return }

        try? fm.startDownloadingUbiquitousItem(at: realURL)
        // `brctl download` reliably materializes (and often blocks until done),
        // so trigger it up front. Run it off the cooperative thread pool so many
        // concurrent downloads don't starve Swift's executor threads.
        await brctlDownloadAsync(realURL)

        let start = Date()
        while needsDownload(realURL) {
            if Task.isCancelled { throw BackupError.cancelled }
            if Date().timeIntervalSince(start) > timeout {
                throw BackupError.downloadTimedOut(realURL)
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Run the synchronous `brctl download` on a background GCD thread so the
    /// awaiting task suspends instead of blocking a cooperative executor thread.
    private func brctlDownloadAsync(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                self.brctlDownload(url)
                continuation.resume()
            }
        }
    }

    /// Best-effort `brctl download` fallback.
    private func brctlDownload(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = ["download", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
