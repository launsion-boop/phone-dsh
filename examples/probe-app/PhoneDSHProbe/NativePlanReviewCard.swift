// SPDX-License-Identifier: MIT
// NativePlanReviewCard — the official `PlanReviewPanel` takeover of the composer
// seat while `exit_plan_mode` is blocked on a plan review.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   packages/client/ui-user-questions/src/client/PlanReviewPanel.tsx + .module.css
//   packages/client/ui-plan/src/client/{PlanPreview.module.css,locales.ts}
//   packages/client/ui-user-questions/src/client/locales.ts
//
// Geometry: card 338pt, radius 20, `specific-input-major` fill, panel elevation
// (0.5pt stroke + y3/8 + 0/16 shadows). Warm strip 12/16 with a StateDot and
// 「计划待审」; summary 14/16/12 with a 15/22 w500 single-line title and a 14/24
// two-line secondary description; footer 8/16/12 with a 12pt error slot and two
// 36pt-tall radius-12 buttons (「要求修改」outline + 「同意执行」primary).
//
// Title/summary derivation reuses `NativePlanDocument` from NativePlanCard.swift
// (the shared markdown → plain-text projection) and the busy strip reuses
// `NativeOngoingRing` from NativeTodoDock.swift, so those two files ship with it.

import SwiftUI

/// The plan under review: the request's question plus its plan Markdown
/// (`user-questions/request` `question` + `detail`).
public struct NativePlanReviewData: Equatable {
    /// The ask the official card uses as its region label.
    public var question: String
    /// The complete plan document (`exit_plan_mode` `args.plan`).
    public var markdown: String

    public init(question: String, markdown: String) {
        self.question = question
        self.markdown = markdown
    }

    /// Official `extractMarkdownPlainText(plan, mode: 'first-line')`.
    public var title: String { NativePlanDocument.firstLine(markdown) }

    /// Official first paragraph, hidden when it repeats the title.
    public var summary: String {
        let paragraph = NativePlanDocument.firstParagraph(markdown)
        return paragraph == title ? "" : paragraph
    }
}

/// Composer-seat plan review card: approve, or ask to change the plan.
public struct NativePlanReviewCard: View {
    /// Official `plan.header` / `plan.discuss` / `plan.approve`.
    public static let headerText = "计划待审"
    public static let requestChangesText = "要求修改"
    public static let approveText = "同意执行"
    /// Official `preview.full` and its accessible name (`preview.open`).
    public static let openFullPlanText = "查看全文"
    public static let openFullPlanAccessibilityText = "在侧边栏打开计划"

    private let review: NativePlanReviewData
    private let isBusy: Bool
    private let errorText: String?
    private let width: CGFloat
    private let onApprove: () -> Void
    private let onRequestChanges: () -> Void
    private let onOpenPlan: (() -> Void)?

    /// - Parameters:
    ///   - review: question + plan Markdown; title/summary derive from it.
    ///   - isBusy: decision in flight — buttons disable, strip dot spins.
    ///   - errorText: failed-send copy for the footer status slot.
    ///   - width: card width (338 at 402pt).
    ///   - onApprove / onRequestChanges: answer or dismiss the review.
    ///   - onOpenPlan: opens the full plan; 「查看全文」 hides when nil.
    public init(review: NativePlanReviewData,
                isBusy: Bool = false,
                errorText: String? = nil,
                width: CGFloat = 338,
                onApprove: @escaping () -> Void,
                onRequestChanges: @escaping () -> Void,
                onOpenPlan: (() -> Void)? = nil) {
        self.review = review
        self.isBusy = isBusy
        self.errorText = errorText
        self.width = width
        self.onApprove = onApprove
        self.onRequestChanges = onRequestChanges
        self.onOpenPlan = onOpenPlan
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NativeParityTokens.radiusXL, style: .continuous)
        return VStack(spacing: 0) {
            strip
            summary
            footer
        }
        .frame(width: width)
        .background(NativeParityTokens.input)
        .clipShape(shape)
        .overlay(shape.strokeBorder(NativeParityTokens.borderL2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.02), radius: 16, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.question)
        .accessibilityValue(isBusy ? "正在提交" : "")
    }

    // MARK: - Warm strip

    private var strip: some View {
        HStack(spacing: 8) {
            if isBusy {
                NativeOngoingRing()
            } else {
                Circle()
                    .fill(PlanReviewInk.warn)
                    .frame(width: 6, height: 6)
                    .frame(width: 10, height: 10)
            }
            Text(Self.headerText)
                .font(.system(size: 14))
                .foregroundStyle(PlanReviewInk.warn)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let onOpenPlan {
                Button(action: onOpenPlan) {
                    HStack(spacing: 4) {
                        Text(Self.openFullPlanText)
                        NativeChatIcon(name: .chevronDown, size: 14)
                            .rotationEffect(.degrees(-90))
                    }
                }
                .buttonStyle(PlanReviewLinkStyle())
                .accessibilityLabel(Self.openFullPlanAccessibilityText)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeParityTokens.warningSurface)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NativeParityTokens.labelPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if !review.summary.isEmpty {
                Text(review.summary)
                    .font(.system(size: 14))
                    .lineSpacing(NativeParityTokens.bodyLineSpacing)
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        // Official ≤720px footer aligns its items to the bottom edge.
        HStack(alignment: .bottom, spacing: 12) {
            Text(errorText ?? "")
                .font(.system(size: 11))
                .foregroundStyle(NativeParityTokens.error)
                .lineLimit(1)
                .frame(minHeight: 16, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(action: onRequestChanges) {
                    HStack(spacing: 6) {
                        NativeChatIcon(name: .edit, size: 14)
                        Text(Self.requestChangesText)
                    }
                }
                .buttonStyle(PlanReviewButtonStyle(variant: .outline))
                Button(action: onApprove) {
                    Text(Self.approveText)
                }
                .buttonStyle(PlanReviewButtonStyle(variant: .primary))
            }
            .disabled(isBusy)
            // Official `Button:disabled { opacity: .4 }`.
            .opacity(isBusy ? 0.4 : 1)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - Buttons (official `Button md`)

private enum PlanReviewButtonVariant { case outline, primary }

/// 36pt tall, radius 12, 14/22 label, 0/14 padding.
private struct PlanReviewButtonStyle: ButtonStyle {
    let variant: PlanReviewButtonVariant

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeParityTokens.radiusMD, style: .continuous)
        return configuration.label
            .font(.system(size: 14))
            .foregroundStyle(variant == .primary ? PlanReviewInk.primaryInk
                                                 : NativeParityTokens.labelPrimary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(background(pressed: configuration.isPressed))
            .clipShape(shape)
            .overlay {
                if variant == .outline {
                    shape.strokeBorder(NativeParityTokens.borderL3, lineWidth: 0.5)
                }
            }
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    /// Filled primary darkens while pressed; outlined stays transparent until
    /// pressed (official `interactive-bg-hover`).
    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary:
            return NativeParityTokens.labelPrimary.opacity(pressed ? 0.9 : 1)
        case .outline:
            return NativeParityTokens.rgba(light: 0x263148, lightAlpha: 0.06,
                                           dark: 0xFFFFFF, darkAlpha: 0.08)
                .opacity(pressed ? 1 : 0)
        }
    }
}

/// Official `.reviewLink`: 14pt secondary label that darkens while pressed.
private struct PlanReviewLinkStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(configuration.isPressed ? NativeParityTokens.labelPrimary
                                                     : NativeParityTokens.labelSecondary)
    }
}

// MARK: - Ink not yet promoted to NativeParityTokens

private enum PlanReviewInk {
    /// Official `state-warn-primary` (amber-500); `NativeParityTokens.warning` is
    /// the darker `state-warn-label` amber (#DD8629), so the strip ink stays local.
    static let warn = NativeParityTokens.color(light: 0xF59E0B, dark: 0xF59E0B)
    /// Official `label-primary-foreground` (inverted label).
    static let primaryInk = NativeParityTokens.color(light: 0xFFFFFF, dark: 0x0F1115)
}

#if DEBUG
struct NativePlanReviewCard_Previews: PreviewProvider {
    private static let plan = """
    # Add `--greeting` flag to CLI

    Add a `--greeting <text>` option to the CLI entry point so scripts can print \
    a custom greeting before running. Keep the flag optional and default it to \
    the current build string.

    ## Steps
    1. Parse the flag in `cli.ts`
    2. Thread it through `run()`
    3. Cover it with one unit test
    """
    private static let question = "Approve this plan and leave plan mode?"

    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                NativePlanReviewCard(review: .init(question: question, markdown: plan),
                                     onApprove: {}, onRequestChanges: {}, onOpenPlan: {})
                NativePlanReviewCard(review: .init(question: question, markdown: plan),
                                     isBusy: true,
                                     onApprove: {}, onRequestChanges: {}, onOpenPlan: {})
                NativePlanReviewCard(review: .init(question: question, markdown: plan),
                                     errorText: "提交回答失败",
                                     onApprove: {}, onRequestChanges: {})
                NativePlanReviewCard(review: .init(question: question,
                                                   markdown: "# Ship the settings sheet"),
                                     onApprove: {}, onRequestChanges: {})
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("计划待审：默认 / 提交中 / 失败 / 仅标题")
    }
}

struct NativePlanReviewCardDark_Previews: PreviewProvider {
    static var previews: some View {
        NativePlanReviewCard(review: .init(question: "Approve this plan and leave plan mode?",
                                           markdown: "# Add `--greeting` flag to CLI\n\nAdd a --greeting option to the CLI."),
                             onApprove: {}, onRequestChanges: {}, onOpenPlan: {})
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .preferredColorScheme(.dark)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("计划待审：深色")
    }
}
#endif
