// SPDX-License-Identifier: MIT
// Off-main status/diagnostic log.
//
// `chat-status.log` used to be opened, seeked, written and closed on the main
// actor for every status line, and every timestamp built a fresh
// `ISO8601DateFormatter`. One serial queue now owns a long-lived FileHandle
// and one formatter: callers only capture the line (and a Date for the
// timestamped flavour) and return. The file and every line format are
// unchanged.

import Foundation

public final class StatusLogWriter {
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

    /// One writer for the production file. The queue is serial, so hang
    /// monitor lines, status lines and diagnostics cannot interleave bytes.
    public static let shared = StatusLogWriter()

    private let queue = DispatchQueue(label: "dev.phone-dsh.status-log", qos: .utility)
    private let url: URL
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    public init(url: URL = StatusLogWriter.defaultURL) {
        self.url = url
    }

    /// The historical timestamped status line: `<ISO8601> <text>\n`.
    public func append(_ text: String) {
        // Capture the time at the call site (the meaning of the old line), but
        // format it on the writer queue so the main actor only reads a Date.
        let date = Date()
        queue.async { [weak self] in
            self?.write(text, at: date)
        }
    }

    /// The historical raw diagnostic line: exactly `<line>\n`, no timestamp.
    public func appendRaw(_ line: String) {
        queue.async { [weak self] in
            self?.write(line, at: nil)
        }
    }

    /// Blocks until every line queued before this call has been written.
    /// Tests use it; production never waits on the log.
    public func waitForIdle() {
        queue.sync {}
    }

    private func write(_ text: String, at date: Date?) {
        let line = date.map { "\(formatter.string(from: $0)) \(text)\n" } ?? "\(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { open() }
        guard let writer = handle else { return }
        do {
            try writer.seekToEnd()
            try writer.write(contentsOf: data)
        } catch {
            // One retry after a stale / closed handle. A status line must never
            // take the app down or block the caller.
            try? writer.close()
            self.handle = nil
            open()
            if let retry = self.handle {
                try? retry.seekToEnd()
                try? retry.write(contentsOf: data)
            }
        }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
    }
}
