// SPDX-License-Identifier: MIT
// NativeTurnTail: the official `turn-tail` action row that closes a Turn —
// copy, feedback, optional slot actions, branch, usage and the clock.
//
// Official baseline: deepseek-harness 7be5505b0b, `TurnTailNodeView.tsx`,
// `MessageIconActions.tsx` + `.module.css`, `TurnUsagePanel.module.css`,
// `message-chrome.ts` (`formatMessageClock`). Contract:
// docs/receipts/ios-session-audit/05-timeline.md §2.4 (T-07) and
// 04-subagent-inbox.md. 402pt values: 28pt row, 8pt gap, 28×28 buttons with
// radius 8, 17pt glyphs, 12/24 clock, tertiary resting color, official
// `margin-top: 4px; margin-left: -6px`; usage collapses to a bare 28pt glyph
// on a phone (`TurnUsagePanel.module.css`, max-width 480px).
//
// Deliberately independent of `MessageIconActions`/`NativeChatTheme`: every
// callback is optional and defaults to a no-op so the row previews standalone.

import Foundation
import SwiftUI

// MARK: - Clock

/// The official `formatMessageClock`: 24-hour local clock; same calendar day →
/// `HH:mm`, same year → `M月d日 HH:mm`, otherwise `yyyy年M月d日 HH:mm`.
enum NativeMessageClock {
    static func string(for date: Date,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let clock = String(format: "%02d:%02d", hour, minute)
        let then = calendar.dateComponents([.year, .month, .day], from: date)
        let reference = calendar.dateComponents([.year, .month, .day], from: now)
        let month = then.month ?? 1
        let day = then.day ?? 1
        if then.year == reference.year && then.month == reference.month && then.day == reference.day {
            return clock
        }
        if then.year == reference.year {
            return "\(month)月\(day)日 \(clock)"
        }
        return "\(then.year ?? 1)年\(month)月\(day)日 \(clock)"
    }
}

// MARK: - Actions

/// Official `feedback.action.like` / `dislike` families.
enum NativeTurnTailFeedback {
    case like
    case dislike
}

/// One extra action for the official `assistant-actions` slot position
/// (between copy/feedback and branch). The callback defaults to a no-op.
struct NativeTurnTailAction: Identifiable {
    let id: String
    let systemImage: String
    let accessibilityLabel: String
    var action: () -> Void

    init(id: String,
         systemImage: String,
         accessibilityLabel: String,
         action: @escaping () -> Void = {}) {
        self.id = id
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }
}

// MARK: - Row

/// The 28pt turn-tail action row. Official order: copy → extra actions →
/// branch → usage → clock. Every action renders even without a callback so the
/// component can be previewed and wired incrementally.
struct NativeTurnTail: View {
    /// `turn/end` time; `nil` hides the clock.
    var time: Date?
    /// Caller-driven copy feedback (official swaps to a check for 1s).
    var isCopied: Bool = false
    /// Official `branchUnavailable`: the action stays visible at 40% opacity.
    var isBranchAvailable: Bool = true
    /// Official usage action only exists in `detailed` mode with token data,
    /// and collapses to a glyph-only button on a phone-width viewport.
    var showsUsage: Bool = false
    var extraActions: [NativeTurnTailAction] = []
    var onCopy: () -> Void = {}
    var onFeedback: (NativeTurnTailFeedback) -> Void = { _ in }
    var onBranch: () -> Void = {}
    var onUsage: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            actionButton(systemImage: isCopied ? "checkmark" : "doc.on.doc",
                         label: isCopied ? "复制成功" : "复制",
                         action: onCopy)
            actionButton(systemImage: "hand.thumbsup", label: "好的回答") {
                onFeedback(.like)
            }
            actionButton(systemImage: "hand.thumbsdown", label: "有问题的回答") {
                onFeedback(.dislike)
            }
            ForEach(extraActions) { extra in
                actionButton(systemImage: extra.systemImage,
                             label: extra.accessibilityLabel,
                             action: extra.action)
            }
            actionButton(systemImage: "arrow.triangle.branch",
                         label: "在新对话中分支",
                         isEnabled: isBranchAvailable,
                         hint: isBranchAvailable ? "" : "仅可从已完成轮次的最后一条消息分支",
                         action: onBranch)
            trailingInfo
        }
        .frame(height: 28)
        // Official `TurnTailNodeView.module.css` `.actions` offsets: the row
        // hangs 6pt into the transcript's leading padding and starts 4pt below
        // the previous row (12pt response gap + 4 = the official 16pt).
        .padding(.top, 4)
        .padding(.leading, -6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailingInfo: some View {
        HStack(spacing: 8) {
            if showsUsage {
                Button {
                    onUsage()
                } label: {
                    // SF approximation of `IconDatabaseOutlineRegular`; the
                    // official phone trigger is a bare 28pt glyph (15pt icon).
                    Image(systemName: "cylinder")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .accessibilityLabel("本轮用量")
            }
            if let time = time {
                Text(NativeMessageClock.string(for: time))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .lineLimit(1)
                    .frame(height: 24)
            }
        }
        // Official `.endInfo { margin-left: 8px }` adds to the row gap.
        .padding(.leading, 8)
    }

    private func actionButton(systemImage: String,
                              label: String,
                              isEnabled: Bool = true,
                              hint: String = "",
                              action: @escaping () -> Void) -> some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NativeParityTokens.labelTertiary)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

#if DEBUG

private struct NativeTurnTailPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("默认：复制 / 点赞 / 点踩 / 分支 / 时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTail(time: Date())

                Text("含用量与额外动作（复制后 checkmark）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTail(
                    time: Date(),
                    isCopied: true,
                    showsUsage: true,
                    extraActions: [
                        NativeTurnTailAction(id: "share",
                                             systemImage: "square.and.arrow.up",
                                             accessibilityLabel: "分享"),
                    ])

                Text("分支不可用（40% 不透明度）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTail(time: Date(), isBranchAvailable: false, showsUsage: true)

                Text("无时间 / 全部回调省略")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTail()
            }
            .frame(width: NativeParityTokens.contentWidth, alignment: .leading)
            .padding(32)
        }
    }
}

struct NativeTurnTail_Previews: PreviewProvider {
    static var previews: some View {
        NativeTurnTailPreview()
    }
}

#endif
