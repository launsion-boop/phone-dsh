// SPDX-License-Identifier: MIT
//
// NativeQuestionReplyBubble — the official `QuestionReplyView` late-reply
// bubble: right aligned, 72% max width, 10x16 padding, radius 20, #EDF3FE,
// label 13/18 secondary, summary 14/22, expandable question details, and a
// 28x28 copy action. Values come from
// docs/receipts/ios-session-audit/03-questions.md (A11) and NativeParityTokens.
//
// The bubble is presentation only: the owner parses
// `user/message.source.kind == "user-question-reply"` into NativeQuestionReply
// and wires `onCopy` to UIPasteboard (the module boundary keeps this file on
// SwiftUI + Foundation + NativeParityTokens).

import SwiftUI
import Foundation

// MARK: - Local reply data

struct NativeQuestionReplyOption: Identifiable, Equatable {
    var label: String
    var description: String?
    var id: String { label }
}

/// One asked question as echoed in the steer payload.
struct NativeQuestionReplyQuestion: Identifiable, Equatable {
    let id: String
    var question: String
    var header: String?
    var detail: String?
    var options: [NativeQuestionReplyOption] = []
}

/// One structured answer as echoed in the steer payload.
struct NativeQuestionReplyAnswer: Equatable {
    let id: String
    var selected: [String]
    var custom: String?
}

struct NativeQuestionReply: Identifiable, Equatable {
    let id: String
    var callID: String
    var time: Date
    var questions: [NativeQuestionReplyQuestion]
    var answers: [NativeQuestionReplyAnswer]
    /// Model-facing text, shown when the payload is unreadable.
    var fallbackText: String

    /// Selected labels followed by a non-blank custom answer; empty = skipped.
    func values(for questionID: String) -> [String] {
        let answer = answers.first { $0.id == questionID }
        let custom = answer?.custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (answer?.selected ?? []) + (custom.isEmpty ? [] : [custom])
    }

    /// Collapsed summary: answers comma-joined across every question.
    var summary: String {
        let joined = questions.flatMap { values(for: $0.id) }
        return joined.isEmpty ? NativeQuestionReplyCopy.skipped : joined.joined(separator: ", ")
    }

    /// Clipboard text in the open bubble's layout (`question — answer` blocks).
    var clipboardText: String {
        guard !questions.isEmpty else { return fallbackText }
        return questions.map { question in
            let heading: String
            if let header = question.header, !header.isEmpty, header != question.question {
                heading = "\(header) — \(question.question)"
            } else {
                heading = question.question
            }
            let values = values(for: question.id)
            let answer = values.isEmpty
                ? NativeQuestionReplyCopy.skipped
                : "\(NativeQuestionReplyCopy.answerLabel)\(values.joined(separator: ", "))"
            return "\(heading)\n\(answer)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Copy (official zh, verbatim)

enum NativeQuestionReplyCopy {
    static let label = "回答先前等待中的问题"
    static let open = "展开问题详情"
    static let close = "收起问题详情"
    static let answerLabel = "回答："
    static let skipped = "已跳过"
    static let copy = "复制"
    static let copied = "复制成功"
}

// MARK: - Bubble

struct NativeQuestionReplyBubble: View {
    let reply: NativeQuestionReply
    var onCopy: ((String) -> Void)?

    @State private var expanded: Bool
    @State private var copied = false
    @State private var containerWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(reply: NativeQuestionReply, initiallyExpanded: Bool = false,
         onCopy: ((String) -> Void)? = nil) {
        self.reply = reply
        self.onCopy = onCopy
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var bubbleMaxWidth: CGFloat {
        // `max-width: 72%` of the transcript row; the 338pt column is the
        // fallback until the background measurement lands.
        max(1, (containerWidth > 0 ? containerWidth : NativeParityTokens.contentWidth) * 0.72)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubble
            actions
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: NativeQuestionReplyWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(NativeQuestionReplyWidthKey.self) { width in
            if abs(width - containerWidth) > 0.5 { containerWidth = width }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NativeQuestionReplyCopy.label)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NativeParityTokens.labelSecondary)
                            .frame(width: 12, height: 12)
                        Text(NativeQuestionReplyCopy.label)
                            .font(.system(size: 13))
                            .lineSpacing(nativeReplySpacing(13, 18))
                            .foregroundStyle(NativeParityTokens.labelSecondary)
                    }
                    if !expanded {
                        Text(reply.summary)
                            .font(.system(size: 14))
                            .lineSpacing(nativeReplySpacing(14, 22))
                            .foregroundStyle(NativeParityTokens.labelPrimary)
                            .padding(.top, 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(NativeQuestionReplyCopy.label) · "
                                + (expanded ? NativeQuestionReplyCopy.close : NativeQuestionReplyCopy.open))
            .accessibilityValue(expanded ? "已展开" : "已折叠")

            if expanded { details }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
        .background(NativeParityTokens.bubble,
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(NativeParityTokens.labelSecondary.opacity(0.24))
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                if reply.questions.isEmpty {
                    Text(reply.fallbackText)
                        .font(.system(size: 14))
                        .lineSpacing(nativeReplySpacing(14, 22))
                        .foregroundStyle(NativeParityTokens.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(reply.questions) { question in
                        questionDetails(question)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private func questionDetails(_ question: NativeQuestionReplyQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let header = question.header, !header.isEmpty, header != question.question {
                Text(header)
                    .font(.system(size: 11))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(question.question)
                .font(.system(size: 12))
                .foregroundStyle(NativeParityTokens.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(question.options) { option in
                        Text("• \(option.label)\(option.description.map { " — \($0)" } ?? "")")
                            .font(.system(size: 11))
                            .foregroundStyle(NativeParityTokens.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 16)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(NativeQuestionReplyCopy.answerLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                let values = reply.values(for: question.id)
                Text(values.isEmpty ? NativeQuestionReplyCopy.skipped : values.joined(separator: ", "))
                    .font(.system(size: 14))
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Text(reply.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 13))
                .lineSpacing(nativeReplySpacing(13, 24))
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .padding(.trailing, 4)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(NativeParityTokens.labelTertiary)
            .opacity(onCopy == nil ? 0.4 : 1)
            .disabled(onCopy == nil)
            .accessibilityLabel(copied ? NativeQuestionReplyCopy.copied : NativeQuestionReplyCopy.copy)
        }
        .frame(height: 28)
        .padding(.trailing, 4)
    }

    private func copy() {
        guard let onCopy else { return }
        onCopy(reply.clipboardText)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            copied = false
        }
    }
}

private struct NativeQuestionReplyWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private func nativeReplySpacing(_ size: CGFloat, _ lineHeight: CGFloat) -> CGFloat {
    max(0, lineHeight - size * 1.193)
}

// MARK: - Previews

#if DEBUG
private let nativeQuestionReplyPreview = NativeQuestionReply(
    id: "reply-1",
    callID: "call_00_Preview",
    time: Date(timeIntervalSince1970: 1_782_000_000),
    questions: [
        NativeQuestionReplyQuestion(
            id: "color",
            question: "你更喜欢哪种颜色？",
            header: "选择一个",
            detail: nil,
            options: [
                NativeQuestionReplyOption(label: "蓝色", description: "冷色、退后，适合长时间阅读。"),
                NativeQuestionReplyOption(label: "绿色", description: "中频色，感知亮度最高。"),
            ]),
        NativeQuestionReplyQuestion(id: "deadline", question: "什么时候要？", header: "排期"),
    ],
    answers: [
        NativeQuestionReplyAnswer(id: "color", selected: ["绿色"], custom: "回答晚于超时"),
        NativeQuestionReplyAnswer(id: "deadline", selected: [], custom: nil),
    ],
    fallbackText: "")

#Preview("迟到回答 · 收起") {
    NativeQuestionReplyBubble(reply: nativeQuestionReplyPreview, onCopy: { _ in })
        .padding(.horizontal, NativeParityTokens.transcriptSide)
        .padding(.vertical, 24)
        .frame(width: 402, alignment: .trailing)
        .background(NativeParityTokens.surface)
}

#Preview("迟到回答 · 展开") {
    NativeQuestionReplyBubble(reply: nativeQuestionReplyPreview, initiallyExpanded: true, onCopy: { _ in })
        .padding(.horizontal, NativeParityTokens.transcriptSide)
        .padding(.vertical, 24)
        .frame(width: 402, alignment: .trailing)
        .background(NativeParityTokens.surface)
}
#endif
