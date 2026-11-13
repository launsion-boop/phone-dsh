// SPDX-License-Identifier: MIT

import Foundation

/// One bounded text read behind a document card.
public struct BotDocumentText: Equatable, Sendable {
    /// The UTF-8 prefix that was read, without a leading BOM.
    public let text: String
    /// True when the file is longer than the read limit (or grew past it).
    public let truncated: Bool
    /// Size reported by the file system when known; otherwise the bytes read.
    public let byteCount: Int
    /// The limit this read used, in bytes.
    public let limit: Int
}

/// Why a document card could not render its file.
public enum BotDocumentFileReadError: Error, Equatable, Sendable {
    /// The path does not exist (or its metadata cannot be read).
    case notFound
    /// The path exists but is a directory, device or other non-regular file.
    case notRegularFile
    /// The bytes are not valid UTF-8, so rendering them as markdown would lie.
    case notUTF8
    /// Opening or reading failed; carries the system description.
    case unreadable(String)

    public var localizedDescription: String {
        switch self {
        case .notFound: return "文件不存在或无法读取"
        case .notRegularFile: return "不是普通文件"
        case .notUTF8: return "不是 UTF-8 文本"
        case .unreadable(let detail): return detail
        }
    }
}

/// Reads a document card's file without trusting it to be small or textual.
///
/// The card path is resolved by the App (VFS `/dsh/workspace/...` → the
/// materialized host directory); this type only owns the bounded read. The
/// 256 KiB default matches the P19 envelope limit, so a card preview never
/// displays more than the Worker could have returned in one tool result.
public enum BotDocumentFileReader {
    /// Default preview cap. The document card shows a truncation notice above
    /// this and offers the full native preview.
    public static let defaultLimit = 256 * 1024

    /// Read at most `limit` bytes of UTF-8 text from `url`.
    ///
    /// A truncated read never ends in the middle of a multi-byte scalar: the
    /// trailing bytes are dropped until the prefix decodes as UTF-8. A file
    /// that is invalid UTF-8 within the limit fails with `.notUTF8` instead of
    /// showing replacement characters.
    public static func readText(at url: URL,
                                limit: Int = defaultLimit) throws -> BotDocumentText {
        let limit = max(1, limit)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values else { throw BotDocumentFileReadError.notFound }
        guard values.isRegularFile == true else { throw BotDocumentFileReadError.notRegularFile }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BotDocumentFileReadError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw BotDocumentFileReadError.unreadable(error.localizedDescription)
        }

        let fileSize = values.fileSize
        let truncated = data.count > limit || (fileSize ?? 0) > limit
        var bytes = Array(data.prefix(limit))
        if truncated {
            // Never split a UTF-8 scalar at the truncation boundary.
            while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
        }
        guard var text = String(bytes: bytes, encoding: .utf8) else {
            throw BotDocumentFileReadError.notUTF8
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return BotDocumentText(text: text, truncated: truncated,
                               byteCount: fileSize ?? data.count, limit: limit)
    }
}
