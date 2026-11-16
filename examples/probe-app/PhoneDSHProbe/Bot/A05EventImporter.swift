// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Debug-only replay of a captured production event journal. It appends the
/// real durable events through the same `BotEventLog` the Bot uses, so the
/// normal projections build the rows; it does not mock permissions, feedback
/// or observation, and it never writes a feedback/derivation event itself.
enum BotA05EventImporter {
    private struct Line: Decodable { let event: BotEvent }

    static func importIfRequested(store: SQLiteDomainStore) async throws {
        guard let path = ProcessInfo.processInfo.environment["PDSH_A05_IMPORT_EVENTS"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return }
        var existing = Set<String>()
        if let current = try? await store.events(after: 0, limit: 100_000) {
            existing = Set(current.map(\.eventId))
        }
        let decoder = JSONDecoder()
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            guard !raw.isEmpty,
                  let line = try? decoder.decode(Line.self, from: Data(raw)),
                  !existing.contains(line.event.eventId) else { continue }
            do {
                _ = try await store.append(line.event)
                existing.insert(line.event.eventId)
            } catch {
                // A duplicate from an interrupted replay is already present;
                // any other failure must surface so the fixture is not silent.
                if let current = try? await store.events(after: 0, limit: 100_000),
                   current.contains(where: { $0.eventId == line.event.eventId }) {
                    continue
                }
                throw error
            }
        }
    }
}
