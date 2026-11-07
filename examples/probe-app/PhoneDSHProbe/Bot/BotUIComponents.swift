// SPDX-License-Identifier: MIT

import SwiftUI

private struct BotFontModifier: ViewModifier {
    let weight: Font.Weight
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var lineHeight: CGFloat

    init(size: CGFloat, lineHeight: CGFloat, weight: Font.Weight, style: Font.TextStyle) {
        self.weight = weight
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        _lineHeight = ScaledMetric(wrappedValue: lineHeight, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight))
            .lineSpacing(max(0, lineHeight - size))
    }
}

extension View {
    func botFont(size: CGFloat, lineHeight: CGFloat, weight: Font.Weight = .regular,
                 style: Font.TextStyle = .body) -> some View {
        modifier(BotFontModifier(size: size, lineHeight: lineHeight, weight: weight, style: style))
    }

    func botTitleFont() -> some View {
        botFont(size: 17, lineHeight: 22, weight: .semibold, style: .headline)
    }

    func botBodyFont(weight: Font.Weight = .regular) -> some View {
        botFont(size: HomeSpec.bodySize, lineHeight: HomeSpec.bodyLine, weight: weight)
    }

    func botProcessFont(weight: Font.Weight = .regular) -> some View {
        botFont(size: HomeSpec.processSize, lineHeight: HomeSpec.bodyLine, weight: weight)
    }

    func botSecondaryFont(weight: Font.Weight = .regular) -> some View {
        botFont(size: NativeParityTokens.secondarySize,
                lineHeight: NativeParityTokens.secondaryLineHeight, weight: weight, style: .callout)
    }

    func botCaptionFont(weight: Font.Weight = .regular) -> some View {
        botFont(size: NativeParityTokens.captionSize,
                lineHeight: NativeParityTokens.captionLineHeight, weight: weight, style: .caption)
    }

    func botHitTarget() -> some View {
        frame(minWidth: 44)
            .frame(height: 44)
    }
}

enum BotCardShape {
    case conversation
    case object
    case work
    case inline
    case approval

    var radius: CGFloat {
        switch self {
        case .conversation, .object: HomeSpec.bubbleRadius
        case .work: HomeSpec.listCardRadius
        case .inline, .approval: 12
        }
    }

    var surface: Color {
        switch self {
        case .approval: NativeParityTokens.selector
        default: HomeSpec.surface
        }
    }
}

struct BotCard<Content: View>: View {
    let shape: BotCardShape
    @ViewBuilder var content: Content

    init(_ shape: BotCardShape = .work, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.surface, in: RoundedRectangle(cornerRadius: shape.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: shape.radius, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL2, lineWidth: 0.5))
    }
}

struct BotPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .botFont(size: HomeSpec.bodySize, lineHeight: HomeSpec.bodyLine, weight: .semibold)
            .foregroundStyle(HomeSpec.primaryButtonInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(HomeSpec.primaryButton, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct BotSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .botProcessFont(weight: .medium)
            .foregroundStyle(NativeParityTokens.labelPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(NativeParityTokens.selector, in: Capsule())
            .overlay(Capsule().strokeBorder(NativeParityTokens.borderL2, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct BotTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .botSecondaryFont(weight: .medium)
            .foregroundStyle(NativeParityTokens.labelSecondary)
            .frame(minWidth: 44)
            .frame(height: 44)
            .padding(.horizontal, 8)
            .background(NativeParityTokens.selector.opacity(configuration.isPressed ? 0.8 : 0), in: Capsule())
    }
}

enum BotStatusTone {
    case accent, success, warning, danger, neutral

    var color: Color {
        switch self {
        case .accent: NativeParityTokens.accent
        case .success: NativeParityTokens.success
        case .warning: NativeParityTokens.warning
        case .danger: NativeParityTokens.error
        case .neutral: NativeParityTokens.labelTertiary
        }
    }
}

struct BotStatusPill: View {
    let text: String
    let tone: BotStatusTone
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .botCaptionFont(weight: .medium)
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct BotCardHeader: View {
    let title: String
    var systemImage: String?
    var status: String?
    var tone: BotStatusTone = .neutral

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
                    .frame(width: 32, height: 32)
                    .background(NativeParityTokens.selector, in: RoundedRectangle(cornerRadius: 10))
            }
            Text(title)
                .botTitleFont()
                .foregroundStyle(HomeSpec.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let status { BotStatusPill(text: status, tone: tone) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct BotIconTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(NativeParityTokens.labelSecondary)
            .frame(width: 42, height: 42)
            .background(NativeParityTokens.selector, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct BotStaticAvatar: View {
    var size: CGFloat = 44

    var body: some View {
        Text("Bot")
            .botCaptionFont(weight: .semibold)
            .foregroundStyle(HomeSpec.textSecondary)
            .frame(width: size, height: size)
            .background(HomeSpec.surface, in: Circle())
            .overlay(Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .accessibilityLabel("Bot 静态头像占位")
    }
}

struct BotEmptyState: View {
    let title: String
    let message: String
    var systemImage = "bubble.left.and.bubble.right"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(HomeSpec.textTertiary)
                .frame(width: 56, height: 56)
                .background(HomeSpec.surface, in: Circle())
            Text(title)
                .botTitleFont()
                .foregroundStyle(HomeSpec.textPrimary)
            Text(message)
                .botBodyFont()
                .foregroundStyle(HomeSpec.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}

struct BotFailureRow: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(NativeParityTokens.warning)
            Text(message)
                .botSecondaryFont()
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(BotTextButtonStyle())
                    .botHitTarget()
                    .accessibilityIdentifier("bot.retry")
            }
        }
        .padding(14)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
