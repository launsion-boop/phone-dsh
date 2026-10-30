// SPDX-License-Identifier: MIT

import SwiftUI

struct NativeChangedFilesCard: View {
    let changes: NativeChangedFiles
    var onOpenFile: (String) -> Void
    @State private var expanded = false

    private var single: NativeChangedFile? { changes.files.count == 1 ? changes.files[0] : nil }
    private var visibleFiles: [NativeChangedFile] {
        expanded ? changes.files : Array(changes.files.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onOpenFile(changes.files[0].path) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(NativeChatTheme.input)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(NativeChatTheme.border, lineWidth: 0.5)
                        Group {
                            if let single { FileTypeGlyph.icon(for: single.path, size: 20) }
                            else { FileTypeGlyph.icon(for: "Sources/code.swift", size: 20) }
                        }
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(single.map { "已编辑 \($0.path.split(separator: "/").last.map(String.init) ?? $0.path)" }
                            ?? "已编辑 \(changes.files.count) 个文件")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NativeChatTheme.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("+\(changes.added)").foregroundStyle(NativeChatTheme.success)
                            Text("-\(changes.deleted)").foregroundStyle(NativeChatTheme.danger)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(height: 60)
                .background(NativeChatTheme.selector)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if single == nil {
                Divider().overlay(NativeChatTheme.border)
                ForEach(visibleFiles) { file in
                    Button { onOpenFile(file.path) } label: {
                        HStack(spacing: 10) {
                            Text(file.display)
                                .font(.system(size: 12))
                                .foregroundStyle(NativeChatTheme.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            HStack(spacing: 6) {
                                Text("+\(file.added)").foregroundStyle(NativeChatTheme.success)
                                Text("-\(file.deleted)").foregroundStyle(NativeChatTheme.danger)
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if changes.files.count > 4 {
                    Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起" : "全部 \(changes.files.count) 个文件")
                            NativeChatIcon(name: .chevronDown, size: 14)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(NativeChatTheme.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(NativeChatTheme.input)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(NativeChatTheme.border, lineWidth: 0.5))
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}
