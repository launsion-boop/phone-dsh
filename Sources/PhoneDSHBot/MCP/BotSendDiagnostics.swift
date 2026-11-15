// SPDX-License-Identifier: MIT
//
// TEMPORARY send-path diagnostics. Writes one bounded append-only line per
// stage to Documents/bot-send.log so a device run can name the exact await a
// send is stuck on. Not part of the protocol; remove once the hang is closed.

import Foundation

enum BotSendDiagnostics {
    private static let lock = NSLock()

    static func log(_ message: String) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bot-send.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
