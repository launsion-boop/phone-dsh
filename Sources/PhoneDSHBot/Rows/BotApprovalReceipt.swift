// SPDX-License-Identifier: MIT

import Foundation

/// User-facing receipt text for an approval card. The same mapping is used by
/// the durable row projection and the SwiftUI card so the receipt always
/// matches the button the user actually pressed.
public enum BotApprovalReceipt {
    /// - Parameters:
    ///   - status: The projected status (`allowed`, `allowed-session`,
    ///     `always`, `denied`, `never`, `timed-out`, `expired`, `cancelled`).
    ///   - scope: The effective grant scope when the status alone cannot tell a
    ///     session grant from a standing one.
    public static func label(for status: String, scope: String? = nil) -> String {
        switch status {
        case "allowed": return "已允许一次"
        case "allowed-session": return "本次对话都允许"
        case "always":
            return scope == "session" ? "本次对话都允许" : "已总是允许"
        case "denied": return "已拒绝"
        case "never": return "已设为永不允许"
        case "timed-out": return "已超时，视为拒绝"
        case "expired": return "已过期，视为拒绝"
        case "cancelled": return "已取消"
        default: return "已处理"
        }
    }
}
