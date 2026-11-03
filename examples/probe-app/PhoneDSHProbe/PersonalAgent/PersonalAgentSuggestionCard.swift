// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct PersonalAgentSuggestionCard: View {
    let suggestion: SuggestionCard
    let onDismiss: () -> Void
    let onDecline: () -> Void
    let onChoose: (SuggestionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭建议")
                .accessibilityIdentifier("app.chat.suggestions.dismiss")
            }

            ForEach(Array(suggestion.options.prefix(4).enumerated()), id: \.element.id) { index, option in
                Button { onChoose(option) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(Character(UnicodeScalar(65 + index)!)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(HomeSpec.userBubble, in: RoundedRectangle(cornerRadius: 7))
                        Text(option.label)
                            .font(.subheadline)
                            .foregroundStyle(HomeSpec.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("app.chat.suggestion.\(index)")
            }

            VStack(alignment: .leading, spacing: 8) {
                if suggestion.allowCustom {
                    Text("或在下方聊天中回答")
                        .font(.caption)
                        .foregroundStyle(HomeSpec.textTertiary)
                }
                if suggestion.kind == .nextSteps {
                    Button("不再建议", action: onDecline)
                        .font(.caption)
                        .foregroundStyle(HomeSpec.textTertiary)
                        .accessibilityIdentifier("app.chat.suggestions.decline")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HomeSpec.borderList, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
