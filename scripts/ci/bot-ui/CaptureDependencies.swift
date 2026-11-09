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
                if !callID.isEmpty { callIndexes[callID] = result.count }
                result.append(item)
            case "tool/result":
                let message = data["message"] ?? .null
                let callID = message["toolCallId"]?.stringValue
                    ?? message["source"]?["callId"]?.stringValue ?? ""
                let error = data["error"] != nil || message["isError"]?.boolValue == true
                let output = message["content"]?.stringValue ?? ""
                if let index = callIndexes[callID] {
                    result[index].kind = .toolResult(isError: error)
                    result[index].toolOutput = output
                } else {
                    var item = ChatItem(id: "\(sessionID):\(seq)",
                                        kind: .toolResult(isError: error),
                                        title: error ? "Tool error" : "Tool result",
                                        text: output)
                    item.callID = callID
                    item.toolOutput = output
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textTertiary)
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textPrimary)
                    Spacer(minLength: 0)
                }
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
