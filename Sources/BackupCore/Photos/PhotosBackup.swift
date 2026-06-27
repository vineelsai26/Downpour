import Foundation
import Photos

/// Backs up the iCloud Photos library by exporting each asset's original
/// resources (photos, videos, Live Photo pairs, edited renders) via PhotoKit,
/// downloading from iCloud as needed, into an incremental snapshot. Assets are
/// exported concurrently (bounded by `config.maxConcurrency`).
public struct PhotosBackup: SourceBackup {
    public let source: BackupSource = .photos
    private let exporter = PhotoKitExporter()

    public init() {}

    private struct ResourceResult: Sendable {
        let rel: String
        var entry: ManifestEntry?
        var copied: Bool = false
        var reused: Bool = false
        var bytes: Int64 = 0
        var warning: String?
    }

    private struct AssetResult: Sendable {
        let name: String?
        var resources: [ResourceResult]
    }

    public func run(_ context: BackupRunContext) async throws -> SourceSummary {
        let reporter = context.reporter
        reporter.report(.phaseChanged(source: .photos, phase: "Requesting Photos access"))

        let status = await exporter.requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw BackupError.photosAuthorizationDenied
        }
        if status == .limited {
            reporter.report(.warning(source: .photos, message: "Photos access is limited — only selected photos will be backed up. Grant full access in System Settings ▸ Privacy & Security ▸ Photos."))
        }

        let fm = FileManager.default
        let destRoot = context.config.destination(for: .photos)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let previousManifest = Manifest.load(for: .photos, in: context.config.destinationRoot)
        var newManifest = Manifest(source: .photos)

        let store = SnapshotStore(sourceRoot: destRoot, supportsHardlinks: context.filesystem.supportsHardlinks)
        let session = try store.beginSession(timestamp: context.timestamp)

        reporter.report(.phaseChanged(source: .photos, phase: "Scanning Photos library"))
        let assets = exporter.fetchAllAssets(
            includeVideos: context.config.includePhotoVideos,
            includeHidden: context.config.includeHiddenPhotos
        )

        var summary = SourceSummary(source: .photos)
        summary.snapshotPath = session.targetDir.path
        reporter.report(.phaseChanged(source: .photos, phase: "Backing up \(assets.count) photos & videos"))

        let tempDir = fm.temporaryDirectory.appendingPathComponent("downpour-photos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let previous = previousManifest.entries          // read-only, shared across tasks
        let verify = context.config.verifyAfterCopy
        let snapshotName = session.snapshotName
        var completed = 0

        await processConcurrently(
            assets,
            maxConcurrency: context.config.maxConcurrency,
            process: { _, asset in
                await processAsset(asset, previous: previous, session: session,
                                   tempDir: tempDir, verify: verify, snapshotName: snapshotName)
            },
            record: { assetResult in
                completed += 1
                for r in assetResult.resources {
                    summary.filesConsidered += 1
                    if let warning = r.warning {
                        summary.warnings += 1
                        reporter.report(.warning(source: .photos, message: warning))
                    } else if let entry = r.entry {
                        newManifest.entries[r.rel] = entry
                        if r.copied {
                            summary.filesCopied += 1
                            summary.bytesCopied += r.bytes
                        } else {
                            summary.filesReused += 1
                        }
                        reporter.report(.itemBackedUp(source: .photos, name: r.rel, bytes: r.bytes, reused: r.reused))
                    }
                }
                reporter.report(.progress(
                    source: .photos, completed: completed, total: assets.count,
                    bytes: summary.bytesCopied, currentItem: assetResult.name
                ))
            }
        )

        if Task.isCancelled { throw BackupError.cancelled }

        try store.finalize(session: session, retention: context.config.snapshotRetention)
        try newManifest.save(to: context.config.destinationRoot)

        reporter.report(.sourceFinished(summary))
        return summary
    }

    private func processAsset(
        _ asset: PHAsset, previous: [String: ManifestEntry],
        session: SnapshotSession, tempDir: URL, verify: Bool, snapshotName: String
    ) async -> AssetResult {
        let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
        var results: [ResourceResult] = []

        for resource in exporter.resources(for: asset) {
            if Task.isCancelled { break }
            let rel = exporter.relativePath(for: asset, resource: resource)
            do {
                // Reuse unchanged resources without re-downloading from iCloud.
                if let prev = previous[rel],
                   abs(prev.modified - modified) < 1.0,
                   let reused = session.reuseFromPrevious(relativePath: rel) {
                    results.append(ResourceResult(
                        rel: rel,
                        entry: ManifestEntry(relativePath: rel, size: reused.bytes, modified: modified, sha256: prev.sha256, snapshotName: snapshotName),
                        copied: false, reused: true, bytes: reused.bytes
                    ))
                    continue
                }

                let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.removeItem(at: tempURL)
                try await exporter.export(resource, to: tempURL)
                let result = try session.placeProducedFile(relativePath: rel, tempURL: tempURL, verify: verify)
                results.append(ResourceResult(
                    rel: rel,
                    entry: ManifestEntry(relativePath: rel, size: result.bytes, modified: modified, sha256: result.sha256, snapshotName: snapshotName),
                    copied: true, reused: false, bytes: result.bytes
                ))
            } catch {
                results.append(ResourceResult(rel: rel, entry: nil, warning: "\(rel): \(error.localizedDescription)"))
            }
        }
        return AssetResult(name: asset.originalFilename, resources: results)
    }
}

private extension PHAsset {
    /// Best-effort display name for progress.
    var originalFilename: String? {
        PHAssetResource.assetResources(for: self).first?.originalFilename
    }
}
