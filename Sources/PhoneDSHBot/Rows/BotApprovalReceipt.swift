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

    /// One human sentence for a cancelled approval's durable `reason`. The raw
    /// code (`worker_restarted`, `consumer_cancelled`, …) never reaches the
    /// approval-history UI; unknown codes fall back to the generic cancelled
    /// label so a future reason cannot leak an internal token.
    public static func cancellationReason(_ reason: String?) -> String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        switch reason.lowercased() {
        case "worker_restarted": return "App 重启时取消"
        case "consumer_cancelled", "consumer_canceled": return "请求已结束，已取消"
        case "shutdown": return "App 关闭时取消"
        case "bot_deleted": return "Bot 已删除时取消"
        case "task_stopped": return "任务已停止"
        case "routine_stopped": return "例行任务已停止"
        case "approval_expired", "expired": return "超过有效期，已取消"
        case "timeout", "timed_out", "timed-out", "timedout": return "等待超时，已取消"
        default: return "审批已取消"
        }
    }
}
