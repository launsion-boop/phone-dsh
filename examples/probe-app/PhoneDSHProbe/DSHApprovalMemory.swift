// SPDX-License-Identifier: MIT

import Foundation

/// The app's "always allow" memory for one DSH session.
///
/// DSH Remote's permission adapter only has `allowed-once` on the wire, so the
/// phone keeps the always decision locally and silently answers later approvals
/// for the same session + tool with `allow_once`. A deny or an explicit
/// allow-once clears the entry, so the next request asks again. Session ids
/// scope the grant: another chat never inherits it.
enum DSHApprovalMemory {
    private static let defaultsKey = "dev.phone-dsh.dsh-permission-always.v1"

    static func isAllowed(sessionID: String, tool: String) -> Bool {
        guard !sessionID.isEmpty, !tool.isEmpty else { return false }
        return entries()[sessionID]?.contains(tool) == true
    }

    static func remember(sessionID: String, tool: String) {
        guard !sessionID.isEmpty, !tool.isEmpty else { return }
        var all = entries()
        all[sessionID, default: []].insert(tool)
        write(all)
    }

    static func forget(sessionID: String, tool: String) {
        guard !sessionID.isEmpty, !tool.isEmpty else { return }
        var all = entries()
        all[sessionID]?.remove(tool)
        if all[sessionID]?.isEmpty == true { all.removeValue(forKey: sessionID) }
        write(all)
    }

    private static func entries() -> [String: Set<String>] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded.mapValues(Set.init)
    }

    private static func write(_ entries: [String: Set<String>]) {
        let encoded = entries.mapValues { $0.sorted() }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
