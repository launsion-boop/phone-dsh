// SPDX-License-Identifier: MIT

import Foundation

/// Decision for one Bot use of an official skill body. The gate reads only L's
/// derivation view (`status` + reasons); it never opens the skill file or scans
/// the body, and it never turns absent linege into `current`.
public enum BotSkillUseDecision: Sendable, Equatable {
    case allowed
    case denied(status: BotProvenanceStatus, reasons: [BotProvenanceReason])

    public var denialCode: String? {
        guard case .denied(let status, _) = self else { return nil }
        return "skill-provenance-\(status.rawValue)"
    }
}

/// Minimal official-compatible gate for the Bot `skill` tool / catalog use.
/// Only a `current` derivation is readable; erased/revoked/changed/unavailable
/// and unknown all deny with their real status, so an unknown skill cannot be
/// presented as current. This type does not register a skill provider.
public enum BotSkillUseGate {
    public static func decide(
        status: BotProvenanceStatus,
        reasons: [BotProvenanceReason] = []
    ) -> BotSkillUseDecision {
        guard status == .current else {
            return .denied(status: status, reasons: reasons)
        }
        return .allowed
    }
}
