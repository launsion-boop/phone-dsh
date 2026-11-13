// SPDX-License-Identifier: MIT

// Fixture-only stand-ins for the app-root presentation types that the Bot
// sources reference. The capture app intentionally links only PhoneDSHBot and
// PhoneDSHAgentCore; pulling ChatPage.swift or NativeTranscriptProjector.swift
// into this target would drag the whole DSH session UI (and SwiftMath) with it.
// These types keep the Bot page's real layout and interaction code compiling
// against the same tool-row / process-row surface without changing app source.

import Foundation
import SwiftUI
import UIKit
import PhoneDSHAgentCore

enum NativeToolState: Equatable {
    case preparing, running, ok, error, stopped
}

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case toolCall
        case toolResult(isError: Bool)
    }

    let id: String
    var kind: Kind
    var title: String
    var text: String
    var toolName: String? = nil
    var callID: String? = nil
    var argumentsRaw: String? = nil
    var toolOutput: String? = nil
    var toolState: NativeToolState? = nil
}

enum NativeTranscriptProjector {
    /// Minimal fixture projector: enough of the real journal-to-tool-row
    /// projection for the running-tool fixture and the process row.
    static func items(from records: [JSONValue], sessionID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        var callIndexes: [String: Int] = [:]
        for event in records {
            guard let seq = event["seq"]?.intValue,
                  let type = event["type"]?.stringValue else { continue }
            let data = event["data"] ?? .null
            switch type {
            case "tool/call":
                let callID = data["callId"]?.stringValue ?? ""
                let name = data["name"]?.stringValue ?? "tool"
                let raw = data["arguments"]?.stringValue ?? ""
                var item = ChatItem(id: "\(sessionID):\(seq)", kind: .toolCall,
                                    title: name, text: raw)
                item.toolName = name
                item.callID = callID
                item.argumentsRaw = raw
                item.toolState = .running
                if !callID.isEmpty { callIndexes[callID] = result.count }
                result.append(item)
            case "tool/result":
                let message = data["message"] ?? .null
                let callID = message["toolCallId"]?.stringValue
                    ?? message["source"]?["callId"]?.stringValue ?? ""
                let error = data["error"] != nil || message["isError"]?.boolValue == true
                let output = (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
                    guard block["type"]?.stringValue == "text" else { return nil }
                    return block["text"]?.stringValue
                }.joined()
                if let index = callIndexes[callID] {
                    result[index].kind = .toolResult(isError: error)
                    result[index].toolOutput = output
                    result[index].toolState = error ? .error : .ok
                } else {
                    var item = ChatItem(id: "\(sessionID):\(seq)",
                                        kind: .toolResult(isError: error),
                                        title: error ? "Tool error" : "Tool result",
                                        text: output)
                    item.callID = callID
                    item.toolOutput = output
                    item.toolState = error ? .error : .ok
                    result.append(item)
                }
            default:
                continue
            }
        }
        return result
    }
}

enum NativeTurnProcessState: Equatable {
    case running
    case completed(elapsed: TimeInterval?)
    case stopped
    case failed

    static func resolve(endReasonKind: String?, elapsed: TimeInterval?) -> NativeTurnProcessState {
        guard let endReasonKind else { return .running }
        switch endReasonKind {
        case "aborted", "interrupted": return .stopped
        case "error": return .failed
        default: return .completed(elapsed: elapsed)
        }
    }

    var label: String {
        switch self {
        case .running: return ""
        case .stopped: return "已停止"
        case .failed: return "处理失败"
        case .completed(let elapsed):
            guard let elapsed else { return "已完成" }
            return "已完成，用时 \(Int(max(1, elapsed)))秒"
        }
    }

    var alwaysOpen: Bool {
        switch self {
        case .running, .stopped, .failed: return true
        case .completed: return false
        }
    }
}

struct NativeTurnProcessRow: View {
    let state: NativeTurnProcessState
    let isOpen: Bool
    let isFoldable: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(state.label)
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textTertiary)
                if isFoldable {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HomeSpec.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 33, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ToolRunRow: View {
    let items: [ChatItem]
    /// Mirrors the app's shared ToolRunRow override; the Bot page passes the
    /// same action-name mapping used in production. The Bot page has already
    /// replaced a failed call's wire output with the human summary.
    var titleForItem: ((ChatItem) -> String)? = nil

    private var uniqueItems: [ChatItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(uniqueItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.toolState == .error
                          ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .font(.system(size: 12))
                        .foregroundStyle(item.toolState == .error
                                         ? BotUIPalette.danger : HomeSpec.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(titleForItem?(item) ?? item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textPrimary)
                        if item.toolState == .error,
                           let summary = item.toolOutput, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(HomeSpec.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    [titleForItem?(item) ?? item.title,
                     item.toolState == .error ? item.toolOutput ?? "" : ""]
                        .filter { !$0.isEmpty }
                        .joined(separator: "，"))
                .accessibilityIdentifier("bot.tool.row")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct NativeMarkdownBody: View {
    let markdown: String
    let streaming: Bool
    let workspaceFiles: [String]
    let onOpenFile: ((String) -> Void)?

    init(markdown: String, streaming: Bool = false,
         workspaceFiles: [String] = [], onOpenFile: ((String) -> Void)? = nil) {
        self.markdown = markdown
        self.streaming = streaming
        self.workspaceFiles = workspaceFiles
        self.onOpenFile = onOpenFile
    }

    var body: some View {
        Text(markdown)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

enum NativeChatTheme {
    static func bodyFont() -> Font { NativeChatPreferences.shared.font(for: .text) }

    static var bodyLineSpacing: CGFloat {
        let size = CGFloat(NativeChatPreferences.shared.textFontSize)
        return max(0, NativeParityTokens.bodyLineHeight - UIFont.systemFont(ofSize: size).lineHeight)
    }
}

// MARK: - Card file preview stand-ins

// The capture target copies `Bot/` (including BotCardFilePreview.swift) but
// not the app's preview stack, which drags in PhoneDSHEngine and the page
// bridge. These stand-ins keep the card code compiling. Fixtures either pass
// an injected `canOpenPath` handler or carry inline content, so no fixture
// depends on resolving a workspace file; a path-only card shows the real
// failure copy.
enum PreviewKind {
    case text, markdown, html, model, webMedia, image, pdf, office, video, audio, unsupported
}

extension URL {
    var previewKind: PreviewKind {
        switch pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "txt", "log", "json", "jsonl", "yaml", "yml", "xml", "toml", "ini", "csv", "tsv",
             "swift", "m", "c", "h", "go", "rs", "py", "js", "ts", "sh", "css", "sql":
            return .text
        default: return .unsupported
        }
    }
}

enum PreviewTarget: Identifiable, Hashable {
    case workspaceFile(String)

    var id: String {
        switch self {
        case .workspaceFile(let path): return "workspace:\(path)"
        }
    }
}

enum PreviewPathResolver {
    /// The capture app has no ChatModel workspace; a card path is never
    /// resolvable here, which is the explicit-error branch.
    static func fileURL(for relativePath: String) -> URL? { nil }
}

struct PreviewSurface: View {
    let target: PreviewTarget

    var body: some View {
        ContentUnavailableView("预览不可用", systemImage: "doc.questionmark",
                               description: Text("采集目标没有接入工作区预览。"))
    }
}

struct NativePagedTextView: View {
    let text: String
    let isLoading: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
        }
    }
}
