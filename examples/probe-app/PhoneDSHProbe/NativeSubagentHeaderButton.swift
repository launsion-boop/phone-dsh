// SPDX-License-Identifier: MIT
//
// WS-E — session-header subagent catalog trigger.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:690-712
//   packages/client/ui-subagent/src/client/SubagentHeaderLineage.module.css:9-70
// 402pt values: min-height 28, padding 3×2, radius 8, gap 4, text 12/18,
// optional 14pt running spinner, 12pt chevron (rotates 180° while open).
// The trigger hides itself at count 0: the official catalog action is only
// visible once the projection proves children exist.

import SwiftUI

struct NativeSubagentHeaderButton: View {
    let count: Int
    var runningCount: Int
    var isExpanded: Bool
    var maxWidth: CGFloat?
    var action: () -> Void

    init(count: Int,
         runningCount: Int = 0,
         isExpanded: Bool = false,
         maxWidth: CGFloat? = nil,
         action: @escaping () -> Void) {
        self.count = count
        self.runningCount = runningCount
        self.isExpanded = isExpanded
        self.maxWidth = maxWidth
        self.action = action
    }

    /// `false` at count 0; callers can use it to reclaim header space.
    static func isVisible(count: Int) -> Bool { count > 0 }

    /// VoiceOver copy: the total leads, a running catalog names the subset.
    static func accessibilityLabel(count: Int, runningCount: Int) -> String {
        if runningCount > 0 {
            return "\(count) 个子智能体，\(runningCount) 个正在运行"
        }
        return "\(count) 个子智能体"
    }

    @ViewBuilder
    var body: some View {
        if Self.isVisible(count: count) {
            Button(action: action) {
                HStack(spacing: 4) {
                    if runningCount > 0 {
                        NativeSubagentActivitySpinner(size: 14)
                    }
                    Text("\(count) 个子智能体")
                        .font(.system(size: 12))
                        .frame(height: 18)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.12), value: isExpanded)
                }
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
                .frame(minHeight: 28)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Self.accessibilityLabel(count: count, runningCount: runningCount)))
        }
    }
}

/// The 14pt form of the official `StateDot state="ongoing"` spinner: a 25%
/// opacity full ring behind a rotating arc on one 1.5s period. The catalog
/// sheet reuses it for every running row, so it lives with the trigger.
struct NativeSubagentActivitySpinner: View {
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(NativeParityTokens.labelTertiary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(NativeParityTokens.labelTertiary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { startIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in startIfNeeded() }
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(1, size * 2 / 24) }

    private func startIfNeeded() {
        guard !reduceMotion, !spinning else { return }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            spinning = true
        }
    }
}

#if DEBUG
#Preview("子智能体按钮 · 空/单/多/运行中") {
    VStack(alignment: .leading, spacing: 20) {
        NativeSubagentHeaderButton(count: 0) {}
        NativeSubagentHeaderButton(count: 1) {}
        NativeSubagentHeaderButton(count: 8) {}
        NativeSubagentHeaderButton(count: 8, runningCount: 3) {}
        NativeSubagentHeaderButton(count: 8, runningCount: 3, isExpanded: true) {}
    }
    .padding(24)
}

#Preview("子智能体按钮 · 深色") {
    NativeSubagentHeaderButton(count: 8, runningCount: 3) {}
        .padding(24)
        .preferredColorScheme(.dark)
}
#endif
