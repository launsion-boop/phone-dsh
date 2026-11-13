// SPDX-License-Identifier: MIT
// `Documents/chat-status.log` writer. W1-E moves the per-line open/write/close
// off the main actor and rotates the file by size instead of letting it grow
// forever. All file work happens on one private serial queue; callers only hand
// over an already-formatted line.
//
// Two line formats are preserved from the pre-W1 implementation: `append` keeps
// `<ISO8601> <text>` (the historical status line) and `appendRaw` keeps
// `<line>` unchanged for diagnostics that format themselves.

import Foundation
import Darwin

public final class ChatStatusLogWriter: @unchecked Sendable {
    /// The same file the App has always written (`Documents/chat-status.log`).
    public static let defaultURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-status.log")
    }()

    /// MetricKit payloads live in a directory next to that file.
    public static let defaultDiagnosticsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
    }()

    /// One writer for the production file: the queue is serial, so hang-monitor
    /// lines, status lines and diagnostics cannot interleave bytes.
    public static let shared = ChatStatusLogWriter()

    public let url: URL
    public let maximumBytes: Int
    private let queue = DispatchQueue(label: "phone-dsh.chat-status-log",
                                      qos: .utility)
    /// Touched only from `queue`, so one instance keeps one cached formatter.
    private let formatter = ISO8601DateFormatter()

    public init(url: URL? = nil, maximumBytes: Int = 1 << 20) {
        self.url = url ?? ChatStatusLogWriter.defaultURL
        self.maximumBytes = max(64 * 1024, maximumBytes)
    }

    /// Fire-and-forget timestamped append. The caller captures the time (the
    /// meaning of the old line); the queue formats it and writes it.
    public func append(_ text: String) {
        let date = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let stamp = self.formatter.string(from: date)
            self.write("\(stamp) \(text)\n")
        }
    }

    /// Fire-and-forget raw append: exactly `<line>\n`, no timestamp.
    public func appendRaw(_ line: String) {
        queue.async { [weak self] in
            self?.write("\(line)\n")
        }
    }

    /// Blocks until every line queued before this call has been written.
    /// Tests use it; production never waits on the log.
    public func waitForIdle() {
        queue.sync {}
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
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
