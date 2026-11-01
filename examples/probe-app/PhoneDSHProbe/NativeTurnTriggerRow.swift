// SPDX-License-Identifier: MIT
// NativeTurnTriggerRow: the official `turn-trigger` notice — the expandable
// card that explains why a non-human message (subagent, goal, schedule, job,
// webhook, plugin…) started a Turn.
//
// Official baseline: deepseek-harness 7be5505b0b, `TurnTriggerNodeView.tsx` +
// `TurnTriggerNodeView.module.css`, `turn-trigger.ts`, `locale.ts`
// (`message.trigger.*`). Contract:
// docs/receipts/ios-session-audit/04-subagent-inbox.md §2 (A1/A2) and
// 05-timeline.md §5. 402pt values: 338pt wide, radius 20, `#F9FAFB` fill,
// 0.5pt border, header padding 12×16 with 10pt internal gap, 14pt icon/title,
// 12/18 clock, 12pt chevron, body padding 40 leading / 16 trailing / 12 bottom.

import Foundation
import SwiftUI

// MARK: - Source family

/// The ten source families of official `turn-trigger.ts` (the shipped
/// `TRIGGER_ICONS` map). Titles are the official `message.trigger.*` copy.
enum NativeTurnTriggerSource: String, CaseIterable, Identifiable {
    case request
    case goal
    case agent
    case team
    case subagent
    case github
    case webhook
    case schedule
    case job
    case plugin

    var id: String { rawValue }

    /// Official `message.trigger.*` copy (locale.ts:53-62).
    var title: String {
        switch self {
        case .request: return "收到执行请求"
        case .goal: return "继续执行目标"
        case .agent: return "收到任务消息"
        case .team: return "收到团队消息"
        case .subagent: return "子任务状态更新"
        case .github: return "收到 GitHub 事件"
        case .webhook: return "收到外部事件"
        case .schedule: return "自动化任务"
        case .job: return "后台任务状态更新"
        case .plugin: return "插件状态更新"
        }
    }

    /// SF approximations of the official custom 20×20 glyphs: request =
    /// `IconContextInjectionOutlineRegular`, goal = `IconGoalOutlineRegular`,
    /// agent = `IconPaperPlaneOutlineRegular`, team/subagent =
    /// `IconAgentPresetOutlineRegular`, github = `IconBranchOutlineRegular`,
    /// webhook = `IconGlobeOutlineRegular`, schedule = `IconClockOutlineRegular`,
    /// job = `IconQueueOutlineRegular`, plugin = `IconCordisPluginOutlineRegular`.
    var systemImage: String {
        switch self {
        case .request: return "arrow.down.to.line"
        case .goal: return "target"
        case .agent: return "paperplane"
        case .team, .subagent: return "person.2"
        case .github: return "arrow.triangle.branch"
        case .webhook: return "globe"
        case .schedule: return "clock"
        case .job: return "list.bullet"
        case .plugin: return "puzzlepiece.extension"
        }
    }

    /// Official `turnTriggerDetails`: `source.kind` first, then the webhook
    /// provider (`github`); every unknown or custom source falls back to
    /// `request` so the notice still renders.
    static func resolve(kind: String, provider: String? = nil) -> NativeTurnTriggerSource {
        switch kind {
        case "goal": return .goal
        case "agent-message": return .agent
        case "team-message": return .team
        case "subagent-settled": return .subagent
        case "webhook": return provider == "github" ? .github : .webhook
        case "schedule": return .schedule
        case "tool-jobs": return .job
        case "cordis-host-runner": return .plugin
        default: return .request
        }
    }
}

// MARK: - Data

/// One waking notice: source family, event time, and the model-facing body.
struct NativeTurnTriggerData: Equatable {
    var source: NativeTurnTriggerSource
    var time: Date?
    var content: String
    var explanation: String

    /// Official `message.trigger.explanation`.
    static let defaultExplanation = "这条通知触发了本轮回复。"

    init(source: NativeTurnTriggerSource,
         time: Date? = nil,
         content: String,
         explanation: String = NativeTurnTriggerData.defaultExplanation) {
        self.source = source
        self.time = time
        self.content = content
        self.explanation = explanation
    }
}

// MARK: - Typography

/// The official `--dsw-font-xxs-12` line box is 12/18. SwiftUI adds leading on
/// top of the 12pt system font's own ~14.32pt line box, so 3.68pt of extra
/// leading reaches 18pt. (`NativeParityTokens` publishes 14/24 and 13/24
/// deltas only, so the caption delta stays local to this file.)
private enum NativeTriggerCaptionTypography {
    static let extraLeading: CGFloat = 3.68
}

// MARK: - Row

/// The trigger card. Official expansion is local disclosure state (default
/// collapsed), so the row owns it; `initiallyExpanded` exists for previews.
struct NativeTurnTriggerRow: View {
    let data: NativeTurnTriggerData
    private let maxWidth: CGFloat
    @State private var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(data: NativeTurnTriggerData,
         initiallyExpanded: Bool = false,
         maxWidth: CGFloat = NativeParityTokens.contentWidth) {
        self.data = data
        self.maxWidth = maxWidth
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                bodyContent
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(NativeParityTokens.turnTriggerBG)
        .clipShape(RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5)
        }
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.1)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: data.source.systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 14, height: 14)
                Text(data.source.title)
                    .font(.system(size: NativeParityTokens.bodySize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let time = data.time {
                    Text(NativeMessageClock.string(for: time))
                        .font(.system(size: NativeParityTokens.captionSize))
                        .lineLimit(1)
                        .frame(height: NativeParityTokens.captionLineHeight)
                }
                // SF approximation of `IconChevronDownOutlineRegular` (12pt).
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(NativeParityTokens.labelTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(data.source.title)
        .accessibilityValue(accessibilityValue)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(data.explanation)
                .font(.system(size: NativeParityTokens.captionSize))
                .lineSpacing(NativeTriggerCaptionTypography.extraLeading)
                .foregroundStyle(NativeParityTokens.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
            NativeTurnTriggerContentText(content: data.content)
        }
        .padding(.leading, 40)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        let expanded = isExpanded ? "已展开" : "已折叠"
        guard let time = data.time else { return expanded }
        return "\(NativeMessageClock.string(for: time))，\(expanded)"
    }
}

/// Official `.content`: 12/18, `pre-wrap`, max-height 240 with `overflow: auto`.
/// SwiftUI needs the natural height to decide whether a scroll container is
/// required, so a preference reports it and only overflowing bodies scroll.
private struct NativeTurnTriggerContentText: View {
    let content: String

    @State private var contentHeight: CGFloat = 0

    private static let maxHeight: CGFloat = 240

    var body: some View {
        Group {
            if contentHeight > Self.maxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    text
                }
                .frame(height: Self.maxHeight)
            } else {
                text
            }
        }
        .onPreferenceChange(NativeTurnTriggerContentHeightKey.self) { height in
            contentHeight = height
        }
    }

    private var text: some View {
        Text(content)
            .font(.system(size: NativeParityTokens.captionSize))
            .lineSpacing(NativeTriggerCaptionTypography.extraLeading)
            .foregroundStyle(NativeParityTokens.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NativeTurnTriggerContentHeightKey.self,
                        value: proxy.size.height)
                }
            }
    }
}

private struct NativeTurnTriggerContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if DEBUG

private struct NativeTurnTriggerRowPreview: View {
    private static let longContent: String = {
        let head = """
            子智能体已完成：修复了登录页的空白状态，并补上了回归测试。

            路径：Examples/Probe/LoginView.swift
            验证：在 402pt 宽度下连续打开 5 次，空白状态均未复现。

            """
        return head + String(repeating: "重复的诊断日志行，用来触发 240pt 上限与滚动。\n", count: 12)
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("折叠（默认）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTriggerRow(data: NativeTurnTriggerData(
                    source: .subagent,
                    time: Date(),
                    content: "子智能体已完成：聊天页空白状态已修复。"))

                Text("展开（含 240pt 上限滚动）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTriggerRow(
                    data: NativeTurnTriggerData(
                        source: .subagent,
                        time: Date(),
                        content: Self.longContent),
                    initiallyExpanded: true)

                Text("无时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeTurnTriggerRow(
                    data: NativeTurnTriggerData(source: .request, content: "外部请求已排队。"),
                    initiallyExpanded: true)

                Text("10 种来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(NativeTurnTriggerSource.allCases) { source in
                    HStack(spacing: 10) {
                        Image(systemName: source.systemImage)
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 14, height: 14)
                        Text(source.title)
                            .font(.system(size: 14))
                        Text(source.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                }
            }
            .frame(width: NativeParityTokens.contentWidth, alignment: .leading)
            .padding(32)
        }
    }
}

struct NativeTurnTriggerRow_Previews: PreviewProvider {
    static var previews: some View {
        NativeTurnTriggerRowPreview()
    }
}

#endif
