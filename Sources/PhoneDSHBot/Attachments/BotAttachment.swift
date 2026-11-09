// SPDX-License-Identifier: MIT

import Foundation

/// One file the user attached to a `chat` action. The field names and the
/// string values in `kind` follow dsh-bot `src/main/attachments.cjs`; the
/// phoneDSH prompt block is assembled from the same shape.
public struct BotAttachment: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var size: Int64
    public var mimeType: String
    public var kind: String

    public init(name: String, path: String, size: Int64, mimeType: String, kind: String) {
        self.name = name
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.kind = kind
    }
}

public enum BotAttachmentPolicy {
    /// dsh-bot `MAX_ATTACHMENTS`.
    public static let maxCount = 10
    /// dsh-bot `MAX_ATTACHMENT_BYTES` (25 MiB).
    public static let maxBytes: Int64 = 25 * 1024 * 1024

    /// Mirrors dsh-bot `kindFor(name, mimeType)` exactly, including the
    /// case-sensitive MIME prefix check and the extension fallback.
    public static func kind(name: String, mimeType: String) -> String {
        let mime = mimeType
        let lower = name.lowercased()
        func hasExtension(_ extensions: [String]) -> Bool {
            extensions.contains { lower.hasSuffix("." + $0) }
        }
        if mime.hasPrefix("image/") || hasExtension(["png", "jpg", "jpeg", "gif", "webp", "heic"]) {
            return "image"
        }
        if mime.hasPrefix("audio/") || hasExtension(["mp3", "wav", "m4a", "aac", "ogg"]) {
            return "audio"
        }
        if mime.hasPrefix("video/") || hasExtension(["mp4", "mov", "webm", "mkv"]) {
            return "video"
        }
        if mime == "application/pdf" || hasExtension(["pdf"]) {
            return "pdf"
        }
        if hasExtension(["md", "markdown"]) {
            return "markdown"
        }
        if hasExtension(["csv", "xls", "xlsx", "numbers"]) {
            return "table"
        }
        if hasExtension(["json", "jsonl", "yml", "yaml"]) {
            return "json"
        }
        if hasExtension(["doc", "docx", "pages", "rtf"]) {
            return "document"
        }
        if hasExtension(["zip", "tar", "gz", "tgz", "rar", "7z"]) {
            return "archive"
        }
        return "file"
    }

    /// Mirrors dsh-bot `safeName`: take the basename, replace every character
    /// outside `[\w.\- ()一-鿿]` with `_`, remove leading dots, cap at 120
    /// characters and fall back to `file`.
    public static func safeName(_ name: String) -> String {
        let raw = name.isEmpty ? "file" : name
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? "file"
        var scalars = String.UnicodeScalarView()
        for unit in base.utf16 {
            let allowed = unit == 0x2E || unit == 0x2D || unit == 0x5F || unit == 0x20
                || unit == 0x28 || unit == 0x29
                || (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit)
                || (0x61...0x7A).contains(unit) || (0x4E00...0x9FFF).contains(unit)
            if allowed, let scalar = Unicode.Scalar(UInt32(unit)) {
                scalars.append(scalar)
            } else {
                scalars.append(Unicode.Scalar(UInt32(0x5F))!)
            }
        }
        var cleaned = String(scalars)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        return cleaned.isEmpty ? "file" : cleaned
    }
}
