// SPDX-License-Identifier: MIT

// BotDeliveryViews: the "建议附上" block inside an existing approval/draft
// card. It uses the existing card rows and 44pt hit targets; it does not add a
// second card system or a second conversation surface.

import SwiftUI
import PhoneDSHBot

struct BotSuggestedResourcesSection: View {
    let session: BotDeliverySelectionSession
    var onToggle: (String) -> Void
    var onSubmit: () -> Void
    var onReset: () -> Void
    @Environment(\.botCardTheme) private var theme

    private var busy: Bool {
        switch session.phase {
        case .submitting, .awaitingDurable: return true
        case .idle, .failed: return false
        }
    }

    var body: some View {
        if session.draft.resources.isEmpty && session.draft.parameters.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            BotCardDivider()
            header
                .padding(.top, 10)
                .padding(.bottom, 2)
            if !session.draft.parameters.isEmpty {
                parametersLine
                    .padding(.bottom, 4)
            }
            ForEach(Array(session.draft.resources.enumerated()), id: \.element.id) { index, resource in
                if index > 0 { BotCardDivider(inset: BotCardMetrics.glyphColumn + 12) }
                resourceRow(resource)
            }
            if let hint = session.hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(phaseIsFailure ? NativeParityTokens.error : HomeSpec.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("bot.delivery.hint")
            }
            actions
                .padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.delivery.section")
    }

    private var phaseIsFailure: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            Text("建议附上")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Spacer(minLength: 8)
            Text(session.summary)
                .font(.system(size: 12))
                .foregroundStyle(HomeSpec.textTertiary)
                .monospacedDigit()
                .accessibilityIdentifier("bot.delivery.summary")
        }
        .frame(minHeight: 20)
    }

    private var parametersLine: some View {
        let values = session.draft.parameters.prefix(3)
            .map { "\($0.label)：\($0.value)" }
            .joined(separator: " · ")
        return Text(values)
            .font(.system(size: 12))
            .foregroundStyle(HomeSpec.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func resourceRow(_ resource: BotDeliveryResource) -> some View {
        let availability = session.availability(for: resource.id)
        let enabled: Bool = {
            if case .selectable = availability, session.canEdit { return true }
            return false
        }()
        Button {
            guard enabled else { return }
            onToggle(resource.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: glyph(for: resource))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(glyphInk(for: resource))
                    .frame(width: BotCardMetrics.glyphColumn, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(resource.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(enabled || session.isSelected(resource.id)
                                             ? HomeSpec.textPrimary : HomeSpec.textSecondary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let stateLabel = resource.stateLabel {
                            BotCardTag(text: stateLabel, tone: cardTone(for: resource))
                        }
                    }
                    if let detail = resource.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(HomeSpec.textTertiary)
                            .lineLimit(1)
                    }
                    if let reason = resource.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let source = resource.source {
                        Text("来自：\(source.label) · \(source.verification.label)")
                            .font(.system(size: 12))
                            .foregroundStyle(HomeSpec.textTertiary)
                            .lineLimit(1)
                    }
                    if let note = resource.selectionNote {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(resource.isSelectable
                                             ? HomeSpec.textTertiary : NativeParityTokens.error)
                    }
                    if let reason = resource.stateReason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundStyle(resource.isSelectable
                                             ? HomeSpec.textTertiary : NativeParityTokens.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 7)
            .frame(minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(resource, selected: session.isSelected(resource.id)))
        .accessibilityIdentifier("bot.delivery.resource.\(resource.id)")
    }

    @ViewBuilder
    private var actions: some View {
        switch session.phase {
        case .submitting:
            statusLine("正在更新选择…")
        case .awaitingDurable:
            statusLine("正在更新草稿…")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(friendlyFailure(reason))
                    .font(.system(size: 12))
                    .foregroundStyle(NativeParityTokens.error)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重试更新") { onSubmit() }
                        .buttonStyle(BotCardButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("bot.delivery.retry")
                    Button("撤销改动") { onReset() }
                        .buttonStyle(BotCardButtonStyle(kind: .plain))
                        .accessibilityIdentifier("bot.delivery.reset")
                }
            }
        case .idle:
            if session.hasChanges {
                HStack(alignment: .center, spacing: 8) {
                    Button("更新选择并重新确认") { onSubmit() }
                        .buttonStyle(BotCardButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("bot.delivery.submit")
                    Button("撤销改动") { onReset() }
                        .buttonStyle(BotCardButtonStyle(kind: .plain))
                        .accessibilityIdentifier("bot.delivery.reset")
                }
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(HomeSpec.textTertiary)
        }
        .frame(minHeight: 32)
        .accessibilityIdentifier("bot.delivery.pending")
    }

    private func cardTone(for resource: BotDeliveryResource) -> BotCardTone {
        switch resource.state {
        case .revoked, .erased, .unavailable: return .danger
        case .changed, .unknown: return .warning
        case .current: return .neutral
        }
    }

    private func glyph(for resource: BotDeliveryResource) -> String {
        if !resource.isSelectable { return "slash.circle" }
        return session.isSelected(resource.id) ? "checkmark.circle.fill" : "circle"
    }

    private func glyphInk(for resource: BotDeliveryResource) -> Color {
        if !resource.isSelectable { return HomeSpec.textPlaceholder }
        return session.isSelected(resource.id) ? theme.accent : HomeSpec.iconMuted
    }

    private func accessibilityLabel(_ resource: BotDeliveryResource, selected: Bool) -> String {
        var parts = [resource.name]
        if selected { parts.append("已选取") } else { parts.append("未选取") }
        if let state = resource.stateLabel { parts.append(state) }
        return parts.joined(separator: "，")
    }

    /// The planner's raw refusal codes never reach the screen.
    private func friendlyFailure(_ reason: String) -> String {
        switch reason {
        case "draft_revision_mismatch", "draft_changed":
            return "草稿已经更新，请查看最新选择后再确认。"
        case "resource_unavailable", "resource_revoked", "resource_erased":
            return "有资料已经失效，请移除后再更新。"
        case "invalid_selection", "missing_selection":
            return "这次选择没有生效，请重试。"
        default:
            return "这次选择没有更新成功，请重试。"
        }
    }
}
