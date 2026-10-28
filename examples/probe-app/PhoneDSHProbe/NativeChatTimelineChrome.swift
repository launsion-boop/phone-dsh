// SPDX-License-Identifier: MIT
// Calm, provenance-preserving presentation for injected DSH context.

import SwiftUI
import UIKit

enum NativeTranscriptRow: Identifiable {
    case item(ChatItem)
    case contexts([ChatItem])
    /// One run of consecutive tool calls/results, folded into a single row.
    case tools([ChatItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .contexts(let items): "context-group-\(items.first?.id ?? "empty")"
        case .tools(let items): "tool-run-\(items.first?.id ?? "empty")"
        }
    }
}

struct NativeContextSourceGroup: View {
    let items: [ChatItem]
    @State private var isExpanded = false

    private var sourceNames: [String] {
        items.map { $0.title.replacingOccurrences(of: "DSH context · ", with: "") }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    contextDetail(item)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("上下文")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("· \(items.count) 条")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if items.count == 1, let source = sourceNames.first.flatMap(NativeSourceName.chinese) {
                    Text(source)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .font(.footnote)
        .tint(.secondary)
        .padding(.leading, -4)
        .padding(.vertical, 1)
    }

    private func contextDetail(_ item: ChatItem) -> some View {
        let source = item.title.replacingOccurrences(of: "DSH context · ", with: "")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let name = NativeSourceName.chinese(source) {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = item.text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(NativeSourceName.chinese(source).map { "复制\($0)上下文" } ?? "复制这条上下文")
            }
            // 引用来的文字,不是代码:不加底色,13 号次要墨、行高 20。
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
                .lineSpacing(20 - 16)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
// 宿主给的上下文来源名是程序内部的名字(user-approval、command 之类),不许上屏。
// 认得出来的翻中文,认不出来的一律不显示:留白比露原文强。
enum NativeSourceName {
    static func chinese(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user-approval", "user_approval": return "你同意的"
        case "file", "workspace", "files": return "读过的文件"
        case "command", "shell": return "命令输出"
        case "search", "web-search": return "搜到的"
        default: return nil
        }
    }
}
