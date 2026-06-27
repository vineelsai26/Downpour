import Foundation

/// A category of data that can be backed up.
public enum BackupSource: String, Codable, CaseIterable, Sendable {
    case drive
    case photos

    public var displayName: String {
        switch self {
        case .drive: return "iCloud Drive"
        case .photos: return "iCloud Photos"
        }
    }

    /// Subdirectory under the destination root where this source's data lives.
    public var directoryName: String {
        switch self {
        case .drive: return "Drive"
        case .photos: return "Photos"
        }
    }
}
