import Foundation

public enum BackupError: LocalizedError {
    case destinationUnavailable(URL)
    case destinationNotWritable(URL)
    case sourceMissing(BackupSource, URL)
    case photosAuthorizationDenied
    case downloadTimedOut(URL)
    case insufficientSpace(needed: Int64, available: Int64)
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let url):
            return "Backup destination is not available: \(url.path). Is the external disk connected?"
        case .destinationNotWritable(let url):
            return "Backup destination is not writable: \(url.path)."
        case .sourceMissing(let source, let url):
            return "\(source.displayName) source not found at \(url.path)."
        case .photosAuthorizationDenied:
            return "Photos access was denied. Grant access in System Settings ▸ Privacy & Security ▸ Photos."
        case .downloadTimedOut(let url):
            return "Timed out downloading from iCloud: \(url.path)."
        case .insufficientSpace(let needed, let available):
            return "Not enough free space. Needs ~\(ByteFormat.string(needed)), only \(ByteFormat.string(available)) available."
        case .cancelled:
            return "Backup was cancelled."
        case .underlying(let message):
            return message
        }
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
