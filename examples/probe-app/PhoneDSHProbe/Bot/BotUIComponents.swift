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

/// The Bot's avatar: the DS big-fish character from dsh-bot, framed the way
/// dsh-bot crops its circle avatar, on a white disc with a hairline edge.
struct BotStaticAvatar: View {
    var size: CGFloat = 44

    var body: some View {
        BotAvatarImage(size: size)
            .overlay(Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .accessibilityLabel("Bot 头像")
    }
}

/// The bundled `BotAvatar` art clipped to a circle.
struct BotAvatarImage: View {
    var size: CGFloat

    var body: some View {
        Image("BotAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(Color.white)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

struct BotEmptyState: View {
    let title: String
    let message: String
    var systemImage = "bubble.left.and.bubble.right"
    /// The chat's welcome shows the Bot avatar instead of a symbol.
    var showsAvatar = false

    var body: some View {
        VStack(spacing: 16) {
            if showsAvatar {
                BotStaticAvatar(size: 72)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(HomeSpec.textTertiary)
                    .frame(width: 56, height: 56)
                    .background(HomeSpec.surface, in: Circle())
            }
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
