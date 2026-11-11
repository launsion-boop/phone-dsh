// SPDX-License-Identifier: MIT
// `Documents/chat-status.log` writer. W1-E moves the per-line open/write/close
// off the main actor and rotates the file by size instead of letting it grow
// forever. All file work happens on one private serial queue; callers only hand
// over an already-formatted line.

import Foundation
import Darwin

public final class ChatStatusLogWriter: @unchecked Sendable {
    public static let shared = ChatStatusLogWriter()

    public let url: URL
    public let maximumBytes: Int
    private let queue = DispatchQueue(label: "phone-dsh.chat-status-log",
                                      qos: .utility)

    public init(url: URL? = nil, maximumBytes: Int = 1 << 20) {
        self.url = url ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-status.log")
        self.maximumBytes = max(64 * 1024, maximumBytes)
    }

    /// Fire-and-forget append. The caller formats the line; the writer prefixes
    /// the timestamp so ordering matches the previous implementation.
    public func append(_ text: String) {
        queue.async { [url, maximumBytes] in
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp) \(text)\n".data(using: .utf8) else { return }
            let path = url.path
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            let end = lseek(fd, 0, SEEK_END)
            if end >= off_t(maximumBytes) {
                close(fd)
                Self.rotate(url: url)
                let fresh = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
                guard fresh >= 0 else { return }
                Self.writeAll(fresh, data)
                close(fresh)
                return
            }
            Self.writeAll(fd, data)
            close(fd)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset),
                                         buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += count
            }
        }
    }

    /// One previous generation (`chat-status.log.1`); the rotation itself is
    /// allowed to lose the older generation because this log is diagnostic.
    private static func rotate(url: URL) {
        let manager = FileManager.default
        let previous = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
    }
}
