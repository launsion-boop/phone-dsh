// SPDX-License-Identifier: MIT
//
// NativeQuestionComposer — the official `QuestionComposer` composer takeover
// (338pt card, radius 20, `min(60vh, 520)` cap) for the native session page.
// Geometry/copy follow the 402pt baseline in
// docs/receipts/ios-session-audit/03-questions.md and NativeParityTokens.
//
// The view owns presentation + draft state only: submit, discard, wait claims
// and draft persistence stay with the ChatPage/ChatModel question carrier.

import SwiftUI
import Foundation

// MARK: - Local question data

/// One selectable answer. `label` is the wire value and keeps a trailing
/// recommendation suffix; only the display label is stripped.
struct NativeQuestionOption: Identifiable, Equatable {
    var label: String
    var description: String?
    var id: String { label }
}

/// The official suffix split (`/\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$/i`).
enum NativeQuestionRecommendedLabel {
    private static let suffix = try? NSRegularExpression(
        pattern: #"\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$"#, options: [.caseInsensitive])

    static func parse(_ raw: String) -> (label: String, isRecommended: Bool) {
        let full = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let suffix, let match = suffix.firstMatch(in: raw, range: full),
              let range = Range(match.range, in: raw) else { return (raw, false) }
        return (raw.replacingCharacters(in: range, with: ""), true)
    }
}

struct NativeQuestionItem: Identifiable, Equatable {
    let id: String
    var header: String?
    var question: String
    var detail: String?
    var options: [NativeQuestionOption] = []
    var multiSelect = false

    var hasOptions: Bool { !options.isEmpty }

    /// Only a marked first option is an implicit draft.
    var recommendedOptionLabel: String? {
        guard let first = options.first,
              NativeQuestionRecommendedLabel.parse(first.label).isRecommended else { return nil }
        return first.label
    }
}

/// One question's editable draft; mirrors the official `QuestionDraftAnswer`.
struct NativeQuestionDraft: Equatable, Codable {
    var selected: [String] = []
    var custom: String = ""
    var skipped: Bool = false

    var isAnswered: Bool {
        !selected.isEmpty || !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isCompleted: Bool { isAnswered || skipped }
}

/// One wire answer (`{id, selected, custom?}`). A skipped question carries
/// neither a selection nor custom text, matching `{ id, selected: [] }`.
struct NativeQuestionAnswerItem: Equatable {
    let id: String
    let selected: [String]
    var custom: String?
    var skipped = false

    init(id: String, selected: [String], custom: String? = nil, skipped: Bool = false) {
        self.id = id
        self.selected = selected
        self.custom = custom
        self.skipped = skipped
    }
}

struct NativeQuestionAnswerBatch: Equatable {
    var answers: [NativeQuestionAnswerItem]
}

/// A recorded answer supplied to the read-only review panel.
struct NativeQuestionReviewAnswer: Equatable {
    let id: String
    var selected: [String]
    var custom: String?
}

/// Restored page + drafts (official `dsh.user-questions.drafts.v1`).
struct NativeQuestionProgress: Equatable, Codable {
    var index: Int
    var drafts: [NativeQuestionDraft]
}

enum NativeQuestionWaitState: Equatable {
    case counting, focused, editing, waiting, continued
}

/// Wait state owned by the carrier. `timed == false` is the shipped blocking
/// question, which never shows a wait status.
struct NativeQuestionWait: Equatable {
    var state: NativeQuestionWaitState
    var timed = false
    var remainingSeconds = 0
}

/// `discard` sends `ASK_CANCELLED` (blocking waterfall request); `hide` only
/// leaves the seat (a call-keyed panel reopens from the tool row).
enum NativeQuestionDismissal: Equatable {
    case discard, hide
}

// MARK: - Copy (official zh, verbatim)

enum NativeQuestionCopy {
    static let incomplete = "请先完成这道问题。"
    static let unanswered = "请选择一个选项或填写自定义答案。"
    static let unavailable = "当前无法提交，请稍候再试。"
    static let takeTime = "慢慢回答"
    static let held = "会一直等你回答"
    static let continued = "已继续工作，仍可回答"
    static let reviewStatus = "已回答"
    static let reviewSkipped = "这道问题当时被跳过。"
    static let prev = "上一题"
    static let next = "下一题"
    static let minimize = "收起问题卡片"
    static let maximize = "展开问题卡片"
    static let cancel = "放弃整组问题"
    static let close = "收起问题面板，可从工具调用重新打开"
    static let recommended = "推荐"
    static let placeholder = "输入你的答案"
    static let skip = "跳过"
    static let submit = "提交"
    static let submitting = "正在提交…"

    static func countdown(_ seconds: Int) -> String { "\(seconds) 秒后继续工作" }
    static func paused(_ seconds: Int) -> String { "已暂停 · 剩余 \(seconds) 秒" }
}

// MARK: - Composer

struct NativeQuestionComposer: View {
    let questions: [NativeQuestionItem]
    let requestKey: String
    let reviewAnswers: [NativeQuestionReviewAnswer]?
    let wait: NativeQuestionWait?
    let isSubmitting: Bool
    let submissionError: String?
    let channelAvailable: Bool
    let viewportHeight: CGFloat
    let dismissal: NativeQuestionDismissal
    let showsFooterDiscard: Bool
    let onSubmit: (NativeQuestionAnswerBatch) -> Void
    let onDiscard: (() -> Void)?
    let onClose: (() -> Void)?
    let onTakeTime: (() -> Void)?
    let onEngage: (() -> Void)?
    let onMinimizeChange: ((Bool) -> Void)?

    @State private var index: Int
    @State private var drafts: [NativeQuestionDraft]
    @State private var minimized: Bool
    @State private var validationError: String?
    @FocusState private var customFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(questions: [NativeQuestionItem], requestKey: String = "",
         reviewAnswers: [NativeQuestionReviewAnswer]? = nil, wait: NativeQuestionWait? = nil,
         isSubmitting: Bool = false, submissionError: String? = nil, channelAvailable: Bool = true,
         initiallyMinimized: Bool = false, initialProgress: NativeQuestionProgress? = nil,
         viewportHeight: CGFloat = 874,
         dismissal: NativeQuestionDismissal = .discard, showsFooterDiscard: Bool = false,
         onSubmit: @escaping (NativeQuestionAnswerBatch) -> Void = { _ in },
         onDiscard: (() -> Void)? = nil, onClose: (() -> Void)? = nil,
         onTakeTime: (() -> Void)? = nil, onEngage: (() -> Void)? = nil,
         onMinimizeChange: ((Bool) -> Void)? = nil) {
        self.questions = questions
        self.requestKey = requestKey
        self.reviewAnswers = reviewAnswers
        self.wait = wait
        self.isSubmitting = isSubmitting
        self.submissionError = submissionError
        self.channelAvailable = channelAvailable
        self.viewportHeight = viewportHeight
        self.dismissal = dismissal
        self.showsFooterDiscard = showsFooterDiscard
        self.onSubmit = onSubmit
        self.onDiscard = onDiscard
        self.onClose = onClose
        self.onTakeTime = onTakeTime
        self.onEngage = onEngage
        self.onMinimizeChange = onMinimizeChange
        let prepared = Self.prepare(questions: questions, review: reviewAnswers, progress: initialProgress)
        _index = State(initialValue: prepared.index)
        _drafts = State(initialValue: prepared.drafts)
        _minimized = State(initialValue: initiallyMinimized)
    }

    // MARK: State

    private var isReview: Bool { reviewAnswers != nil }
    private var isLocked: Bool { isSubmitting || isReview }
    private var effectiveDismissal: NativeQuestionDismissal { isReview ? .hide : dismissal }
    private var currentQuestion: NativeQuestionItem? {
        questions.indices.contains(index) ? questions[index] : nil
    }
    private var currentDraft: NativeQuestionDraft {
        drafts.indices.contains(index) ? drafts[index] : NativeQuestionDraft()
    }
    private var feedback: String? { submissionError ?? validationError }
    private var maxCardHeight: CGFloat {
        min(max(viewportHeight, 0) * 0.6, NativeParityTokens.questionMaxHeight)
    }
    private var isLastQuestion: Bool { index >= questions.count - 1 }
    private var submitTitle: String {
        if isSubmitting { return NativeQuestionCopy.submitting }
        return isLastQuestion ? NativeQuestionCopy.submit : NativeQuestionCopy.next
    }
    private var submitDisabled: Bool {
        isSubmitting || !currentDraft.isAnswered || (isLastQuestion && !channelAvailable)
    }

    private static func prepare(questions: [NativeQuestionItem],
                                review: [NativeQuestionReviewAnswer]?,
                                progress: NativeQuestionProgress?) -> (index: Int, drafts: [NativeQuestionDraft]) {
        var built: [NativeQuestionDraft]
        if let review {
            var byID: [String: NativeQuestionReviewAnswer] = [:]
            for answer in review { byID[answer.id] = answer }
            built = questions.map { question in
                guard let answer = byID[question.id] else { return NativeQuestionDraft() }
                let custom = answer.custom ?? ""
                return NativeQuestionDraft(
                    selected: answer.selected, custom: custom,
                    skipped: answer.selected.isEmpty
                        && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else if let progress, progress.drafts.count == questions.count {
            built = progress.drafts
        } else {
            built = questions.map {
                NativeQuestionDraft(selected: $0.recommendedOptionLabel.map { [$0] } ?? [])
            }
        }
        var start = 0
        if let progress, questions.indices.contains(progress.index) { start = progress.index }
        return (start, built)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            if !minimized {
                ViewThatFits(in: .vertical) {
                    answerBody
                    ScrollView { answerBody }
                }
                .frame(maxWidth: .infinity)
                footer
            }
        }
        .padding(.bottom, 10)
        .frame(width: NativeParityTokens.contentWidth)
        .frame(maxHeight: maxCardHeight, alignment: .top)
        // The composer seat proposes the full screen height; without this the
        // maxHeight frame expands to 520 and centers a short card in it.
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous)
            .fill(NativeParityTokens.surface))
        .clipShape(RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL2, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.031), radius: 8, x: 0, y: 3)
        .shadow(color: .black.opacity(0.02), radius: 16, x: 0, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(currentQuestion?.question ?? "问题")
        .onChange(of: customFocused) { _, focused in if focused { onEngage?() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow = currentQuestion?.header, !eyebrow.isEmpty {
                    Text(eyebrow).font(.system(size: 11))
                        .lineSpacing(sp(11, 16))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(currentQuestion?.question ?? "问题")
                    .font(.system(size: 16, weight: .medium))
                    .lineSpacing(sp(16, 22))
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            headerActions
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: minimized ? 14 : 0, trailing: 16))
    }

    private var headerActions: some View {
        HStack(alignment: .center, spacing: 4) {
            if let status = waitStatusText {
                Text(status).font(.system(size: 12)).lineSpacing(sp(12, 24))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(status)
            }
            if waitShowsTakeTime {
                NativeQuestionActionButton(title: NativeQuestionCopy.takeTime,
                                           enabled: !isSubmitting) { onTakeTime?() }
            }
            NativeQuestionIconButton(systemName: minimized ? "chevron.up" : "chevron.down",
                                     label: minimized ? NativeQuestionCopy.maximize : NativeQuestionCopy.minimize,
                                     enabled: !isSubmitting) { toggleMinimized() }
            NativeQuestionIconButton(systemName: "xmark",
                                     label: effectiveDismissal == .discard
                                        ? NativeQuestionCopy.cancel : NativeQuestionCopy.close,
                                     enabled: !isSubmitting) { close() }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var waitStatusText: String? {
        if isReview { return NativeQuestionCopy.reviewStatus }
        guard let wait else { return nil }
        switch wait.state {
        case .continued: return NativeQuestionCopy.continued
        case .counting: return wait.timed ? NativeQuestionCopy.countdown(wait.remainingSeconds) : nil
        case .focused: return wait.timed ? NativeQuestionCopy.paused(wait.remainingSeconds) : nil
        case .waiting, .editing: return wait.timed ? NativeQuestionCopy.held : nil
        }
    }

    private var waitShowsTakeTime: Bool {
        guard !isReview, let wait, wait.timed else { return false }
        return wait.state == .counting || wait.state == .focused
    }

    @ViewBuilder
    private var answerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = currentQuestion?.detail, !detail.isEmpty {
                Text(nativeQuestionMarkdown(detail)).font(.system(size: 14))
                    .lineSpacing(NativeParityTokens.bodyLineSpacing)
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2).padding(.top, 8).padding(.bottom, 8)
            }
            if let question = currentQuestion {
                if question.hasOptions {
                    optionList(question)
                } else if !isReview || !currentDraft.custom.isEmpty {
                    answerField(placeholder: NativeQuestionCopy.placeholder)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .frame(minHeight: 64, alignment: .topLeading)
                        .background(NativeParityTokens.selector, in: RoundedRectangle(
                            cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
                                .strokeBorder(customFocused ? NativeParityTokens.accent
                                              : NativeParityTokens.borderL4, lineWidth: 0.5)
                        }
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                }
                if isReview, currentDraft.skipped {
                    Text(NativeQuestionCopy.reviewSkipped).font(.system(size: 14))
                        .lineSpacing(NativeParityTokens.bodyLineSpacing)
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionList(_ question: NativeQuestionItem) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { position, option in
                optionRow(option, number: position + 1, multiSelect: question.multiSelect)
            }
            if !isReview || !currentDraft.custom.isEmpty {
                customInlineRow(multiSelect: question.multiSelect)
            }
        }
        .padding(.top, 12).padding(.horizontal, 8).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func optionRow(_ option: NativeQuestionOption, number: Int, multiSelect: Bool) -> some View {
        let display = NativeQuestionRecommendedLabel.parse(option.label)
        let selected = currentDraft.selected.contains(option.label)
        // Official paints the row for a selected single choice only; a
        // multi-select row shows its state through the checkbox.
        let highlighted = selected && !multiSelect
        return Button {
            choose(option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if multiSelect {
                    NativeQuestionCheckbox(checked: selected)
                } else {
                    NativeQuestionNumberChip(number: number)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(display.label).font(.system(size: 14, weight: .medium))
                            .lineSpacing(NativeParityTokens.bodyLineSpacing)
                            .foregroundStyle(NativeParityTokens.labelPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if display.isRecommended { NativeQuestionRecommendedBadge() }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 14))
                            .lineSpacing(NativeParityTokens.bodyLineSpacing)
                            .foregroundStyle(NativeParityTokens.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
            .frame(minHeight: NativeParityTokens.questionOptionMinHeight, alignment: .leading)
            .background(highlighted ? NativeQuestionPalette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous)
                    .strokeBorder(highlighted ? NativeParityTokens.borderL2 : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isLocked)
        .accessibilityLabel(display.isRecommended
                            ? "\(display.label)，\(NativeQuestionCopy.recommended)" : display.label)
        .accessibilityHint(option.description ?? "")
        .accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }

    private func customInlineRow(multiSelect: Bool) -> some View {
        let yielded = !multiSelect && !currentDraft.selected.isEmpty
        let active = !yielded && (customFocused || !currentDraft.custom.isEmpty)
        return HStack(alignment: .top, spacing: 8) {
            if multiSelect {
                NativeQuestionCheckbox(checked: !currentDraft.custom.isEmpty)
            } else {
                NativeQuestionEditChip()
            }
            answerField(placeholder: NativeQuestionCopy.placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(minHeight: NativeParityTokens.questionOptionMinHeight, alignment: .leading)
        .background(active ? NativeQuestionPalette.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous)
                .strokeBorder(active ? NativeParityTokens.borderL2 : Color.clear, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
    }

    private func answerField(placeholder: String) -> some View {
        TextField("", text: customText,
                  prompt: Text(placeholder).foregroundColor(NativeParityTokens.labelCaption),
                  axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 16))
            .lineSpacing(sp(16, 24))
            .foregroundStyle(NativeParityTokens.labelPrimary)
            .lineLimit(1...6)
            .focused($customFocused).disabled(isLocked)
            .accessibilityLabel(placeholder)
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            pager
            Text(feedback ?? "").font(.system(size: 11))
                .lineSpacing(sp(11, 16))
                .foregroundStyle(NativeParityTokens.error)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .bottomTrailing)
                .accessibilityLabel(feedback.map { "错误：\($0)" } ?? "")
                .accessibilityHidden(feedback == nil)
            if !isReview {
                HStack(spacing: 12) {
                    if showsFooterDiscard, effectiveDismissal == .discard {
                        NativeQuestionActionButton(title: NativeQuestionCopy.cancel,
                                                   enabled: !isSubmitting) { close() }
                    }
                    NativeQuestionActionButton(title: NativeQuestionCopy.skip,
                                               enabled: !isSubmitting) { skipCurrent() }
                    NativeQuestionActionButton(title: submitTitle, style: .primary,
                                               enabled: !submitDisabled) { continueFlow() }
                }
                .fixedSize()
            }
        }
        .padding(.top, 12).padding(.horizontal, 10)
    }

    private var pager: some View {
        HStack(spacing: 6) {
            NativeQuestionIconButton(systemName: "chevron.left", label: NativeQuestionCopy.prev,
                                     enabled: index > 0 && !isSubmitting) { goTo(index - 1) }
            Text("\(index + 1) / \(questions.count)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NativeParityTokens.labelSecondary)
                .padding(.horizontal, 4).fixedSize()
                .accessibilityLabel("第 \(index + 1) 题，共 \(questions.count) 题")
            NativeQuestionIconButton(systemName: "chevron.right", label: NativeQuestionCopy.next,
                                     enabled: !isLastQuestion && !isSubmitting) { goTo(index + 1) }
        }
        .fixedSize()
    }

    // MARK: Actions

    private var customText: Binding<String> {
        Binding(
            get: { currentDraft.custom },
            set: { newValue in
                guard drafts.indices.contains(index) else { return }
                drafts[index].custom = newValue
                if currentQuestion?.multiSelect != true { drafts[index].selected = [] }
                drafts[index].skipped = false
                validationError = nil
                onEngage?()
            })
    }

    private func choose(_ option: NativeQuestionOption) {
        guard !isLocked, drafts.indices.contains(index), let question = currentQuestion else { return }
        onEngage?()
        validationError = nil
        let page = index
        drafts[page].skipped = false
        if question.multiSelect {
            if let position = drafts[page].selected.firstIndex(of: option.label) {
                drafts[page].selected.remove(at: position)
            } else {
                drafts[page].selected.append(option.label)
            }
            return
        }
        drafts[page].selected = [option.label]
        drafts[page].custom = ""
        guard page < questions.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { index = page + 1 }
    }

    private func goTo(_ next: Int) {
        guard !isSubmitting, questions.indices.contains(next) else { return }
        customFocused = false
        validationError = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { index = next }
    }

    private func skipCurrent() {
        guard !isLocked, drafts.indices.contains(index) else { return }
        onEngage?()
        validationError = nil
        let page = index
        drafts[page] = NativeQuestionDraft(selected: [], custom: "", skipped: true)
        customFocused = false
        if page < questions.count - 1 {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { index = page + 1 }
            return
        }
        submitDrafts()
    }

    private func continueFlow() {
        guard !isLocked else { return }
        guard currentDraft.isAnswered else {
            validationError = NativeQuestionCopy.unanswered
            return
        }
        validationError = nil
        if !isLastQuestion { goTo(index + 1); return }
        submitDrafts()
    }

    private func submitDrafts() {
        guard !isSubmitting else { return }
        if let missing = drafts.firstIndex(where: { !$0.isCompleted }) {
            goTo(missing)
            validationError = NativeQuestionCopy.incomplete
            return
        }
        guard channelAvailable else {
            validationError = NativeQuestionCopy.unavailable
            return
        }
        validationError = nil
        onSubmit(makeBatch())
    }

    private func makeBatch() -> NativeQuestionAnswerBatch {
        NativeQuestionAnswerBatch(answers: questions.enumerated().map { position, question in
            let draft = drafts.indices.contains(position) ? drafts[position] : NativeQuestionDraft()
            if draft.skipped {
                return NativeQuestionAnswerItem(id: question.id, selected: [], skipped: true)
            }
            let custom = draft.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = custom.isEmpty || question.multiSelect ? draft.selected : []
            return NativeQuestionAnswerItem(id: question.id, selected: selected,
                                            custom: custom.isEmpty ? nil : custom)
        })
    }

    private func toggleMinimized() {
        guard !isSubmitting else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { minimized.toggle() }
        onMinimizeChange?(minimized)
    }

    private func close() {
        guard !isSubmitting else { return }
        if effectiveDismissal == .hide { onClose?(); return }
        guard channelAvailable else {
            validationError = NativeQuestionCopy.unavailable
            return
        }
        onDiscard?()
    }
}

// MARK: - Small parts

private enum NativeQuestionPalette {
    /// Official `interactive-bg-hover`: rgba(38,49,72,.06).
    static let hoverFill = NativeParityTokens.rgba(light: 0x263148, lightAlpha: 0.06,
                                                   dark: 0xFFFFFF, darkAlpha: 0.08)
    /// Official `bg-overlay` behind the option number.
    static let overlayFill = NativeParityTokens.color(light: 0xE9ECF2, dark: 0x61666B)
    /// Official `label-primary-foreground` over a primary fill.
    static let primaryInk = NativeParityTokens.color(light: 0xFFFFFF, dark: 0x0F1115)
}

private struct NativeQuestionRecommendedBadge: View {
    var body: some View {
        Text(NativeQuestionCopy.recommended).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(NativeParityTokens.planChipInk)
            .padding(.horizontal, 4).frame(height: 18)
            .background(NativeParityTokens.planChipBG,
                        in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct NativeQuestionNumberChip: View {
    let number: Int

    var body: some View {
        Text("\(number)").font(.system(size: 12, weight: .medium))
            .foregroundStyle(NativeParityTokens.labelSecondary)
            .frame(width: 20, height: 20)
            .background(NativeQuestionPalette.overlayFill,
                        in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style: .continuous))
            .padding(.top, 2)
            .accessibilityHidden(true)
    }
}

private struct NativeQuestionCheckbox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style: .continuous)
                .fill(checked ? NativeParityTokens.labelPrimary : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style: .continuous)
                        .strokeBorder(checked ? NativeParityTokens.labelPrimary : NativeParityTokens.borderL4,
                                      lineWidth: 0.5)
                }
                .frame(width: 14, height: 14)
            if checked {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NativeQuestionPalette.primaryInk)
            }
        }
        .frame(width: 20, height: 20).padding(.top, 2)
        .accessibilityHidden(true)
    }
}

private struct NativeQuestionEditChip: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style: .continuous)
                .fill(NativeQuestionPalette.overlayFill).frame(width: 20, height: 20)
            Image(systemName: "pencil").font(.system(size: 11, weight: .medium))
                .foregroundStyle(NativeParityTokens.labelSecondary)
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

private struct NativeQuestionIconButton: View {
    let systemName: String
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? NativeParityTokens.labelTertiary
                         : NativeParityTokens.labelCaption.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct NativeQuestionActionButton: View {
    enum Style { case outline, primary }

    let title: String
    var style: Style = .outline
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14)).lineLimit(1)
                .foregroundStyle(style == .primary
                                 ? NativeQuestionPalette.primaryInk : NativeParityTokens.labelPrimary)
                .padding(.horizontal, 14).frame(height: 36)
                .background {
                    let shape = RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous)
                    if style == .primary {
                        shape.fill(NativeParityTokens.labelPrimary)
                    } else {
                        shape.strokeBorder(NativeParityTokens.borderL3, lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

private func sp(_ size: CGFloat, _ lineHeight: CGFloat) -> CGFloat {
    // SF Pro's default line height is ~1.193x the point size; the official
    // line-height is the CSS px value at the 402pt baseline.
    max(0, lineHeight - size * 1.193)
}

private func nativeQuestionMarkdown(_ text: String) -> AttributedString {
    if let parsed = try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return parsed
    }
    return AttributedString(text)
}

// MARK: - Previews

#if DEBUG
private enum NativeQuestionPreviewData {
    static let single = [NativeQuestionItem(id: "color", header: "选择一个", question: "你更喜欢哪种颜色？", options: [
        NativeQuestionOption(label: "蓝色（推荐）", description: "冷色、退后，适合长时间阅读。"),
        NativeQuestionOption(label: "绿色", description: "中频色，感知亮度最高，长时间阅读更省力。"),
    ])]

    static let pages = [
        NativeQuestionItem(id: "q1", header: "第一步", question: "先确认目标受众。",
                           options: [.init(label: "开发者"), .init(label: "设计团队")]),
        NativeQuestionItem(id: "q2", header: "第二步", question: "再确认交付形式。",
                           options: [.init(label: "原生 App"), .init(label: "网页")]),
        NativeQuestionItem(id: "q3", header: "第三步", question: "最后确认时间范围。",
                           options: [.init(label: "本周"), .init(label: "本月")]),
    ]
}

private extension View {
    func questionPreviewStage() -> some View {
        padding(.vertical, 24)
            .frame(width: 402, height: 874, alignment: .bottom)
            .background(NativeParityTokens.surface)
    }
}

#Preview("提问 · 单题") {
    NativeQuestionComposer(questions: NativeQuestionPreviewData.single, onSubmit: { _ in })
        .questionPreviewStage()
}

#Preview("提问 · 多题分页") {
    NativeQuestionComposer(
        questions: NativeQuestionPreviewData.pages,
        initialProgress: NativeQuestionProgress(index: 1, drafts: [NativeQuestionDraft(selected: ["开发者"]),
                                                                 NativeQuestionDraft(), NativeQuestionDraft()]),
        onSubmit: { _ in }).questionPreviewStage()
}

#Preview("提问 · 多选与推荐") {
    NativeQuestionComposer(questions: [NativeQuestionItem(
        id: "features", header: "可多选", question: "这次要一起做哪些能力？",
        options: [.init(label: "离线缓存（推荐）", description: "没有网络时也能继续。"),
                  .init(label: "多人协作"), .init(label: "导出")],
        multiSelect: true)], onSubmit: { _ in }).questionPreviewStage()
}

#Preview("提问 · 自定义答案") {
    NativeQuestionComposer(questions: [NativeQuestionItem(id: "free", header: "补充",
                                                         question: "还有什么要补充的吗？")],
                           onSubmit: { _ in }).questionPreviewStage()
}

#Preview("提问 · 提交中与错误") {
    NativeQuestionComposer(questions: NativeQuestionPreviewData.single, isSubmitting: true,
                           submissionError: "回答未送达，工作已继续，请再提交一次。",
                           onSubmit: { _ in }).questionPreviewStage()
}

#Preview("提问 · 倒计时") {
    NativeQuestionComposer(questions: NativeQuestionPreviewData.single,
                           wait: NativeQuestionWait(state: .counting, timed: true, remainingSeconds: 30),
                           onSubmit: { _ in }).questionPreviewStage()
}

#Preview("提问 · 已回答只读") {
    NativeQuestionComposer(questions: NativeQuestionPreviewData.single,
                           reviewAnswers: [NativeQuestionReviewAnswer(id: "color", selected: ["蓝色（推荐）"])],
                           dismissal: .hide, onSubmit: { _ in }).questionPreviewStage()
}
#endif
