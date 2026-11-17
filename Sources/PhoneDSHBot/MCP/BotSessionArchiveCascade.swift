// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

/// The Worker-side `workspace/archiveSession` step of the Bot delete cascade
/// (GAP-45). It exists as its own type so the step is reversible and testable.
///
/// Archiving is a durable Worker write (the workspace registry's
/// `archivedSessionIds`), and the Worker's archived-session gate ends every
/// model step of an archived session as `blocked`. The cascade archives the
/// Bot's sessions *before* it deletes the profile record, so a later step that
/// fails (`BotDeletionPlan` then rethrows and the Bot stays in the roster) used
/// to leave a live Bot whose own `gb-<id>` session stayed archived: every turn
/// of that Bot was refused without a model call. `restore` is the step's
/// rollback; it lifts only what this cascade archived, never an id that was
/// already archived before it ran (for example an old main-chat epoch).
public enum BotSessionArchiveCascade {
    /// What one `archive` call changed on the Worker.
    public struct Receipt: Equatable, Sendable {
        /// Ids this call newly archived, in call order.
        public var archivedHere: [String]

        public init(archivedHere: [String] = []) { self.archivedHere = archivedHere }
    }

    /// `unarchiveSession` on an id that is not archived writes nothing and returns the current
    /// set, so it doubles as a read of that set (there is no list endpoint for it). The id is
    /// outside the `gb-` namespace and is never a session.
    static let probeSessionID = "zz-archive-cascade-probe"

    /// Archives `sessions`. Best effort per id (an id the Worker does not know is not an error
    /// of the cascade). The receipt names only ids this call archived.
    public static func archive(_ sessions: [String],
                               via transport: any DSHRemoteTransport) async -> Receipt {
        let before = await archivedSet(via: transport)
        var archivedHere: [String] = []
        for sessionID in sessions where !(before?.contains(sessionID) ?? false) {
            guard (try? await transport.call("workspace/archiveSession", args: .object([
                "request": .object([
                    "sessionId": .string(sessionID), "stopActivity": .bool(false),
                ]),
            ]))) != nil else { continue }
            archivedHere.append(sessionID)
        }
        return Receipt(archivedHere: archivedHere)
    }

    /// Rollback of `archive`: unarchives exactly the ids the receipt names.
    public static func restore(_ receipt: Receipt,
                               via transport: any DSHRemoteTransport) async {
        for sessionID in receipt.archivedHere {
            _ = try? await transport.call("workspace/unarchiveSession", args: .object([
                "request": .object(["sessionId": .string(sessionID)]),
            ]))
        }
    }

    /// The Worker's archived-session set, or nil when it cannot be read.
    public static func archivedSet(via transport: any DSHRemoteTransport) async -> Set<String>? {
        guard let value = try? await transport.call("workspace/unarchiveSession", args: .object([
            "request": .object(["sessionId": .string(probeSessionID)]),
        ])), let ids = value["archivedSessionIds"]?.arrayValue else { return nil }
        return Set(ids.compactMap { $0.stringValue })
    }
}
