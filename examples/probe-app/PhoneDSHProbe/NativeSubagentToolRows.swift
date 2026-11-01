// SPDX-License-Identifier: MIT
//
// WS-E — subagent tool rows. One 24pt disclosure row per shipped subagent /
// teammate tool, with the official title, icon, collapsed summary, run state,
// and the recorded-result details card.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   ui-tool/.../toolview/details-row.tsx:19-31 (icons), tool-call-model.ts:103
//   (titles), control-details-model.ts:133-151 (receipts), ToolRow.module.css
//   (24pt row: 16 leading + 6 gap + 13/24 title + 2px dot + 8 gap + summary),
//   ToolDetails.module.css (radius 16, 0.5 border-l1, code block bg, 13/20).
//
// Official collapsed summaries the integration layer passes in:
//   subagent → "<prompt> · 已启动" (receipt) or "智能体回复";
//   send_message → "<agent id> · 消息已送达";
//   interrupt_agent → "<agent id> · 已请求中断";
//   list_agents → "{n} 个智能体"; wait_agent → "子智能体状态" / "没有正在运行的子智能体";
//   spawn_teammate → the member name.

import SwiftUI

enum NativeSubagentToolKind: String, CaseIterable, Identifiable, Hashable {
    case subagent
    case listAgents = "list_agents"
    case sendMessage = "send_message"
    case waitAgent = "wait_agent"
    case interruptAgent = "interrupt_agent"
    case spawnTeammate = "spawn_teammate"

    var id: String { rawValue }

    // Pinned to the checked-in 7be5505b0b locale (`查看子智能体` /
    // `中断智能体` / `创建队友`); the assignment's longer working names are not
    // the shipped copy.
    var title: String {
        switch self {
        case .subagent: "创建子智能体"
        case .listAgents: "查看子智能体"
        case .sendMessage: "发送消息"
        case .waitAgent: "等待子智能体"
        case .interruptAgent: "中断智能体"
        case .spawnTeammate: "创建队友"
        }
    }

    /// Official detailIcon: subagent = IconAgentPresetOutlineRegular; the five
    /// teammate tools (list/send/wait/interrupt/spawn) = IconUsersOutlineRegular.
    var systemImage: String {
        self == .subagent ? "person.badge.plus" : "person.2"
    }

    var targetLabel: String {
        switch self {
        case .spawnTeammate: "成员"
        default: "智能体 ID"
        }
    }

    var messageLabel: String {
        switch self {
        case .subagent: "任务内容"
        case .sendMessage: "消息"
        case .spawnTeammate: "成员信息"
        default: "内容"
        }
    }

    var resultLabel: String {
        self == .subagent ? "智能体回复" : "结果"
    }
}

enum NativeSubagentToolPhase: String, CaseIterable, Hashable {
    case preparing
    case running
    case ok
    case error
    case stopped

    var isActive: Bool { self == .preparing || self == .running }

    var label: String {
        switch self {
        case .preparing: "正在准备调用"
        case .running: "运行中"
        case .ok: "已完成"
        case .error: "失败"
        case .stopped: "已停止"
        }
    }
}

enum NativeSubagentBadgeTone: String, Hashable {
    case info
    case success
    case warning
    case error
    case neutral

    /// Official badge tones: business #4176E6, success #22C55E,
    /// warn #F59E0B, error #EC1313, neutral label-caption.
    var color: Color {
        switch self {
        case .info: NativeParityTokens.color(light: 0x4176E6, dark: 0x7AAAFF)
        case .success: NativeParityTokens.success
        case .warning: NativeParityTokens.color(light: 0xF59E0B, dark: 0xF59E0B)
        case .error: NativeParityTokens.error
        case .neutral: NativeParityTokens.labelCaption
        }
    }
}

struct NativeSubagentBadge: Hashable {
    var label: String
    var tone: NativeSubagentBadgeTone = .neutral
}

struct NativeSubagentToolItem: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var badge: NativeSubagentBadge? = nil
}

struct NativeSubagentToolRowData: Identifiable, Hashable {
    let id: String
    var kind: NativeSubagentToolKind
    var phase: NativeSubagentToolPhase = .ok
    var summary: String = ""
    /// First error line, shown instead of the summary on a failed row.
    var errorSummary: String? = nil
    var badge: NativeSubagentBadge? = nil
    var target: String? = nil
    var statusText: String? = nil
    /// Prompt / message body.
    var message: String? = nil
    /// Agent reply / recorded result.
    var result: String? = nil
    var items: [NativeSubagentToolItem] = []
    var caption: String? = "调用结果"

    var collapsedSummary: String {
        switch phase {
        case .error: errorSummary ?? summary
        case .stopped: summary.isEmpty ? "已停止" : summary
        default: summary
        }
    }

    var hasDetails: Bool {
        phase != .preparing
            && (badge != nil || target != nil || statusText != nil
                || message != nil || result != nil || !items.isEmpty)
    }
}

struct NativeSubagentToolRow: View {
    let data: NativeSubagentToolRowData
    @State private var expanded: Bool

    init(data: NativeSubagentToolRowData, initiallyExpanded: Bool = false) {
        self.data = data
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                collapsedRow
            }
            .buttonStyle(.plain)
            .disabled(!data.hasDetails)
            .accessibilityLabel(Text(data.kind.title))
            .accessibilityValue(Text(accessibilityValue))
            if expanded && data.hasDetails {
                NativeSubagentToolDetails(data: data)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collapsedRow: some View {
        HStack(spacing: 0) {
            ZStack {
                Image(systemName: data.kind.systemImage)
                    .font(.system(size: 14))
                    .opacity(expanded ? 0 : 1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .opacity(expanded ? 1 : 0)
            }
            .foregroundStyle(NativeParityTokens.labelTertiary)
            .frame(width: 16, height: 16)
            .padding(.trailing, 6)

            Text(data.kind.title)
                .font(.system(size: 13))
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .lineLimit(1)
                .layoutPriority(1)

            if !data.collapsedSummary.isEmpty {
                Circle()
                    .fill(NativeParityTokens.labelCaption)
                    .frame(width: 2, height: 2)
                    .padding(.horizontal, 8)
                NativeSubagentToolSummary(text: data.collapsedSummary,
                                          active: data.phase.isActive,
                                          color: summaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.1), value: expanded)
    }

    private var summaryColor: Color {
        switch data.phase {
        case .error: NativeParityTokens.error
        case .stopped: NativeParityTokens.warning
        default: NativeParityTokens.labelTertiary
        }
    }

    private var accessibilityValue: String {
        [data.phase.label, data.badge?.label, data.collapsedSummary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Official TextShimmer is a 1.5s sweep; a 1.2s opacity pulse is the
/// reduce-motion-safe approximation (no gradient mask needed).
private struct NativeSubagentToolSummary: View {
    let text: String
    let active: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .opacity(active && dimmed && !reduceMotion ? 0.55 : 1)
            .onAppear { start() }
            .onChange(of: active) { _, _ in start() }
    }

    private func start() {
        guard active, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

private struct NativeSubagentToolDetails: View {
    let data: NativeSubagentToolRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption = data.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeParityTokens.labelCaption)
                    .padding(.bottom, 6)
            }
            if let badge = data.badge {
                badgeView(badge).padding(.bottom, 6)
            }
            if let target = data.target {
                field(data.kind.targetLabel, target)
            }
            if let status = data.statusText {
                field("状态", status)
            }
            if let message = data.message, !message.isEmpty {
                prose(data.kind.messageLabel, message)
            }
            if let result = data.result, !result.isEmpty {
                prose(data.kind.resultLabel, result)
            }
            if !data.items.isEmpty {
                itemList.padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeParityTokens.codeBlock,
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5)
        }
        .padding(.leading, 4)
        .padding(.vertical, 4)
    }

    private func badgeView(_ badge: NativeSubagentBadge) -> some View {
        HStack(spacing: 5) {
            Circle().fill(badge.tone.color).frame(width: 5, height: 5)
            Text(badge.label)
                .font(.system(size: 12))
                .foregroundStyle(badge.tone.color)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(NativeParityTokens.labelCaption)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(NativeParityTokens.labelSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func prose(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(NativeParityTokens.labelCaption)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(NativeParityTokens.labelSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var itemList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(data.items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundStyle(NativeParityTokens.labelSecondary)
                                .lineLimit(1)
                                .frame(height: 17)
                            let secondary = [item.subtitle, item.detail]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                            if !secondary.isEmpty {
                                Text(secondary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(NativeParityTokens.labelTertiary)
                                    .lineLimit(1)
                                    .frame(height: 15)
                            }
                        }
                        Spacer(minLength: 8)
                        if let badge = item.badge {
                            badgeView(badge)
                        }
                    }
                    .padding(.vertical, 6)
                    if index < data.items.count - 1 {
                        Rectangle()
                            .fill(NativeParityTokens.borderL2)
                            .frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .frame(height: min(CGFloat(data.items.count) * 44, 320))
    }
}

#if DEBUG
private let nativeSubagentToolPreviewRows: [NativeSubagentToolRowData] = [
    .init(id: "1", kind: .subagent, summary: "定位 subagent 视图 · 已启动",
          badge: .init(label: "已启动", tone: .info), target: "sub-7f3a",
          statusText: "运行中", message: "定位 subagent 视图"),
    .init(id: "2", kind: .sendMessage, summary: "sub-7f3a · 消息已送达",
          badge: .init(label: "消息已送达", tone: .success), target: "sub-7f3a",
          statusText: "已接收", message: "页头目录已完成，请验收。"),
    .init(id: "3", kind: .interruptAgent, summary: "sub-7f3a · 已请求中断",
          badge: .init(label: "已请求中断", tone: .warning), target: "sub-7f3a",
          statusText: "运行中"),
    .init(id: "4", kind: .listAgents, summary: "2 个智能体",
          items: [.init(id: "a", title: "探索代码库", subtitle: "sub-7f3a",
                        detail: "parent=root depth=1", badge: .init(label: "运行中", tone: .info)),
                  .init(id: "b", title: "实现目录", subtitle: "sub-91c2",
                        detail: "parent=root depth=1", badge: .init(label: "已完成", tone: .success))]),
    .init(id: "5", kind: .waitAgent, summary: "子智能体状态",
          badge: .init(label: "等待超时", tone: .neutral), statusText: "等待超时"),
    .init(id: "6", kind: .spawnTeammate, summary: "reviewer",
          badge: .init(label: "已启动", tone: .info), target: "reviewer",
          message: "审查子智能体实现"),
]

#Preview("子智能体工具行 · 六种") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(nativeSubagentToolPreviewRows) { row in
            NativeSubagentToolRow(data: row)
        }
    }
    .padding(24)
}

#Preview("子智能体工具行 · 状态") {
    VStack(alignment: .leading, spacing: 10) {
        NativeSubagentToolRow(data: .init(id: "p", kind: .subagent, phase: .preparing,
                                          summary: "subagent"))
        NativeSubagentToolRow(data: .init(id: "r", kind: .subagent, phase: .running,
                                          summary: "定位 subagent 视图"))
        NativeSubagentToolRow(data: .init(id: "o", kind: .subagent,
                                          summary: "定位 subagent 视图 · 已启动"))
        NativeSubagentToolRow(data: .init(id: "e", kind: .subagent, phase: .error,
                                          errorSummary: "子智能体启动失败：配额不足"))
        NativeSubagentToolRow(data: .init(id: "s", kind: .sendMessage, phase: .stopped,
                                          summary: "sub-7f3a · 消息未发送"))
    }
    .padding(24)
}

#Preview("子智能体工具行 · 展开") {
    VStack(alignment: .leading, spacing: 16) {
        NativeSubagentToolRow(data: nativeSubagentToolPreviewRows[0], initiallyExpanded: true)
        NativeSubagentToolRow(data: nativeSubagentToolPreviewRows[3], initiallyExpanded: true)
    }
    .padding(24)
}
#endif
