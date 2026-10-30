// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

struct NativeMessageActions: View {
    let text: String
    var timestamp: Date?
    var usage: NativeTurnUsage?
    var onBranch: (() -> Void)? = nil
    var onFeedback: ((Bool) -> Void)? = nil
    @State private var copied = false
    @State private var showUsage = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            } label: {
                NativeChatIcon(name: copied ? .check : .copy, size: 17)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "已复制" : "复制")
            if let onFeedback {
                Button { onFeedback(true) } label: { NativeChatIcon(name: .thumbsUp, size: 17) }
                    .buttonStyle(.plain).accessibilityLabel("有用")
                Button { onFeedback(false) } label: { NativeChatIcon(name: .thumbsDown, size: 17) }
                    .buttonStyle(.plain).accessibilityLabel("没用")
            }
            if let onBranch {
                Button(action: onBranch) { NativeChatIcon(name: .branch, size: 17) }
                    .buttonStyle(.plain).accessibilityLabel("从这里分支")
            }
            if !text.isEmpty {
                ShareLink(item: text) { NativeChatIcon(name: .share, size: 17) }
                    .accessibilityLabel("分享")
            }
            if let usage {
                Button { showUsage = true } label: {
                    HStack(spacing: 6) {
                        NativeChatIcon(name: .database, size: 14)
                        Text("用量 \(nativeCompactTokens(usage.totalTokens)) tok")
                    }
                    .font(NativeChatTheme.captionFont())
                    .foregroundStyle(NativeChatTheme.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            if let timestamp, !text.isEmpty {
                Text(nativeClock(timestamp))
                    .font(NativeChatTheme.captionFont())
                    .foregroundStyle(NativeChatTheme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .foregroundStyle(NativeChatTheme.tertiary)
        .sheet(isPresented: $showUsage) {
            if let usage { NativeTurnUsageDetails(usage: usage) }
        }
    }
}

private struct NativeTurnUsageDetails: View {
    let usage: NativeTurnUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let percent = nativePercent(usage.cacheHitPercent) { LabeledContent("缓存命中", value: "\(percent)%") }
                LabeledContent("未缓存输入", value: "\(usage.uncachedInputTokens) tok")
                if let value = usage.cacheReadTokens { LabeledContent("缓存读取", value: "\(value) tok") }
                if let value = usage.cacheWriteTokens { LabeledContent("缓存写入", value: "\(value) tok") }
                LabeledContent("输出", value: "\(usage.outputTokens) tok")
                if let value = usage.reasoningTokens { LabeledContent("其中推理", value: "\(value) tok") }
                LabeledContent("合计", value: "\(usage.totalTokens) tok")
            }
            .navigationTitle("本轮用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
