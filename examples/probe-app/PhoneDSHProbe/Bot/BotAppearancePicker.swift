// SPDX-License-Identifier: MIT

import PhoneDSHBot
import SwiftUI

/// The one appearance editor shared by the Bot info page and the add-Bot
/// dialog: a live preview, the four hairstyle stills and the fifteen colour
/// swatches. Selection is rendered immediately from the value the caller
/// passes; writing it is the caller's decision (the info page saves per tap,
/// the add dialog keeps a draft until 创建).
struct BotAppearancePicker: View {
    var appearance: BotFishAppearance
    var isMainBot = false
    var showsPreview = true
    var previewSize: CGFloat = 112
    var identifierPrefix = "bot.info.appearance"
    var onSelectColor: (BotFishColor) -> Void
    var onSelectHairstyle: (BotFishHairstyle) -> Void

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 2, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsPreview {
                BotFishView(state: .idle, size: previewSize, appearance: appearance,
                            crowned: isMainBot, allowsPoke: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("外观预览，\(appearance.color.displayName)，\(appearance.hairstyle.displayName)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("发型")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                HStack(spacing: 6) {
                    ForEach(BotFishHairstyle.allCases, id: \.self) { hairstyle in
                        hairstyleButton(hairstyle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("颜色")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                    ForEach(BotFishColor.allCases, id: \.self) { color in
                        colorButton(color)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// The preview for one hairstyle keeps the selected colour and drops the
    /// automatic flag, matching the info page's per-field writes.
    func appearance(for hairstyle: BotFishHairstyle) -> BotFishAppearance {
        var value = appearance
        value.hairstyle = hairstyle
        value.autoHairstyle = false
        return value
    }

    private func hairstyleButton(_ hairstyle: BotFishHairstyle) -> some View {
        let selected = appearance.hairstyle == hairstyle
        return Button {
            onSelectHairstyle(hairstyle)
        } label: {
            BotFishView(state: .idle, size: 40, appearance: appearance(for: hairstyle),
                        crowned: isMainBot, still: true)
                .frame(width: 44, height: 44)
                .background(selected ? HomeSpec.userBubble : Color.clear, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(HomeSpec.primaryButton, lineWidth: selected ? 2 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hairstyle.displayName)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("\(identifierPrefix).hair.\(hairstyle.rawValue)")
    }

    private func colorButton(_ color: BotFishColor) -> some View {
        let selected = appearance.color == color
        return Button {
            onSelectColor(color)
        } label: {
            Circle()
                .fill(Self.swatch(color))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5)
                }
                .frame(width: 44, height: 44)
                .overlay {
                    Circle()
                        .strokeBorder(HomeSpec.primaryButton, lineWidth: selected ? 2 : 0)
                        .frame(width: 32, height: 32)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("\(identifierPrefix).color.\(color.rawValue)")
    }

    static func swatch(_ color: BotFishColor) -> Color {
        let hex = color.hex.hasPrefix("#") ? String(color.hex.dropFirst()) : color.hex
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return .gray }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
