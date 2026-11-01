// SPDX-License-Identifier: MIT
//
// NativeAskQuestionCard — the official transcript `AskQuestionCard` body for
// an `ask_user_question` tool row. Answered batches render a question/answer
// definition list; unanswered batches render a verdict plus the question list.
// A `查看回答` pill opens the read-only panel. No raw JSON is ever rendered.
//
// Contract: docs/receipts/ios-session-audit/03-questions.md (A9/A10, Q-01).
// The row chrome (24pt disclosure, `提问` title, `{n}/{m} 已回答` summary) stays
// with NativeToolCallModel/ChatPage; this view is the expanded body only.

import SwiftUI
import Foundation

// MARK: - Local card data

struct NativeAskQuestionAnsweredItem: Identifiable, Equatable {
    let id: String
    var question: String
    var answers: [String]
}

struct NativeAskQuestionUnansweredItem: Identifiable, Equatable {
    let id: String
    var question: String
}

/// The two official card shapes. For `.answered`, one item is one recorded
/// answer entry (a skipped question has `answers == []`); the summary
/// denominator is the answer batch length, never the question count.
enum NativeAskQuestionCardContent: Equatable {
    case answered([NativeAskQuestionAnsweredItem])
    case unanswered(verdict: String, questions: [NativeAskQuestionUnansweredItem])

    var answeredSummary: String? {
        guard case .answered(let items) = self else { return nil }
        let answered = items.filter { !$0.answers.isEmpty }.count
        return NativeAskQuestionCopy.answered(answered, total: items.count)
    }
}

// MARK: - Copy (official zh, verbatim)

/// The four official unanswered verdicts (`ask.pendingDetail` / `closedDetail`
/// / `cancelledDetail` / `interruptedDetail`).
enum NativeAskQuestionVerdict {
    static let pending = "等待中的问题仍可在输入框中回答"
    static let closed = "该问题已结束，结果见下方对话"
    static let cancelled = "本轮已取消，未提交回答"
    static let interrupted = "本轮已中断，未提交回答"
}

enum NativeAskQuestionCopy {
    static let title = "提问"
    static let review = "查看回答"
    static let skipped = "未回答"
    static let waiting = "等待回答"
    static let reopen = "回答"
    static let answeredStatus = "已回答"
    static let closedStatus = "已结束"
    static let cancelledStatus = "已取消"
    static let interruptedStatus = "已中断"

    static func answered(_ answered: Int, total: Int) -> String { "\(answered)/\(total) 已回答" }
}

// MARK: - Card

struct NativeAskQuestionCard: View {
    let content: NativeAskQuestionCardContent
    var skippedLabel = NativeAskQuestionCopy.skipped
    var reviewTitle = NativeAskQuestionCopy.review
    var onReview: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .vertical) {
            column
            ScrollView { column }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 360)
        .background(NativeParityTokens.surface,
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5)
        }
        .padding(.leading, 4)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("问答记录")
    }

    @ViewBuilder
    private var column: some View {
        switch content {
        case .answered(let items):
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in answeredRow(item) }
                reviewAffordance
            }
        case .unanswered(let verdict, let questions):
            VStack(alignment: .leading, spacing: 16) {
                Text(verdict)
                    .font(.system(size: 14))
                    .lineSpacing(NativeParityTokens.bodyLineSpacing)
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(questions) { question in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").font(.system(size: 14))
                            Text(question.question)
                                .font(.system(size: 14))
                                .lineSpacing(NativeParityTokens.bodyLineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                    }
                }
                .padding(.leading, 20)
                reviewAffordance
            }
        }
    }

    private func answeredRow(_ item: NativeAskQuestionAnsweredItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.question)
                .font(.system(size: 14))
                .lineSpacing(NativeParityTokens.bodyLineSpacing)
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if item.answers.isEmpty {
                Text(skippedLabel)
                    .font(.system(size: 14))
                    .lineSpacing(NativeParityTokens.bodyLineSpacing)
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(item.answers.enumerated()), id: \.offset) { _, answer in
                    Text(answer)
                        .font(.system(size: 14))
                        .lineSpacing(NativeParityTokens.bodyLineSpacing)
                        .foregroundStyle(NativeParityTokens.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewAffordance: some View {
        if let onReview {
            HStack {
                Spacer(minLength: 0)
                Button(action: onReview) {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle").font(.system(size: 13))
                        Text(reviewTitle).font(.system(size: 12))
                    }
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(NativeParityTokens.selector, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reviewTitle)
                .accessibilityHint("以只读面板重新打开这组问题")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Previews

#if DEBUG
private let nativeAskQuestionAnsweredPreview = NativeAskQuestionCardContent.answered([
    NativeAskQuestionAnsweredItem(id: "color", question: "你更喜欢哪种颜色？", answers: ["绿色", "回答晚于超时"]),
    NativeAskQuestionAnsweredItem(id: "deadline", question: "什么时候要？", answers: []),
])

private let nativeAskQuestionPendingPreview = NativeAskQuestionCardContent.unanswered(
    verdict: NativeAskQuestionVerdict.pending,
    questions: [
        NativeAskQuestionUnansweredItem(id: "color", question: "你更喜欢哪种颜色？"),
        NativeAskQuestionUnansweredItem(id: "deadline", question: "什么时候要？"),
    ])

#Preview("问答卡 · 已回答") {
    NativeAskQuestionCard(content: nativeAskQuestionAnsweredPreview, onReview: {})
        .frame(width: NativeParityTokens.contentWidth)
        .padding(.vertical, 24)
        .background(NativeParityTokens.surface)
}

#Preview("问答卡 · 等待回答") {
    NativeAskQuestionCard(content: nativeAskQuestionPendingPreview, onReview: {})
        .frame(width: NativeParityTokens.contentWidth)
        .padding(.vertical, 24)
        .background(NativeParityTokens.surface)
}

#Preview("问答卡 · 已取消") {
    NativeAskQuestionCard(content: .unanswered(
        verdict: NativeAskQuestionVerdict.cancelled,
        questions: [NativeAskQuestionUnansweredItem(id: "color", question: "你更喜欢哪种颜色？")]))
        .frame(width: NativeParityTokens.contentWidth)
        .padding(.vertical, 24)
        .background(NativeParityTokens.surface)
}
#endif
