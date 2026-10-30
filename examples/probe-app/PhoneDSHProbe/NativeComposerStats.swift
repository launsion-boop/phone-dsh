// SPDX-License-Identifier: MIT

import SwiftUI

struct NativeComposerStats: View {
    let stats: NativeSessionStats?
    let usage: NativeTokenUsage?
    let pressure: NativeContextPressure?
    let breakdown: NativeContextBreakdown?
    @State private var detail: Detail?

    private enum Detail: Identifiable {
        case activity, usage, context
        var id: Int { hashValue }
    }

    @State private var preferences = NativeChatPreferences.shared

    var body: some View {
        if preferences.performanceUsage == .compact { compactView } else { detailedView }
    }

    private var compactView: some View {
        HStack(spacing: 8) {
            if let speed = stats?.tokensPerSecond {
                NativeChatIcon(name: .gauge, size: 14)
                Text("\(Int(speed.rounded())) tok/s")
            }
            if let hit = nativePercent(usage?.cacheHitPercent) {
                NativeChatIcon(name: .database, size: 14)
                Text(NativeText("缓存命中 ", "Cache hit ") + "\(hit)%")
            }
        }
        .modifier(NativeStatPill())
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var detailedView: some View {
        HStack(spacing: 4) {
            if let stats, stats.steps > 0 || stats.tokensPerSecond != nil {
                Button { detail = .activity } label: {
                    HStack(spacing: 6) {
                        NativeChatIcon(name: .gauge, size: 14)
                        if stats.steps > 0 { Text("\(stats.turns) 轮 \(stats.steps) 步") }
                        if let speed = stats.tokensPerSecond {
                            if stats.steps > 0 { Text("·") }
                            Text("\(Int(speed.rounded())) tok/s")
                        }
                    }
                    .modifier(NativeStatPill())
                }
                .buttonStyle(.plain)
            }
            if let usage, usage.billedInputTokens > 0 || usage.outputTokens > 0 {
                Button { detail = .usage } label: {
                    HStack(spacing: 6) {
                        NativeChatIcon(name: .database, size: 14)
                        Text("\(nativeCompactTokens(usage.totalTokens)) tok")
                        if let hit = nativePercent(usage.cacheHitPercent) { Text("· 缓存命中 \(hit)%") }
                    }
                    .modifier(NativeStatPill())
                }
                .buttonStyle(.plain)
            }
            if let percent = pressure?.percent {
                Button { detail = .context } label: {
                    HStack(spacing: 6) {
                        NativeContextRing(percent: percent)
                        Text("\(percent)%")
                    }
                    .modifier(NativeStatPill())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .sheet(item: $detail) { selected in
            NavigationStack {
                List {
                    switch selected {
                    case .activity:
                        if let stats {
                            LabeledContent("轮 / 步", value: "\(stats.turns) / \(stats.steps)")
                            if stats.llmMs > 0 { LabeledContent("模型用时", value: nativeDuration(stats.llmMs)) }
                            if stats.toolMs > 0 { LabeledContent("工具调用用时", value: nativeDuration(stats.toolMs)) }
                            if stats.ttftSteps > 0 { LabeledContent("首 token 平均（TTFT）", value: nativeDuration(stats.ttftMs / Double(stats.ttftSteps))) }
                            if let speed = stats.tokensPerSecond { LabeledContent("输出速度（TPS）", value: "\(Int(speed.rounded())) tok/s") }
                        }
                    case .usage:
                        if let usage {
                            if let hit = nativePercent(usage.cacheHitPercent) { LabeledContent("缓存命中", value: "\(hit)%") }
                            LabeledContent("未缓存输入", value: "\(usage.uncachedInputTokens) tok")
                            LabeledContent("缓存读取", value: "\(usage.cacheReadTokens) tok")
                            if usage.cacheWriteTokens > 0 { LabeledContent("缓存写入", value: "\(usage.cacheWriteTokens) tok") }
                            LabeledContent("输出", value: "\(usage.outputTokens) tok")
                            LabeledContent("合计", value: "\(usage.totalTokens) tok")
                        }
                    case .context:
                        if let pressure, let used = pressure.usedTokens {
                            LabeledContent("上下文已用", value: "\(pressure.percent ?? 0)%")
                            LabeledContent("估算用量 / 容量", value: "~\(nativeCompactTokens(used)) / \(nativeCompactTokens(pressure.contextWindow))")
                        }
                        if let breakdown {
                            LabeledContent("系统提示", value: "~\(nativeCompactTokens(breakdown.systemTokens))")
                            LabeledContent("工具", value: "~\(nativeCompactTokens(breakdown.toolsTokens))")
                            LabeledContent("对话", value: "~\(nativeCompactTokens(breakdown.messageTokens))")
                        }
                    }
                }
                .navigationTitle(selected == .activity ? "会话统计" : selected == .usage ? "Token 用量" : "上下文")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { detail = nil } } }
            }
            .presentationDetents([.medium])
        }
    }
}

private struct NativeStatPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(NativeChatTheme.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
    }
}

private struct NativeContextRing: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle().stroke(NativeChatTheme.border, lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(NativeChatTheme.caption, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}
