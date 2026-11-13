// SPDX-License-Identifier: MIT

import Foundation
import PDFKit
import Photos
import PhoneDSHBot
import UIKit
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
        if url.pathExtension.lowercased() == "pdf" {
            let page = max(1, min(request.page ?? 1, 8))
            let rendered = try pdfPageJPEG(url: url, page: page)
            return try BotModelImagePreparer.prepare(
                data: rendered, name: "\(url.deletingPathExtension().lastPathComponent)-p\(page).jpg")
        }
        return try BotModelImagePreparer.prepare(data: data, name: url.lastPathComponent)
    }

    /// Rasterize one PDF page for vision. A scanned document has no reliable
    /// text layer, so a page image is more honest than OCR guesswork; the
    /// caller controls the page and the per-turn image cap still applies.
    private static func pdfPageJPEG(url: URL, page: Int) throws -> Data {
        guard let document = PDFDocument(url: url), page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else {
            throw BotModelImageError.unsupported
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { throw BotModelImageError.unsupported }
        let scale = min(1, CGFloat(BotModelImagePolicy.maxDimension) / longest)
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            pdfPage.draw(with: .mediaBox, to: context.cgContext)
        }
        guard let data = image.jpegData(compressionQuality: 0.82), !data.isEmpty else {
            throw BotModelImageError.unsupported
        }
        return data
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
