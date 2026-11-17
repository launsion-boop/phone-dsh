// SPDX-License-Identifier: MIT
// DEBUG-only recovery helper: with the launch argument `-pdsh-quarantine-engine 1` it MOVES the DSH engine
// state directory (Documents/chat-host) aside to `chat-host.quarantine-<utc>` and exits, so the next normal
// launch starts the engine from a clean state. It never deletes anything: moving the directory back restores
// the previous state. Needed when the engine host refuses to start with WAL_CORRUPT.
//
// Compiled only under #if DEBUG; never ships.
#if DEBUG
import Foundation

enum DebugEngineQuarantine {
    static let argument = "-pdsh-quarantine-engine"

    /// Call first thing in `App.init()`, before the engine host exists.
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: argument), args.indices.contains(i + 1), args[i + 1] == "1" else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let src = docs.appendingPathComponent("chat-host", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dst = docs.appendingPathComponent("chat-host.quarantine-\(stamp)", isDirectory: true)
        var note = "{\"moved\": false}"
        if fm.fileExists(atPath: src.path) {
            do {
                try fm.moveItem(at: src, to: dst)
                note = "{\"moved\": true, \"to\": \"\(dst.lastPathComponent)\"}"
            } catch {
                note = "{\"moved\": false, \"error\": \"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}"
            }
        }
        try? note.write(to: docs.appendingPathComponent("quarantine-engine.json"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
#endif
