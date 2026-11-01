// SPDX-License-Identifier: MIT
// NativeTurnProcessRow: the official `turn-process` control row — the
// per-Turn "已完成 / 已停止 / 处理失败" label that doubles as the whole-Turn
// process disclosure switch.
//
// Official baseline: deepseek-harness 7be5505b0b, `TurnProcessNodeView.tsx` +
// `TurnProcessNodeView.module.css`, `message-chrome.ts` (`formatRunDuration`).
// Contract: docs/receipts/ios-session-audit/05-timeline.md §2.2 (T-01/T-04).
// 402pt values: 33pt row (8pt of it bottom padding), 0.5pt bottom border,
// 14/24 tertiary label, 14pt chevron 4pt after the label, 100ms 180° turn,
// disabled when the Turn has nothing to fold.

import Foundation
import SwiftUI

// MARK: - Duration

/// The official `formatRunDuration`: whole seconds, floored at one second,
/// no leading zeros, minutes only from 60s and hours only from 60min.
enum NativeRunDuration {
    /// One numeric value or localized unit inside an elapsed-time label.
    struct Part: Equatable {
        let text: String
        let isNumeric: Bool
    }

    /// Official units are `duration.secondUnit` / `minuteUnit` / `hourUnit`.
    static let secondUnit = "秒"
    static let minuteUnit = "分"
    static let hourUnit = "小时"

    /// Split elapsed seconds into the official number/unit runs.
    static func parts(elapsed: TimeInterval) -> [Part] {
        let milliseconds = max(1000, elapsed * 1000)
        let total = Int(milliseconds / 1000)
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let seconds = total % 60
        var parts: [Part] = []
        if hours > 0 {
            parts.append(Part(text: String(hours), isNumeric: true))
            parts.append(Part(text: hourUnit, isNumeric: false))
        }
        // Minutes appear whenever the total reached a minute, including 0分
        // inside an hour label (official `total >= 60` guard).
        if total >= 60 {
            parts.append(Part(text: String(minutes), isNumeric: true))
            parts.append(Part(text: minuteUnit, isNumeric: false))
        }
        parts.append(Part(text: String(seconds), isNumeric: true))
        parts.append(Part(text: secondUnit, isNumeric: false))
        return parts
    }

    /// The concatenated label, e.g. `1分20秒` or `1小时0分0秒`.
    static func string(elapsed: TimeInterval) -> String {
        parts(elapsed: elapsed).map(\.text).joined()
    }
}

// MARK: - State

/// The four visible states of the control row. Official `running` renders
/// nothing (`TurnProcessNodeView` returns null while `turn.status !== 'closed'`);
/// the row only exists for closed Turns.
enum NativeTurnProcessState: Equatable {
    case running
    case completed(elapsed: TimeInterval?)
    case stopped
    case failed

    /// Official copy (`locale.ts`): `message.turnProcess.*` / `message.stopped`.
    static let completedLabel = "已完成"
    static let completedWithDurationPrefix = "已完成，用时 "
    static let stoppedLabel = "已停止"
    static let failedLabel = "处理失败"

    /// Map a `turn/end.reason.kind` onto the row state.
    /// - Parameters:
    ///   - endReasonKind: `turn/end.data.reason.kind`; `nil` while the Turn is open.
    ///   - elapsed: seconds between `turn/start` and `turn/end`.
    static func resolve(endReasonKind: String?, elapsed: TimeInterval?) -> NativeTurnProcessState {
        guard let endReasonKind = endReasonKind else { return .running }
        switch endReasonKind {
        case "aborted", "interrupted":
            return .stopped
        case "error":
            return .failed
        default:
            // `completed`, `max-tokens` and unknown reasons keep the elapsed time.
            return .completed(elapsed: elapsed)
        }
    }

    /// Official `turnProcessAlwaysOpen` (`contract/turn-process.ts:53-60`):
    /// a running Turn and stops/failures never fold, so the row is a real
    /// disclosure only for a completed Turn. The caller also needs content
    /// before it may pass `isFoldable: true`.
    var alwaysOpen: Bool {
        switch self {
        case .running, .stopped, .failed:
            return true
        case .completed:
            return false
        }
    }

    /// VoiceOver / test copy. Stops and failures replace the duration.
    var label: String {
        switch self {
        case .running:
            return ""
        case .stopped:
            return Self.stoppedLabel
        case .failed:
            return Self.failedLabel
        case .completed(let elapsed):
            guard let elapsed = elapsed else { return Self.completedLabel }
            return Self.completedWithDurationPrefix + NativeRunDuration.string(elapsed: elapsed)
        }
    }
}

// MARK: - Row

/// The 33pt turn-process control row. Tapping toggles the whole-Turn process
/// disclosure; with `isFoldable == false` the row stays visible but inert and
/// drops the chevron, matching the official `disabled` button.
struct NativeTurnProcessRow: View {
    var state: NativeTurnProcessState = .completed(elapsed: nil)
    var isOpen: Bool = false
    var isFoldable: Bool = false
    var onToggle: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if case .running = state {
            // Official: an open Turn has no control row (the running status
            // carries the clock instead). Keep the state for the model layer.
            EmptyView()
        } else {
            Button {
                onToggle()
            } label: {
                content
            }
            .buttonStyle(.plain)
            .disabled(!isFoldable)
            .foregroundStyle(NativeParityTokens.labelTertiary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.label)
            .accessibilityValue(accessibilityValue)
        }
    }

    /// 33pt total: flexible 24.5pt label box, the official 8pt bottom
    /// padding, then the 0.5pt border inside the row height.
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                labelText
                    .lineSpacing(NativeParityTokens.bodyLineSpacing)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFoldable {
                    chevron
                        .padding(.leading, 4)
                }
            }
            .frame(maxHeight: .infinity)
            Color.clear
                .frame(height: 8)
            Rectangle()
                .fill(NativeParityTokens.borderL2)
                .frame(height: 0.5)
        }
        .frame(height: NativeParityTokens.turnProcessHeight)
        .contentShape(Rectangle())
    }

    /// Duration digits use the code family + tabular figures, as official
    /// `.durationNumber` does; the units stay in the 14pt UI font.
    private var labelText: Text {
        let body = Font.system(size: NativeParityTokens.bodySize)
        switch state {
        case .running:
            return Text("").font(body)
        case .stopped:
            return Text(NativeTurnProcessState.stoppedLabel).font(body)
        case .failed:
            return Text(NativeTurnProcessState.failedLabel).font(body)
        case .completed(let elapsed):
            guard let elapsed = elapsed else {
                return Text(NativeTurnProcessState.completedLabel).font(body)
            }
            var label = Text(NativeTurnProcessState.completedWithDurationPrefix).font(body)
            for part in NativeRunDuration.parts(elapsed: elapsed) {
                if part.isNumeric {
                    label = label + Text(part.text)
                        .font(.system(size: NativeParityTokens.bodySize, design: .monospaced))
                } else {
                    label = label + Text(part.text).font(body)
                }
            }
            return label
        }
    }

    /// SF approximation: the official glyph is `IconChevronDownOutlineRegular`
    /// (14×14). Rotation and 100ms ease match `.chevron`.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 14, weight: .regular))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isOpen)
    }

    /// Official `aria-expanded` is only present when the Turn has content.
    private var accessibilityValue: String {
        guard isFoldable else { return "" }
        return isOpen ? "已展开" : "已折叠"
    }
}

#if DEBUG

private struct NativeTurnProcessRowPreview: View {
    @State private var open = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("已完成（无时长）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnProcessRow(state: .completed(elapsed: nil), isOpen: false, isFoldable: true) {
                    open.toggle()
                }
                Text("已完成，用时 1分20秒（展开）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                NativeTurnProcessRow(state: .completed(elapsed: 80), isOpen: open, isFoldable: true) {
                    open.toggle()
                }
                Text("已完成，用时 1小时0分0秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                NativeTurnProcessRow(state: .completed(elapsed: 3600), isOpen: false, isFoldable: true)
                Text("已停止（不可折叠）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                NativeTurnProcessRow(state: .stopped)
                Text("处理失败（不可折叠）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                NativeTurnProcessRow(state: .failed)
                Text("运行中：官方不渲染此行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                NativeTurnProcessRow(state: .running, isOpen: false, isFoldable: true)
            }
            .frame(width: NativeParityTokens.contentWidth, alignment: .leading)
            .padding(32)
        }
    }
}

struct NativeTurnProcessRow_Previews: PreviewProvider {
    static var previews: some View {
        NativeTurnProcessRowPreview()
    }
}

#endif
