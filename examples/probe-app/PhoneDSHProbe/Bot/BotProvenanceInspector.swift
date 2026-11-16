// SPDX-License-Identifier: MIT

// BotSourceInspector: the one source entry for a Bot row. It replaces the raw
// row/trust/event-id sheet with human-readable evidence, reason, verification,
// freshness and an explicit invalid/revoked banner. Internal ids never enter
// the primary flow.

import SwiftUI
import UIKit

struct BotSourceInspectorSheet: View {
    let row: BotUIRow
    /// Production wiring resolves the row's derived refs through the lineage
    /// and source services. The default is unavailable; it never fabricates a
    /// source.
    var inspect: (BotSourceInspectionRequest) async -> BotSourceInspectionResult = { _ in
        .unavailable(reason: "来源服务未连接")
    }
    var nowMS: () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
    @Environment(\.dismiss) private var dismiss
    @State private var model: BotProvenanceInspectorModel?
    @State private var failure: String?
    @State private var loading = false
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section {
                        BotSourceInspectorNotice(
                            icon: "exclamationmark.triangle",
                            text: "暂时无法读取来源的当前状态",
                            detail: failure,
                            tone: .warning)
                        Button("重试") { reloadToken &+= 1 }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("bot.source.retry")
                    }
                }
                if let model {
                    if let banner = model.banner {
                        Section {
                            BotSourceInspectorNotice(
                                icon: banner.tone == .danger
                                    ? "exclamationmark.octagon" : "exclamationmark.triangle",
                                text: banner.text,
                                detail: banner.detail,
                                tone: banner.tone == .danger ? .danger : .warning)
                        }
                    }
                    Section {
                        if loading, model.sources.isEmpty {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                        } else if model.sources.isEmpty {
                            Text("这条内容没有留下可展示的来源。")
                                .foregroundStyle(HomeSpec.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                                BotSourceRowView(source: source, nowMS: model.checkedAtMS)
                                    .accessibilityIdentifier("bot.source.entry.\(index)")
                            }
                        }
                    } header: {
                        Text(model.headline)
                    } footer: {
                        Text("来源状态由宿主的记录决定。已失效、已撤权或已抹除的依据不会继续作为当前事实；这里不显示内部编号。")
                    }
                    if case .limited(let reason) = model.availability {
                        Section {
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundStyle(HomeSpec.textTertiary)
                        }
                    }
                } else if loading {
                    Section {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("来源")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .accessibilityIdentifier("bot.source.inspector")
        }
        .task(id: reloadToken) { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        let current = nowMS()
        let request = BotSourceInspectionRequest(botID: row.botID, rowID: row.id,
                                                 eventIDs: row.provenance.eventIDs)
        let result = await inspect(request)
        switch result {
        case .available(let inspection):
            model = BotProvenanceInspectorModel(row: row, inspection: inspection, nowMS: current)
            failure = nil
        case .unavailable(let reason):
            // Keep the truthful row-level fallback visible, but say that the
            // current state could not be read. A cached "current" claim would
            // be a fabricated source state.
            model = BotProvenanceInspectorModel(row: row, nowMS: current)
            failure = reason
        }
        loading = false
    }
}

private struct BotSourceInspectorNotice: View {
    let icon: String
    let text: String
    let detail: String?
    let tone: BotStatusTone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct BotSourceRowView: View {
    let source: BotProvenanceSource
    let nowMS: Int64

    private var meta: String {
        [source.trust.label, source.verification.label].joined(separator: " · ")
    }

    private var timeLabel: String? {
        BotProvenanceTime.label(source.observedAtMS, nowMS: nowMS)
    }

    private var stateTone: BotStatusTone {
        switch source.state {
        case .current: return .success
        case .changed, .unknown: return .warning
        case .revoked, .erased, .unavailable: return .danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.kind.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(width: 30, height: 30)
                .background(HomeSpec.userBubble, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(source.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if source.state != .current || source.verification == .disputed {
                        BotStatusPill(text: source.verification == .disputed
                                      ? source.verification.label : source.state.label,
                                      tone: stateTone)
                    }
                }
                if let reason = source.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(HomeSpec.textTertiary)
                if let timeLabel {
                    Text(timeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textTertiary)
                }
                if let versionLabel = source.versionLabel, !versionLabel.isEmpty {
                    Text("来源版本：\(versionLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textTertiary)
                }
                if let accessLabel = source.accessLabel {
                    Text(accessLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(stateTone.color)
                }
                if source.state != .current, let detail = source.stateReason, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(stateTone.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if source.isFallback {
                    Text("未提供可核验的原始记录")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textTertiary)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 44, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [source.label, source.kind.label, meta]
        if let reason = source.reason, !reason.isEmpty { parts.append(reason) }
        if let timeLabel { parts.append(timeLabel) }
        if source.state != .current { parts.append(source.state.label) }
        return parts.joined(separator: "，")
    }
}
