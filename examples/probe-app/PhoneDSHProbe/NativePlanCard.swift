// SPDX-License-Identifier: MIT
// NativePlanCard — the official submitted-plan card rendered in the turn tail
// after `exit_plan_mode` settles (approved, rejected or dismissed).
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   packages/client/ui-plan/src/client/PlanCard.tsx
//   packages/client/ui-plan/src/client/PlanPreview.module.css
//   packages/client/ui-plan/src/client/locales.ts
//
// Geometry: 60pt tall, radius 16, 0.5pt hairline, `static-neutral-50` fill
// (#FAFAFA / #212123; pressed #F5F5F5 / #292929 over 120ms), padding 8/10, gap 10.
// 40x40 icon well (radius 10, hairline, white 50%/5%) holding the 20pt markdown
// file glyph in business-primary (#4176E6); title 13/20 w500, subtitle 10/16
// tertiary, trailing 「打开」chip 28pt tall / radius 8 / 12pt label. Each card is
// one button; the caller stacks multiple plans with a 10pt gap.
//
// This file also hosts `NativePlanDocument`, the markdown → plain-text projection
// both plan surfaces share (titles here, title + first paragraph in the review
// card), mirroring the official `submittedPlan()` / `extractMarkdownPlainText`.

import Foundation
import SwiftUI

/// One submitted plan (`exit_plan_mode` call that produced a document).
public struct NativePlanCardData: Identifiable, Equatable {
    /// The originating tool-call id (official `SubmittedPlan.callId`).
    public let id: String
    /// The plan's first `# ` heading, stripped of its marker.
    public let title: String
    /// Official `preview.document`.
    public var subtitle: String

    public init(id: String, title: String, subtitle: String = "计划 · Markdown") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    /// Builds the card straight from `exit_plan_mode`'s `args.plan`; nil when the
    /// document has no leading `# ` heading (the official `submittedPlan()` rule,
    /// which leaves such a call as a generic tool row).
    public init?(id: String, markdown: String, subtitle: String = "计划 · Markdown") {
        guard let title = NativePlanDocument.headingTitle(markdown) else { return nil }
        self.init(id: id, title: title, subtitle: subtitle)
    }
}

/// Markdown → plain text for plan titles and summaries.
public enum NativePlanDocument {
    /// Official `submittedPlan()`: the document must start with `# `, and the
    /// returned title is that first line without its marker.
    public static func headingTitle(_ markdown: String) -> String? {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("# ") else { return nil }
        let line = text.components(separatedBy: "\n").first ?? ""
        let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// First visible plain-text line (the plan's H1 when it starts with one).
    public static func firstLine(_ markdown: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            let text = plain(line)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// First semantic paragraph: the block after the heading, before the next
    /// block start (heading, quote, rule, fence) or blank line.
    public static func firstParagraph(_ markdown: String) -> String {
        var paragraph: [String] = []
        var inFence = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if paragraph.isEmpty { inFence.toggle(); continue }
                break
            }
            if inFence { continue }
            if line.isEmpty || startsBlock(line) {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.append(line)
        }
        return paragraph.map { plain($0) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix(">") || isHeading(line) || isRule(line)
    }

    private static func isHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = line.dropFirst(hashes.count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Unlinks links/images, drops inline-code/emphasis markers and leading block
    /// markers, then collapses whitespace.
    private static func plain(_ text: String) -> String {
        var value = text
        if let regex = try? NSRegularExpression(pattern: "!?\\[([^\\]]*)\\]\\([^()]*\\)") {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1")
        }
        for marker in ["**", "__", "~~", "`"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        return stripMarkers(value)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Drops a leading quote/bullet/ordinal/ATX-heading marker until none is left.
    private static func stripMarkers(_ text: String) -> String {
        var value = text
        var changed = true
        while changed {
            changed = false
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                if (1...6).contains(hashes.count),
                   hashes.count == trimmed.count || trimmed.dropFirst(hashes.count).hasPrefix(" ") {
                    value = String(trimmed.dropFirst(hashes.count))
                    changed = true
                    continue
                }
            }
            if trimmed.hasPrefix(">") {
                value = String(trimmed.dropFirst())
                changed = true
                continue
            }
            for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
                value = String(trimmed.dropFirst(prefix.count))
                changed = true
                break
            }
            if changed { continue }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
                let ordinal = trimmed[trimmed.startIndex..<dot]
                let next = trimmed.index(after: dot)
                if !ordinal.isEmpty, ordinal.allSatisfy(\.isNumber),
                   next < trimmed.endIndex, trimmed[next] == " " {
                    value = String(trimmed[trimmed.index(after: next)...])
                    changed = true
                }
            }
        }
        return value
    }
}

/// Turn-tail card that opens the submitted plan's Markdown preview.
public struct NativePlanCard: View {
    /// Official `preview.action`.
    public static let openText = "打开"
    /// Official `.cards` gap between stacked plans.
    public static let stackSpacing: CGFloat = 10

    private let plan: NativePlanCardData
    private let width: CGFloat
    private let onOpen: () -> Void

    /// - Parameters:
    ///   - plan: submitted plan identity + title.
    ///   - width: card width; 338 at the 402pt baseline
    ///     (`NativeParityTokens.contentWidth`).
    ///   - onOpen: opens the plan document (phone: full-width drawer/sheet).
    public init(plan: NativePlanCardData,
                width: CGFloat = 338,
                onOpen: @escaping () -> Void) {
        self.plan = plan
        self.width = width
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                iconWell
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NativeParityTokens.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(plan.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.openText)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeParityTokens.labelPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(PlanCardTint.openFill, in: openShape)
                    .overlay(openShape.strokeBorder(NativeParityTokens.borderL3, lineWidth: 0.5))
            }
        }
        .buttonStyle(NativePlanCardButtonStyle(width: width))
        // Official `preview.openNamed`.
        .accessibilityLabel("打开计划：\(plan.title)")
    }

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PlanCardTint.iconWell)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5)
            // FileTypeIcon kind="markdown": the shipped vector asset, tinted with
            // the official markdown file ink.
            Image("DSHFileMarkdown")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(NativeParityTokens.planChipInk)
                .frame(width: 20, height: 20)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private var openShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeParityTokens.radiusSM, style: .continuous)
    }
}

/// Card chrome: 60pt height, 8/10 padding, fill swap on press.
private struct NativePlanCardButtonStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
        return configuration.label
            .padding(.horizontal, 10)
            .frame(height: 60)
            .frame(width: width)
            .background(configuration.isPressed ? PlanCardTint.pressedFill : PlanCardTint.fill,
                        in: shape)
            .overlay(shape.strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5))
            .contentShape(shape)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Static neutral fills (not yet in NativeParityTokens)

private enum PlanCardTint {
    /// Official `static-neutral-50` / `static-neutral-850`.
    static let fill = NativeParityTokens.color(light: 0xFAFAFA, dark: 0x212123)
    /// Official `static-neutral-100` / `static-neutral-800`.
    static let pressedFill = NativeParityTokens.color(light: 0xF5F5F5, dark: 0x292929)
    /// `color-mix(static-neutral-00 50%, transparent)` / dark 5%.
    static let iconWell = NativeParityTokens.rgba(light: 0xFFFFFF, lightAlpha: 0.5,
                                                  dark: 0xFFFFFF, darkAlpha: 0.05)
    /// Official `button-floating-fill`.
    static let openFill = NativeParityTokens.color(light: 0xFFFFFF, dark: 0x2C2C2E)
}

#if DEBUG
private extension NativePlanCardData {
    /// Built the way the integrator will: straight from `exit_plan_mode`'s
    /// `args.plan`, whose leading `# ` heading becomes the card title.
    static var previewPlans: [NativePlanCardData] {
        [
            NativePlanCardData(id: "call-plan-1", markdown: """
            # Add `--greeting` flag to CLI

            Add a `--greeting <text>` option to the CLI entry point.
            """),
            .init(id: "call-plan-2",
                  title: "把会话投影的 todos/plan 接到原生会话页并按 402pt 基线验收"),
        ].compactMap { $0 }
    }
}

struct NativePlanCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: NativePlanCard.stackSpacing) {
            ForEach(NativePlanCardData.previewPlans) { plan in
                NativePlanCard(plan: plan) {}
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("已提交计划卡：单张 / 多张")
    }
}

struct NativePlanCardDark_Previews: PreviewProvider {
    static var previews: some View {
        NativePlanCard(plan: .init(id: "call-plan-1", title: "Add `--greeting` flag to CLI")) {}
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .preferredColorScheme(.dark)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("已提交计划卡：深色")
    }
}
#endif
