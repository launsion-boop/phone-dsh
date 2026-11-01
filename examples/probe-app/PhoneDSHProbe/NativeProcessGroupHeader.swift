// SPDX-License-Identifier: MIT
// NativeProcessGroupHeader: the official process-group header — a 16pt leading
// box that swaps an activity glyph for a chevron, plus a 14pt title that
// shimmers while the group is live.
//
// Official baseline: deepseek-harness 7be5505b0b, `ChatGroupSeat.tsx`
// (`ProcessGroupHeader`) + `ChatGroupSeat.module.css` (`.title`, `.leading`),
// `step-process.ts`. Contract: docs/receipts/ios-session-audit/05-timeline.md
// §2.3 (T-02) and 04-subagent-inbox.md §2 (A4).
// 402pt values: 16×16 leading box with a 14pt glyph, 6pt gap, 14pt tertiary
// title, 100ms icon/chevron crossfade, 8pt header padding-bottom when open.
//
// The body is NOT part of this view: the caller owns the official 6pt
// `--dsh-chat-flow-gap` between members. Do not add a gap between this header
// and the body — the expanded header already carries the official 8pt.

import SwiftUI

// MARK: - Activity glyphs

/// The official `PROCESS_ICONS` activity families (`ChatGroupSeat.tsx:44-52`).
enum NativeProcessGroupGlyph: String, CaseIterable, Identifiable {
    case thinking
    case read
    case readImage
    case search
    case edit
    case write
    case commands
    case code
    case webSearch
    case webFetch
    case subagents
    case plan
    case questions
    case tools

    var id: String { rawValue }

    /// SF approximations of the official custom glyphs: think =
    /// `IconThinkOutlineRegular`, read/readImage = `IconBrowseOutlineRegular`,
    /// search = `IconSearchOutlineRegular`, edit/write = `IconEditOutlineRegular`,
    /// commands = `IconApiOutlineRegular`, code = `IconCodeOutlineRegular`,
    /// webSearch = `IconGlobeOutlineRegular`, webFetch =
    /// `IconBrowseOutlineRegular`, subagents = `IconAgentPresetOutlineRegular`,
    /// plan = `IconPlanOutlineRegular`, questions = `IconQuestionOutlineRegular`,
    /// tools = `IconSparkleRegular`.
    var systemImage: String {
        switch self {
        case .thinking: return "brain.head.profile"
        case .read: return "doc.text"
        case .readImage: return "photo"
        case .search: return "magnifyingglass"
        case .edit: return "pencil"
        case .write: return "square.and.pencil"
        case .commands: return "terminal"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .webSearch: return "globe"
        case .webFetch: return "safari"
        case .subagents: return "person.2"
        case .plan: return "checklist"
        case .questions: return "questionmark.circle"
        case .tools: return "sparkles"
        }
    }
}

// MARK: - Header

/// One process-group header row. The parent owns expansion state (a group seat
/// holds several headers) and renders the members below it.
struct NativeProcessGroupHeader: View {
    var title: String
    var glyph: NativeProcessGroupGlyph = .tools
    /// Live groups shimmer their title (`TextShimmer active`).
    var isRunning: Bool = false
    var isExpanded: Bool = false
    /// Optional official header-catalog suffix, ` · {count} 个子智能体`.
    /// The shipped group header does not show a count (the `{count} 个 subagent`
    /// locale key is unused), so this stays opt-in.
    var subagentCount: Int?
    var onToggle: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 6) {
                leading
                NativeTurnShimmerText(
                    text: displayTitle,
                    active: isRunning,
                    font: .system(size: 14),
                    color: NativeParityTokens.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Official title line box is the body's 24pt line; the leading
            // 16pt box centers inside it. Expanded adds 8pt below.
            .frame(height: NativeParityTokens.bodyLineHeight, alignment: .leading)
            .padding(.bottom, isExpanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayTitle)
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
    }

    /// 16×16 box; the 14pt glyph and the chevron sit on top of each other and
    /// cross-fade on expansion (touch has no hover, so 展开 replaces the
    /// glyph), exactly like `.leading`/`.activityIcon`/`.chevron`.
    private var leading: some View {
        ZStack {
            // SF approximation of the official activity glyph (14pt in a 16pt box).
            Image(systemName: glyph.systemImage)
                .font(.system(size: 14, weight: .regular))
                .opacity(isExpanded ? 0 : 1)
            // Official open state uses the "up" chevron, closed state "down".
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .regular))
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(NativeParityTokens.labelTertiary)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isExpanded)
        .accessibilityHidden(true)
    }

    private var displayTitle: String {
        guard let count = subagentCount, count > 0 else { return title }
        // Official separator `message.turnProcess.separator` = ` · `.
        return title + " · \(count) 个子智能体"
    }
}

#if DEBUG

private struct NativeProcessGroupHeaderPreview: View {
    @State private var collapsedExpanded = false
    @State private var runningExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("运行中 · 展开（14pt shimmer + 8pt 下内距）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeProcessGroupHeader(
                    title: "正在协调子智能体",
                    glyph: .subagents,
                    isRunning: true,
                    isExpanded: runningExpanded) {
                        runningExpanded.toggle()
                    }

                Text("已完成 · 折叠（点击展开，图标 → chevron 互换）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeProcessGroupHeader(
                    title: "已读取文件并执行了命令",
                    glyph: .commands,
                    isRunning: false,
                    isExpanded: collapsedExpanded) {
                        collapsedExpanded.toggle()
                    }

                Text("已完成 + 子智能体计数后缀")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeProcessGroupHeader(
                    title: "已协调子智能体",
                    glyph: .subagents,
                    isRunning: false,
                    isExpanded: false,
                    subagentCount: 3)

                Text("14 类活动图标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(NativeProcessGroupGlyph.allCases) { glyph in
                    HStack(spacing: 6) {
                        Image(systemName: glyph.systemImage)
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 16, height: 16)
                        Text(glyph.rawValue)
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                }
            }
            .frame(width: NativeParityTokens.contentWidth, alignment: .leading)
            .padding(32)
        }
    }
}

struct NativeProcessGroupHeader_Previews: PreviewProvider {
    static var previews: some View {
        NativeProcessGroupHeaderPreview()
    }
}

#endif
