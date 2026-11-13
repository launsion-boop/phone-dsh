// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

/// One prepared image that can travel in a DSH `session/prompt` content array
/// or an MCP tool result. Bytes are always an encoded raster image, never a
/// filesystem path.
public struct BotModelImage: Sendable, Equatable {
    public let mediaType: String
    public let data: Data
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(mediaType: String = "image/jpeg", data: Data, name: String,
                pixelWidth: Int, pixelHeight: Int) {
        self.mediaType = mediaType
        self.data = data
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum BotModelImageError: Error, Equatable, Sendable {
    case empty
    case unsupported
    case tooLarge
}

/// One request to hand an existing workspace file or an Office artifact to
/// the model. `path` and `fileID` are mutually exclusive; the App resolver owns
/// both lookups so the package never sees a host filesystem path.
public struct BotModelAttachmentRequest: Sendable, Equatable {
    public let path: String?
    public let fileID: String?
    /// Photos-library local identifier returned by `photos.recent/search`.
    public let photoID: String?
    public let purpose: String

    public init(path: String? = nil, fileID: String? = nil,
                photoID: String? = nil, purpose: String) {
        self.path = path
        self.fileID = fileID
        self.photoID = photoID
        self.purpose = purpose
    }
}

/// The same economic bounds the design uses for a vision turn. Keep these in
/// one place: the runtime, the tests and the approval copy must agree.
public enum BotModelImagePolicy {
    public static let maxImagesPerTurn = 2
    public static let maxDimension = 1_568
    public static let maxEncodedBytes = 1_048_576
}

/// Decode, orient, downscale and re-encode one image for a model request.
///
/// ImageIO is used instead of UIImage so the preparation is testable on macOS
/// and never depends on a main-actor UIKit context. The longest edge is capped
/// at `maxDimension`; JPEG quality steps down until the encoded bytes fit
/// `maxEncodedBytes` or the quality floor is reached.
public enum BotModelImagePreparer {
    public static func prepare(data: Data, name: String) throws -> BotModelImage {
        guard !data.isEmpty else { throw BotModelImageError.empty }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw BotModelImageError.unsupported
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: BotModelImagePolicy.maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw BotModelImageError.unsupported }

        var encoded: Data?
        var quality = 0.82
        while quality >= 0.24 {
            guard let candidate = encodeJPEG(image, quality: quality) else {
                throw BotModelImageError.unsupported
            }
            encoded = candidate
            if candidate.count <= BotModelImagePolicy.maxEncodedBytes { break }
            quality -= 0.18
        }
        guard let encoded, encoded.count <= BotModelImagePolicy.maxEncodedBytes else {
            throw BotModelImageError.tooLarge
        }
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return BotModelImage(
            data: encoded,
            name: safeName.isEmpty ? "image.jpg" : String(safeName.prefix(120)),
            pixelWidth: image.width,
            pixelHeight: image.height)
    }

    /// The DSH `session/prompt` spelling: `PromptContentPart.image` declares
    /// `mediaType`, not `mimeType`. Extra MCP-only fields are deliberately
    /// absent so the strict prompt schema never sees them.
    public static func jsonValue(_ image: BotModelImage) -> BotJSONValue {
        .object([
            "type": .string("image"),
            "mediaType": .string(image.mediaType),
            "data": .string(image.data.base64EncodedString()),
            "name": .string(image.name),
        ])
    }

    /// The MCP `CallToolResult.content` spelling. The DSH MCP client admits a
    /// declared image block, verifies the canonical base64 and checks the
    /// selected model route before turning it into an `ImageBlock`.
    public static func mcpJSONValue(_ image: BotModelImage) -> BotJSONValue {
        .object([
            "type": .string("image"),
            "mimeType": .string(image.mediaType),
            "data": .string(image.data.base64EncodedString()),
            "name": .string(image.name),
        ])
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
