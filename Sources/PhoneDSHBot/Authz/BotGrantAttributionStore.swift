// SPDX-License-Identifier: MIT

import Foundation

/// Per-call authorization attribution. The authorizer records the real
/// `BotGrant.id` values it evaluated for a tool call; the durable writers read
/// them when the observation is produced. It never invents a grant and never
/// maps a different call's grant onto this one.
public actor BotGrantAttributionStore {
    private var grantsByCall: [String: [String]] = [:]

    public init() {}

    public func note(callId: String, grantIds: [String]) {
        guard !callId.isEmpty else { return }
        let unique = grantIds.filter { !$0.isEmpty }
        if unique.isEmpty { grantsByCall.removeValue(forKey: callId) }
        else { grantsByCall[callId] = unique }
    }

    /// First real grant evaluated for this call, if any. Callers must not use
    /// this as a substitute for a source that was never authorized.
    public func grantId(callId: String) -> String? {
        grantsByCall[callId]?.first
    }

    public func clear(callId: String) {
        grantsByCall.removeValue(forKey: callId)
    }
}
