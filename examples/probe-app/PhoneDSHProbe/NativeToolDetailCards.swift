// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHAgentCore

struct NativeToolCallRow: View {
    let item: ChatItem
    var onOpenFile: (String) -> Void
    @State private var expanded = false
    private var model: NativeToolCallModel { NativeToolCallModel(item: item) }

    var body: some View {
        NativeDisclosureRow(icon: model.icon, title: model.title, summary: model.summary,
                            running: model.state == .running || model.state == .preparing,
                            expandable: model.hasDetails, showsSummaryWhenExpanded: true,
                            expanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let path = model.filePath {
                    Button { onOpenFile(path) } label: {
                        Label(path, systemImage: "arrow.up.right.square")
                            .font(NativeChatTheme.captionFont())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NativeChatTheme.accent)
                }
                NativeToolDetails(model: model)
            }
            .padding(.leading, 4)
            .padding(.vertical, 4)
        }
        .accessibilityValue(model.state == .error ? "失败" : model.state == .stopped ? "已停止" : model.state == .running ? "运行中" : "已完成")
    }
}

private struct NativeToolDetails: View {
    let model: NativeToolCallModel

    var body: some View {
        switch model.variant {
        case .bash:
            NativeTerminalCard(command: model.argumentsObject?["command"]?.stringValue ?? model.input ?? "",
                               output: model.output ?? "", exitCode: model.item.toolMetadata?["exitCode"]?.intValue
                                ?? model.item.toolMetadata?["exit_code"]?.intValue)
        case .read where model.name == "read", .read where model.name == "read_image":
            if let lines = model.item.toolMetadata?["lines"]?.arrayValue {
                NativeReadCard(lines: lines)
            } else {
                NativeIOCard(input: model.input, output: model.output, isError: model.state == .error)
            }
        case .search where model.name == "grep" || model.name == "glob":
            NativeSearchCard(metadata: model.item.toolMetadata, output: model.output)
        case .search where model.name == "web_search", .read where model.name == "web_fetch":
            NativeWebCard(metadata: model.item.toolMetadata, output: model.output)
        case .write, .edit:
            if let diff = nativeToolDiff(model) {
                NativeDiffCard(oldText: diff.old, newText: diff.new)
            } else {
                NativeIOCard(input: model.input, output: model.output, isError: model.state == .error)
            }
        case .code:
            VStack(alignment: .leading, spacing: 6) {
                if let input = model.input { DSSCodeBlock(source: input, language: "typescript") }
                if let output = model.output { NativeIOCard(input: nil, output: output, isError: model.state == .error) }
            }
        default:
            NativeIOCard(input: model.input, output: model.output, isError: model.state == .error)
        }
    }
}

private struct NativeTerminalCard: View {
    let command: String
    let output: String
    let exitCode: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("$").foregroundStyle(NativeChatTheme.tertiary)
                Text(command)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let exitCode {
                    Text("exit \(exitCode)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(exitCode == 0 ? NativeChatTheme.selector : NativeChatTheme.danger.opacity(0.12),
                                    in: Capsule())
                        .foregroundStyle(exitCode == 0 ? NativeChatTheme.secondary : NativeChatTheme.danger)
                }
            }
            .font(NativeChatTheme.codeFont())
            .padding(12)
            .background(NativeChatTheme.codeBanner)
            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(NativeChatTheme.codeFont())
                        .foregroundStyle(exitCode == 0 || exitCode == nil ? NativeChatTheme.secondary : NativeChatTheme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 224)
            }
        }
        .background(NativeChatTheme.code)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeChatTheme.border, lineWidth: 0.5))
    }
}

private struct NativeReadCard: View {
    let lines: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(line["number"]?.intValue ?? 0)")
                        .foregroundStyle(NativeChatTheme.caption)
                        .frame(minWidth: 32, alignment: .trailing)
                    Text(line["text"]?.stringValue ?? "")
                        .foregroundStyle(NativeChatTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(NativeChatTheme.codeFont())
                .padding(.horizontal, 12).padding(.vertical, 2)
            }
        }
        .padding(.vertical, 10)
        .background(NativeChatTheme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NativeSearchCard: View {
    let metadata: JSONValue?
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if metadata?["shape"]?.stringValue == "paths" {
                ForEach(metadata?["paths"]?.arrayValue ?? [], id: \.self) { path in
                    Text(path.stringValue ?? "").font(NativeChatTheme.codeFont())
                }
            } else {
                ForEach(metadata?["files"]?.arrayValue ?? [], id: \.self) { file in
                    Text(file["path"]?.stringValue ?? "").font(NativeChatTheme.secondaryFont().weight(.medium))
                    ForEach(file["matches"]?.arrayValue ?? [], id: \.self) { match in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(match["lineNumber"]?.intValue ?? 0)").foregroundStyle(NativeChatTheme.caption)
                            Text(match["line"]?.stringValue ?? "").fixedSize(horizontal: false, vertical: true)
                        }
                        .font(NativeChatTheme.codeFont())
                    }
                }
            }
            if (metadata?["files"] == nil && metadata?["paths"] == nil), let output { Text(output).font(NativeChatTheme.codeFont()) }
            if metadata?["truncated"]?.boolValue == true {
                Text("结果已截断").font(NativeChatTheme.captionFont()).foregroundStyle(NativeChatTheme.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeChatTheme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NativeWebCard: View {
    let metadata: JSONValue?
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = metadata?["answer"]?.stringValue { Text(answer).font(NativeChatTheme.secondaryFont()) }
            if let url = metadata?["url"]?.stringValue {
                LabeledContent("地址", value: url)
                LabeledContent("HTTP", value: "\(metadata?["statusCode"]?.intValue ?? 0)")
            }
            ForEach(metadata?["sources"]?.arrayValue ?? [], id: \.self) { source in
                VStack(alignment: .leading, spacing: 3) {
                    if let title = source["title"]?.stringValue { Text(title).font(NativeChatTheme.secondaryFont().weight(.medium)) }
                    if let url = source["url"]?.stringValue { Text(url).font(NativeChatTheme.captionFont()).foregroundStyle(NativeChatTheme.accent) }
                    if let snippet = source["snippet"]?.stringValue { Text(snippet).font(NativeChatTheme.captionFont()).foregroundStyle(NativeChatTheme.secondary) }
                }
            }
            if metadata == nil, let output { Text(output).font(NativeChatTheme.codeFont()) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeChatTheme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NativeIOCard: View {
    let input: String?
    let output: String?
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input { section(title: "输入", text: input, isError: false) }
            if input != nil && output != nil { Divider().overlay(NativeChatTheme.border) }
            if let output { section(title: "输出", text: output, isError: isError) }
        }
        .background(NativeChatTheme.code)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeChatTheme.border, lineWidth: 0.5))
    }

    private func section(title: String, text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundStyle(NativeChatTheme.caption)
            ScrollView {
                Text(text)
                    .foregroundStyle(isError ? NativeChatTheme.danger : NativeChatTheme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .font(NativeChatTheme.codeFont())
        .padding(12)
    }
}

private func nativeToolDiff(_ model: NativeToolCallModel) -> (old: String?, new: String)? {
    if let diff = model.item.toolMetadata?["diffs"]?.arrayValue?.first,
       let newText = diff["newText"]?.stringValue {
        return (diff["oldText"]?.stringValue, newText)
    }
    guard let args = model.argumentsObject else { return nil }
    if model.name == "write", let text = args["content"]?.stringValue { return (nil, text) }
    if model.name == "edit", let text = args["new_string"]?.stringValue { return (args["old_string"]?.stringValue, text) }
    if model.name == "str_replace_editor" {
        if args["command"]?.stringValue == "create" { return (nil, args["file_text"]?.stringValue ?? "") }
        if args["command"]?.stringValue == "str_replace" { return (args["old_str"]?.stringValue, args["new_str"]?.stringValue ?? "") }
    }
    return nil
}

struct NativeDiffCard: View {
    let oldText: String?
    let newText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nativeDiffLines(old: oldText, new: newText).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.kind == .added ? "+" : line.kind == .deleted ? "-" : " ")
                        .frame(width: 12)
                    Text(line.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(NativeChatTheme.codeFont())
                .foregroundStyle(line.kind == .added ? NativeChatTheme.success : line.kind == .deleted ? NativeChatTheme.danger : NativeChatTheme.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
                .background(line.kind == .added ? NativeChatTheme.success.opacity(0.07) : line.kind == .deleted ? NativeChatTheme.danger.opacity(0.07) : .clear)
            }
        }
        .padding(.vertical, 10)
        .background(NativeChatTheme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
