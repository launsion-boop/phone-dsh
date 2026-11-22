// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore

/// Boot-time session recovery rule for the phone DSH chat (pure, so the
/// simulator suite can exercise it without booting an engine).
enum ChatSessionBoot {
    /// True only when a remembered session id was requested and the engine
    /// reports that session as not found. Any other failure keeps the boot
    /// error, and a fresh-session request never falls back to anything.
    static func isMissingRememberedSession(_ error: Error, requested: String?) -> Bool {
        guard requested != nil else { return false }
        return (error as? ProviderError) == .invalidRequest("session_not_found")
    }
}
