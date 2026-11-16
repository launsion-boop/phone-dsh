// SPDX-License-Identifier: MIT

// BotFeedbackBar: the inline feedback interaction for one durable artifact.
// Three choices, one pending state, one "已记录 · 撤销" receipt. It never
// blocks the composer, never starts a model turn and never touches approvals.

import SwiftUI
import PhoneDSHBot

struct BotFeedbackBar: View {
    let artifact: BotFeedbackArtifact
    let state: BotFeedbackState
    var onFeedback: (BotFeedbackVerdict, BotFeedbackScope) -> Void
    @Environment(\.botCardTheme) private var theme
    @State private var confirmingSuppress = false

    private var display: BotFeedbackDisplay { state.display(for: artifact.rowID) }

    var body: some View {
        Group {
            switch display {
            case .none:
                choices
            case .pending:
                receiptLine(text: "正在记录…", icon: nil, showsSpinner: true)
            case .recorded(let verdict):
                receiptLine(text: "已记录：\(verdict.label)", icon: "checkmark.circle", showsSpinner: false,
                            undo: true)
            case .undone:
                receiptLine(text: "已撤销反馈", icon: "arrow.uturn.backward", showsSpinner: false)
            }
        }
        .accessibilityIdentifier("bot.feedback.bar")
        .confirmationDialog("不再提醒这一类？", isPresented: $confirmingSuppress,
                            titleVisibility: .visible) {
            Button("只这一条") { onFeedback(.suppress, .artifact) }
                .accessibilityIdentifier("bot.feedback.suppress.artifact")
            if artifact.suppressScopes.contains(.routineClass) {
                Button("这个例行任务的结果") { onFeedback(.suppress, .routineClass) }
                    .accessibilityIdentifier("bot.feedback.suppress.routineClass")
            }
            if artifact.suppressScopes.contains(.user) {
                Button("所有 Bot 的这类") { onFeedback(.suppress, .user) }
                    .accessibilityIdentifier("bot.feedback.suppress.user")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择范围。这个例行任务只影响同一 routine 的后续结果；跨 Bot 只适用于可共享的类别。")
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(artifact.verdicts.filter { !$0.isUndo }, id: \.self) { verdict in
                    Button {
                        // Suppression without a scope would silently mean
                        // "this one row". The label promises a class, so the
                        // person explicitly chooses artifact vs user scope.
                        if verdict == .suppress {
                            confirmingSuppress = true
                        } else {
                            onFeedback(verdict, .artifact)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: verdict.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(verdict.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(HomeSpec.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnavailable(verdict))
                    .opacity(isUnavailable(verdict) ? 0.4 : 1)
                    .accessibilityIdentifier("bot.feedback.\(verdict.rawValue)")
                }
                Spacer(minLength: 0)
            }
            if let failure = state.failure(for: artifact.rowID), !failure.isEmpty {
                Text(friendlyFailure(failure))
                    .font(.system(size: 12))
                    .foregroundStyle(NativeParityTokens.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bot.feedback.failure")
            }
        }
        .frame(minHeight: 36)
    }

    private func receiptLine(text: String, icon: String?, showsSpinner: Bool,
                             undo: Bool = false) -> some View {
        HStack(spacing: 6) {
            if showsSpinner {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if undo, state.canUndo(for: artifact.rowID) {
                Button("撤销") {
                    onFeedback(.undo, .artifact)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(minWidth: 44, minHeight: 32)
                .buttonStyle(.plain)
                .accessibilityIdentifier("bot.feedback.undo")
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.feedback.receipt")
    }

    private func isUnavailable(_ verdict: BotFeedbackVerdict) -> Bool {
        switch state.availability(for: artifact, verdict: verdict) {
        case .available, .pending, .recorded: return false
        case .unavailable: return true
        }
    }

    private func friendlyFailure(_ reason: String) -> String {
        switch reason {
        case "artifact_not_found", "unknown_artifact":
            return "这条内容已经不可反馈。"
        case "artifact_not_durable", "local_row":
            return "这条内容还没有写入记录，暂时不能反馈。"
        case "duplicate_feedback":
            return "已经记录过同样的反馈。"
        case "undo_target_missing", "feedback_not_found":
            return "找不到可撤销的反馈。"
        default:
            return "反馈没有记录成功，请重试。"
        }
    }
}

/// A compact "查看来源" affordance for a card/sheet footer. The page can also
/// keep its context-menu entry; both open the same `BotSourceInspectorSheet`.
struct BotSourceLinkButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11))
                Text("查看来源")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(HomeSpec.textSecondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bot.source.entry")
    }
}
