// SPDX-License-Identifier: MIT
// NativeTodoDock — the official `conversation.input.dock` To-dos strip (dock
// order 0) rendered natively for the 402pt phone session page.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx + .module.css
//   packages/client/ui-primitives/src/StateDot.tsx + .module.css
//
// Geometry (402pt: 1 CSS px == 1 pt): 338 x 36 while collapsed, radius 16,
// menu surface + 0.5pt hairline + `elevation-panel` shadows; checklist glyph 14,
// title 「任务」13/24 w500, progress 13/20 tertiary, chevron 14. The expanded list
// is capped at 180pt with 8pt row gaps (rows: 16pt status slot + 10pt gap +
// single-line 13/20 secondary). The chevron points UP while collapsed and DOWN
// while expanded — inverted versus the transcript disclosure rows — and the
// toggle has no expand animation. Empty/nil todos render nothing.

import SwiftUI

/// One entry of the host `todos` projection (official `TodoItem`).
public struct NativeTodoItem: Identifiable, Equatable {
    /// Official lifecycle union; `in_progress` is the wire value.
    public enum Status: String, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed

        /// Maps a host status string; nil for a forged/unknown value.
        public init?(wireValue: String) {
            self.init(rawValue: wireValue)
        }

        /// Official `todo.status.*` copy, used for each row's VoiceOver label.
        public var label: String {
            switch self {
            case .completed: return "已完成"
            case .inProgress: return "进行中"
            case .pending: return "待处理"
            }
        }
    }

    public let id: String
    public let content: String
    public let status: Status

    /// The official list keys rows by `content`; pass `id` when the host has one.
    public init(content: String, status: Status, id: String? = nil) {
        self.id = id ?? content
        self.content = content
        self.status = status
    }
}

/// The composer dock strip over the host `todos` projection.
public struct NativeTodoDock: View {
    /// Official `todo.title`.
    public static let title = "任务"

    private let todos: [NativeTodoItem]
    private let width: CGFloat
    @State private var collapsed: Bool

    /// - Parameters:
    ///   - todos: current projection; empty or nil renders nothing (official
    ///     `todos.length === 0 → null`).
    ///   - width: dock card width; 338 at the 402pt baseline
    ///     (`NativeParityTokens.contentWidth`).
    ///   - initiallyExpanded: previews/tests only — the official surface always
    ///     mounts collapsed.
    public init(todos: [NativeTodoItem],
                width: CGFloat = 338,
                initiallyExpanded: Bool = false) {
        self.todos = todos
        self.width = width
        _collapsed = State(initialValue: !initiallyExpanded)
    }

    public var body: some View {
        if todos.isEmpty {
            EmptyView()
        } else {
            dock
        }
    }

    // MARK: - Card

    private var dock: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed { list }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(NativeParityTokens.menu)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.02), radius: 16, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
    }

    // MARK: - Collapsed header

    private var header: some View {
        Button {
            // Official TodoPanel toggles the list without an expand animation.
            collapsed.toggle()
        } label: {
            HStack(spacing: 10) {
                TodoChecklistGlyph()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                Text(Self.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .fixedSize()
                Text(progressText)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NativeChatIcon(name: .chevronDown, size: 14)
                    // Collapsed = up, expanded = down (the inverse of transcript
                    // disclosure rows, per TodoPanel.tsx:81-83).
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .frame(width: 14, height: 14)
            }
            // 24pt title line + 2x6pt card padding = the official 36pt card.
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title) \(progressText)")
        .accessibilityValue(collapsed ? "已折叠" : "已展开")
        .accessibilityHint(collapsed ? "展开任务清单" : "折叠任务清单")
    }

    /// Official `progressLabel`: per-status counts joined by U+2002 + middot +
    /// U+2002 (CSS collapses ASCII runs, so the en spaces are literal); segments
    /// with a zero count are omitted entirely.
    private var progressText: String {
        let done = todos.filter { $0.status == .completed }.count
        let active = todos.filter { $0.status == .inProgress }.count
        let pending = todos.count - done - active
        var parts: [String] = []
        if done > 0 { parts.append("\(done) 已完成") }
        if active > 0 { parts.append("\(active) 进行中") }
        if pending > 0 { parts.append("\(pending) 待处理") }
        return parts.joined(separator: "\u{2002}·\u{2002}")
    }

    // MARK: - Expanded checklist

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(todos) { todo in
                    row(todo)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: listHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Every row is one 20pt line (13/20) with an 8pt gap; the official list is
    /// `max-height: 180px` with internal scrolling.
    private var listHeight: CGFloat {
        let rows = CGFloat(todos.count)
        let content = rows * 20 + max(0, rows - 1) * 8
        return min(NativeParityTokens.todoListMaxHeight, content)
    }

    private func row(_ todo: NativeTodoItem) -> some View {
        HStack(spacing: 10) {
            TodoStatusDot(status: todo.status)
                .frame(width: 16, height: 16)
            Text(todo.content)
                .font(.system(size: 13))
                .foregroundStyle(NativeParityTokens.labelSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(todo.status.label)，\(todo.content)")
    }
}

// MARK: - Official checklist glyph (IconChecklistOutlineRegular)

/// Two hollow bullets + two rules in the official 16-unit icon grid.
private struct TodoChecklistGlyph: View {
    private let lineWidth: CGFloat = 14.0 / 16.0

    var body: some View {
        ChecklistArtwork()
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private struct ChecklistArtwork: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 16
            var path = Path()
            for centerY in [CGFloat(4.5), CGFloat(11.5)] {
                path.addEllipse(in: CGRect(x: (3.75 - 1.75) * scale,
                                           y: (centerY - 1.75) * scale,
                                           width: 3.5 * scale,
                                           height: 3.5 * scale))
            }
            path.move(to: CGPoint(x: 7.5 * scale, y: 4.5 * scale))
            path.addLine(to: CGPoint(x: 13.5 * scale, y: 4.5 * scale))
            path.move(to: CGPoint(x: 7.5 * scale, y: 11.5 * scale))
            path.addLine(to: CGPoint(x: 13.5 * scale, y: 11.5 * scale))
            return path
        }
    }
}

// MARK: - Official StateDot (StateDot.tsx + .module.css)

/// Solid states keep a 10pt layout slot and paint one 6pt core; `in_progress` is
/// a 14pt ring (tertiary, 25% track) that spins 1.5s per turn unless Reduce
/// Motion is on, in which case it holds a fixed arc.
private struct TodoStatusDot: View {
    let status: NativeTodoItem.Status

    /// Official `state-idle-primary` (neutral-300 / neutral-600); not yet in the
    /// shared token file.
    private static let idle = NativeParityTokens.color(light: 0xD4D4D4, dark: 0x545557)

    var body: some View {
        switch status {
        case .completed:
            solid(NativeParityTokens.success)
        case .pending:
            solid(Self.idle)
        case .inProgress:
            NativeOngoingRing()
        }
    }

    private func solid(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .frame(width: 10, height: 10)
    }
}

/// StateDot `ongoing`: a 14pt ring (25% track, 1.2pt stroke) whose 12% arc turns
/// once per 1.5s; Reduce Motion holds the arc in place. Shared with
/// `NativePlanReviewCard`'s busy strip so both surfaces use one loader language.
struct NativeOngoingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(NativeParityTokens.labelTertiary.opacity(0.25), lineWidth: 1.2)
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

#if DEBUG
private extension NativeTodoItem {
    /// Realistic mid-turn checklist for previews.
    static var previewTodos: [NativeTodoItem] {
        [
            NativeTodoItem(content: "梳理 session/projections 的 todos 字段", status: .completed),
            NativeTodoItem(content: "实现 TodoDock 折叠条与三态状态点", status: .inProgress),
            NativeTodoItem(content: "把 todo_write 事件的清单写回投影", status: .pending),
            NativeTodoItem(content: "核对 338×36 / 圆角 16 / 列表 180 的像素基线", status: .pending),
            NativeTodoItem(content: "长条目验证单行省略：接入 /plan 与 plan review 之后再跑一遍 402pt 截图验收", status: .pending),
        ]
    }
}

struct NativeTodoDock_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .center, spacing: 16) {
            NativeTodoDock(todos: NativeTodoItem.previewTodos)
            NativeTodoDock(todos: NativeTodoItem.previewTodos, initiallyExpanded: true)
            NativeTodoDock(todos: [])
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("任务 dock：折叠 / 展开 / 空")
    }
}
#endif
