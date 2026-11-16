// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Debug-only replay of a captured production event journal. It appends the
/// real durable events through the same `BotEventLog` the Bot uses, so the
/// normal projections build the rows; it does not mock permissions, feedback
/// or observation, and it never writes a feedback/derivation event itself.
enum BotA05EventImporter {
    private struct Line: Decodable { let event: BotEvent }

    static func importIfRequested(store: SQLiteDomainStore) async {
        let env = ProcessInfo.processInfo.environment
        let defaultPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("a05/bot-events.jsonl").path
        let path = (env["PDSH_A05_IMPORT_EVENTS"].flatMap { $0.isEmpty ? nil : $0 }) ?? defaultPath
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            NSLog("A05 import: no readable fixture at %@", path)
            return
        }
        NSLog("A05 import: reading %@ (%d bytes)", path, data.count)
        var existing = Set<String>()
        if let current = try? await store.events(after: 0, limit: 100_000) {
            existing = Set(current.map(\.eventId))
        }
        let decoder = JSONDecoder()
        var decoded = 0
        var appended = 0
        for (index, raw) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard !raw.isEmpty else { continue }
            let line: Line
            do { line = try decoder.decode(Line.self, from: Data(raw)) }
            catch {
                NSLog("A05 import: decode failed line %d: %@", index + 1, String(describing: error))
                continue
            }
            decoded += 1
            guard !existing.contains(line.event.eventId) else { continue }
            do {
                _ = try await store.append(line.event)
                existing.insert(line.event.eventId)
                appended += 1
            } catch {
                NSLog("A05 import: append failed line %d type=%@: %@",
                      index + 1, line.event.type, String(describing: error))
            }
        }
        NSLog("A05 import: decoded=%d appended=%d", decoded, appended)
    }
}
