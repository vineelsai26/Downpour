import Foundation
import Photos

/// Low-level PhotoKit access: authorization, original-resource export (with
/// iCloud download), and deterministic on-disk path layout.
public final class PhotoKitExporter: @unchecked Sendable {
    public init() {}

    // MARK: Authorization

    public func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        // `requestAuthorization` hard-crashes the process if the running bundle
        // lacks NSPhotoLibraryUsageDescription (e.g. the bare CLI). Only prompt
        // when the usage string is present.
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            return .denied
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: Fetch

    /// Assets sorted oldest-first, filtered by the given options.
    public func fetchAllAssets(includeVideos: Bool = true, includeHidden: Bool = false) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = includeHidden

        var mediaTypes: [PHAssetMediaType] = [.image]
        if includeVideos { mediaTypes.append(.video) }
        mediaTypes.append(.audio)

        var assets: [PHAsset] = []
        for media in mediaTypes {
            let result = PHAsset.fetchAssets(with: media, options: options)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
        }
        return assets
    }

    public func resources(for asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset)
    }

    // MARK: Export

    /// Write a resource's bytes to `fileURL`, pulling from iCloud if needed.
    public func export(_ resource: PHAssetResource, to fileURL: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Path layout

    /// Deterministic, stable, collision-resistant path for an asset's resource:
    ///   YYYY/MM/<stableID>_<filename>
    /// Stable across runs so unchanged resources can be hardlink-reused.
    public func relativePath(for asset: PHAsset, resource: PHAssetResource) -> String {
        let date = asset.creationDate ?? asset.modificationDate ?? Date(timeIntervalSince1970: 0)
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", comps.year ?? 0)
        let month = String(format: "%02d", comps.month ?? 0)

        let id = stableID(for: asset)
        var name = sanitize(resource.originalFilename)
        switch resource.type {
        case .fullSizePhoto, .fullSizeVideo:
            name = "edited_\(name)"            // user-edited render
        case .adjustmentData:
            name = "adjustments_\(name)"        // edit recipe (small)
        default:
            break
        }
        return "\(year)/\(month)/\(id)_\(name)"
    }

    /// First component of the asset's localIdentifier (a stable UUID), sanitized
    /// to filename-safe characters.
    private func stableID(for asset: PHAsset) -> String {
        let raw = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? asset.localIdentifier
        let cleaned = raw.replacingOccurrences(of: "-", with: "")
        let safe = cleaned.filter { $0.isLetter || $0.isNumber }
        return String(safe.prefix(16))
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}
