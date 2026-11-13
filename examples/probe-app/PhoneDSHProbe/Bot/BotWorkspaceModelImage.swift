// SPDX-License-Identifier: MIT

import Foundation
import Photos
import PhoneDSHBot
#if canImport(ProbeKit)
import ProbeKit
#endif

/// App-side bridge from a workspace attachment to model-ready image bytes.
///
/// `BotDSHRemoteRuntime` owns the prompt shape and the cap; this type only
/// resolves the VFS path through the same materialized-workspace resolver the
/// document preview uses. A missing materialized file, a non-image attachment
/// or a decode failure returns nil so the send keeps its text/path block
/// instead of failing the whole turn.
enum BotWorkspaceModelImage {
    static func prepare(_ attachment: BotAttachment) async -> BotModelImage? {
        guard BotDSHRemoteRuntime.isImageAttachment(attachment),
              let url = PreviewPathResolver.fileURL(for: attachment.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return try? BotModelImagePreparer.prepare(data: data, name: attachment.name)
    }

    /// `attach_to_model` resolver. A user attachment is a workspace path; a
    /// camera/photo tool result is an `OfficeArtifactStore` fileId. Both end in
    /// the same encoder, so the model receives one image shape either way.
    static func image(for request: BotModelAttachmentRequest) async throws -> BotModelImage {
        if let photoID = request.photoID, !photoID.isEmpty {
            let data = try await photoData(for: photoID)
            return try BotModelImagePreparer.prepare(
                data: data, name: "photo-\(photoID.prefix(8)).jpg")
        }
        let url: URL
        #if canImport(ProbeKit)
        if let fileID = request.fileID, !fileID.isEmpty {
            url = try await OfficeArtifactStore.shared.fileURL(for: fileID)
        } else if let path = request.path,
                  let resolved = PreviewPathResolver.fileURL(for: path) {
            url = resolved
        } else {
            throw BotModelImageError.unsupported
        }
        #else
        if let path = request.path,
           let resolved = PreviewPathResolver.fileURL(for: path) {
            url = resolved
        } else {
            throw BotModelImageError.unsupported
        }
        #endif
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BotModelImageError.unsupported
        }
        return try BotModelImagePreparer.prepare(data: data, name: url.lastPathComponent)
    }

    /// Export at most one Photos asset without iCloud network access. A
    /// metadata-only `photos.recent/search` item is useless to the model; the
    /// localIdentifier is the one stable handle the tool result carries.
    private static func photoData(for id: String) async throws -> Data {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { throw BotModelImageError.unsupported }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: BotModelImageError.unsupported)
                }
            }
        }
    }
}
