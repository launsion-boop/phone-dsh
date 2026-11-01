// SPDX-License-Identifier: MIT

import SwiftUI

struct DeviceReadOnlyRow: View {
    let item: DeviceTranscriptItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 6) {
                    if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                    DeviceAttachmentLabels(attachments: item.attachments)
                }
                .font(.body)
                .padding(12)
                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .device:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("设备", systemImage: "iphone")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ChatPage.inkSecondary)
                    if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                    DeviceAttachmentLabels(attachments: item.attachments)
                }
                .font(.body)
                .padding(12)
                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 24)
            }
        case .assistant:
            NativeMarkdownBody(markdown: item.text.isEmpty && item.streaming ? "…" : item.text)
        case .reasoning:
            DisclosureGroup {
                NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text)
                    .font(.footnote)
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                    Text("思考")
                    if item.streaming { ProgressView().controlSize(.small) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        case .toolCall, .toolResult:
            DeviceReadOnlyToolRow(item: item)
        case .systemEvent, .turnError, .maxTokens:
            Label {
                Text(item.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: item.kind == .turnError ? "exclamationmark.circle" : "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(item.kind == .turnError ? ChatPage.danger : .secondary)
        case .image:
            DeviceAttachmentLabels(attachments: item.attachments)
        case .context, .unknown:
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.caption.weight(.medium))
                Text(item.text).textSelection(.enabled)
                DeviceAttachmentLabels(attachments: item.attachments)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .status:
            EmptyView()
        }
    }
}

private struct DeviceAttachmentLabels: View {
    let attachments: [DeviceTranscriptItem.Attachment]

    var body: some View {
        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
            Label(attachment.name, systemImage: attachment.isImage ? "photo" : "paperclip")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DeviceReadOnlyToolRow: View {
    let item: DeviceTranscriptItem
    @State private var expanded = false

    private var status: String {
        switch item.toolState {
        case .running, nil: "运行中"
        case .ok: "已完成"
        case .error: "失败"
        case .stopped: "已停止"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let arguments = item.argumentsRaw, !arguments.isEmpty {
                    DeviceToolText(title: "输入", text: arguments, isError: false)
                }
                if let output = item.toolOutput, !output.isEmpty {
                    DeviceToolText(title: "输出", text: output, isError: item.toolState == .error)
                } else if item.toolState == .running || item.toolState == nil {
                    Label("等待工具结果", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                Text(item.toolName ?? item.title).lineLimit(1)
                Spacer(minLength: 8)
                if item.toolState == .running || item.toolState == nil { ProgressView().controlSize(.small) }
                Text(status).font(.caption)
            }
            .font(.footnote)
            .foregroundStyle(item.toolState == .error ? ChatPage.danger : .secondary)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .accessibilityLabel(item.toolName ?? item.title)
        .accessibilityValue(status)
    }
}

private struct DeviceToolText: View {
    let title: String
    let text: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isError ? ChatPage.danger : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
