import Foundation
import BackupCore

/// Shared persisted settings, read by both the GUI and the headless
/// (launchd) backup path so they always agree on configuration.
enum AppSettings {
    enum Keys {
        static let destination = "destinationPath"
        static let includeDrive = "includeDrive"
        static let includePhotos = "includePhotos"
        static let retention = "retention"
        static let verify = "verify"
        static let includePhotoVideos = "includePhotoVideos"
        static let includeHiddenPhotos = "includeHiddenPhotos"
        static let ejectAfterBackup = "ejectAfterBackup"
        static let notifyOnCompletion = "notifyOnCompletion"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleFrequency = "scheduleFrequency"
        static let scheduleHour = "scheduleHour"
        static let maxConcurrency = "maxConcurrency"
        /// Optional override for the Drive source folder (no UI; power users / testing).
        static let driveSourceOverride = "driveSourceOverride"
    }

    static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    static func int(_ key: String, default def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? def
    }

    static var destinationPath: String {
        UserDefaults.standard.string(forKey: Keys.destination) ?? ""
    }

    /// Build a `BackupConfig` from saved settings, or nil if no destination set.
    static func loadConfig() -> BackupConfig? {
        let d = UserDefaults.standard
        let path = d.string(forKey: Keys.destination) ?? ""
        guard !path.isEmpty else { return nil }

        var sources: Set<BackupSource> = []
        if d.object(forKey: Keys.includeDrive) as? Bool ?? true { sources.insert(.drive) }
        if d.object(forKey: Keys.includePhotos) as? Bool ?? true { sources.insert(.photos) }

        let retention = d.object(forKey: Keys.retention) as? Int ?? 10
        let verify = d.object(forKey: Keys.verify) as? Bool ?? false

        var config = BackupConfig(
            destinationRoot: URL(fileURLWithPath: path, isDirectory: true),
            sources: sources,
            snapshotRetention: retention > 0 ? retention : nil,
            verifyAfterCopy: verify,
            includePhotoVideos: d.object(forKey: Keys.includePhotoVideos) as? Bool ?? true,
            includeHiddenPhotos: d.object(forKey: Keys.includeHiddenPhotos) as? Bool ?? false,
            maxConcurrency: d.object(forKey: Keys.maxConcurrency) as? Int ?? 6
        )
        if let override = d.string(forKey: Keys.driveSourceOverride), !override.isEmpty {
            config.driveSourceRoot = URL(fileURLWithPath: override, isDirectory: true)
        }
        return config
    }
}
