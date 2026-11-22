// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import ProbeKit

/// Boot-time session recovery rule for the phone DSH chat (pure, so the
/// simulator suite can exercise it without booting an engine).
enum ChatSessionBoot {
    /// True when the engine reports the requested session as not found
    /// (`session/not-found` mapped by `DSHRemoteTransport`).
    static func isMissingSession(_ error: Error) -> Bool {
        (error as? ProviderError) == .invalidRequest("session_not_found")
    }

    /// True only when a remembered session id was requested and the engine
    /// reports that session as not found. Any other failure keeps the boot
    /// error, and a fresh-session request never falls back to anything.
    static func isMissingRememberedSession(_ error: Error, requested: String?) -> Bool {
        guard requested != nil else { return false }
        return isMissingSession(error)
    }
}

/// Per-drain bookkeeping for queued sends whose target session could not be
/// activated (host/v1 §10: per-session FIFO, sessions are independent).
///
/// A held session skips its own later entries so FIFO holds inside it, but it
/// never blocks another session's entries. A session the engine reported as
/// not found is remembered for that engine incarnation, so a drain does not
/// repaint its cached tail and re-ask the engine on every pass. That verdict is
/// the proof for §10 `queued → targetLost` (PC-20261122-outbox-lost-target);
/// entries in any other state keep their own rules.
struct OutboxActivationHolds {
    private(set) var held: Set<String> = []
    private var missing: Set<String> = []
    private var missingIncarnation: Int?

    /// Starts one drain pass. `missing` survives passes of the same engine
    /// incarnation; a new engine instance asks again once.
    mutating func beginPass(incarnation: Int) {
        held = []
        if missingIncarnation != incarnation {
            missing = []
            missingIncarnation = incarnation
        }
    }

    func isHeld(_ sessionID: String) -> Bool { held.contains(sessionID) }

    func isKnownMissing(_ sessionID: String) -> Bool { missing.contains(sessionID) }

    mutating func hold(_ sessionID: String) { held.insert(sessionID) }

    /// True only for a `queued` entry whose session this engine incarnation
    /// answered `session/not-found` for. Nothing else is proof.
    func provesTargetLost(_ entry: SendOutboxEntry) -> Bool {
        entry.state == .queued && missing.contains(entry.sessionId)
    }

    mutating func markMissing(_ sessionID: String) {
        missing.insert(sessionID)
        held.insert(sessionID)
    }
}
