import Darwin
import Foundation

/// Process-wide exclusive destination lock. It prevents GUI and launchd runs
/// from concurrently mutating the same snapshots, manifests, and `latest` link.
final class BackupRunLock {
    private let descriptor: Int32

    init(destinationRoot: URL) throws {
        let url = destinationRoot.appendingPathComponent(".downpour.lock")
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BackupError.destinationUnavailable(destinationRoot) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BackupError.backupAlreadyRunning(destinationRoot)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
