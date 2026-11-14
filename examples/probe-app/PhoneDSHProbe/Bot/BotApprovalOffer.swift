// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// What an approval card may offer beyond the single run it is asking about.
///
/// The durable projection writes `alwaysScope` on both events it uses for the
/// card (`BotApprovalCoordinator.request` → `"alwaysScope": offeredScope`, and
/// `resolve` → `alwaysScope` in `approval.decided`). `offeredScope` is
/// `"none"` as soon as one effect cannot stand (`BotToolEffect
/// .canUseStandingGrant`: destructive or unclassified tools), so a standing
/// decision on such an approval can only ever create a consumed once grant.
///
/// The field is *not* guaranteed on every approval row:
/// - A DSH `tool/call` row carries only the model's `RequestApproval`
///   arguments, and that tool schema has no `alwaysScope`
///   (`BotToolCatalog.swift`); the projection's `fieldsFrom(arguments)` cannot
///   invent one.
/// - `local-tool-permission` / `approval` payloads are free-form
///   (`BotSessionLogProjection.uiBody`), and cached rows written by an older
///   build may predate the field.
///
/// Absence therefore means "one-shot only", exactly like `"none"`: the card
/// never invents a standing control from a missing field.
enum BotApprovalOffer {
    /// The scopes a standing decision can actually grant.
    enum Standing: String, Equatable {
        case session
        case until

        var buttonTitle: String {
            switch self {
            case .session: return "本次对话都允许"
            case .until: return "总是允许"
            }
        }
    }

    /// The one-line limitation under the buttons of a one-shot-only card.
    static let onceOnlyNote = "此类操作只能允许一次，下次会重新询问"

    /// The standing scope the projected row offers, or `nil` when it can only
    /// be allowed once. Absent, `"none"`, `"once"` and unknown values all mean
    /// the same thing: no standing control.
    static func standingScope(_ alwaysScope: String?) -> Standing? {
        guard let raw = alwaysScope?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else { return nil }
        return Standing(rawValue: raw)
    }

    /// A standing request on a one-shot-only row is sent as `allowOnce`.
    ///
    /// The coordinator already resolves `always` on such a request to a
    /// consumed once grant (`decision == .always` with `alwaysScope` other than
    /// `session`/`until` → `.once`), so this only makes the wire decision agree
    /// with what the card can deliver. It also covers a stale row whose
    /// `alwaysScope` disappeared between rendering and the tap: the approval
    /// still proceeds once instead of failing with a decision the server would
    /// have silently narrowed anyway.
    static func effectiveDecision(_ requested: String, alwaysScope: String?) -> String {
        requested == "always" && standingScope(alwaysScope) == nil ? "allowOnce" : requested
    }

    /// The receipt for a settled approval row.
    ///
    /// A row is only reported as standing when it proves one. The tool result's
    /// `scope` is the grant the user actually received and wins over the offered
    /// `alwaysScope`; `"none"`/`"once"` (or a durable decision that is not
    /// `always`) keeps the receipt at 「已允许一次」 instead of "已总是允许".
    ///
    /// A status of `always` with no scope at all is the projection's own
    /// standing evidence: DSH `tool/call` receipt rows structurally never carry
    /// `alwaysScope` (`RequestApproval` has no such argument), so that receipt
    /// still reads 「已总是允许」. A durable `approval.decided` row records its
    /// own `decision`, so its forced once grant stays 「已允许一次」 even when
    /// the text fallback produced an `always` status.
    static func receiptLabel(status: String, alwaysScope: String?, effectiveScope: String?,
                             decision: String? = nil) -> String {
        let proven = normalizedScope(effectiveScope) ?? normalizedScope(alwaysScope)
        let standing = standingScope(proven)
        if status == "always" {
            if let standing {
                return BotApprovalReceipt.label(for: "always", scope: standing.rawValue)
            }
            if proven == nil, decision == nil {
                return BotApprovalReceipt.label(for: status)
            }
            return BotApprovalReceipt.label(for: "allowed")
        }
        if status == "allowed", decision?.lowercased() == "always", let standing {
            return BotApprovalReceipt.label(for: "always", scope: standing.rawValue)
        }
        return BotApprovalReceipt.label(for: status, scope: proven)
    }

    private static func normalizedScope(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }
}
