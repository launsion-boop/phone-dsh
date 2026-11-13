// SPDX-License-Identifier: MIT

import PhoneDSHBot
import SwiftUI

/// Whether a card path can be opened by the host's native preview.
///
/// The path namespace is the App preview namespace that
/// `PreviewPathResolver` already owns: `/dsh/workspace/...` (the Worker VFS
/// path the Bot tool result returns) or a path relative to that mount. A card
/// never has to guess whether it holds a host path or a VFS path, and a path
/// outside the workspace is not silently treated as one.
enum BotCardFileAccess {
    @MainActor
    static func canOpen(_ rawPath: String) -> Bool {
        !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && PreviewPathResolver.fileURL(for: rawPath) != nil
    }
}

/// The native full-screen preview for a card attachment.
///
/// This is the same surface the file browser uses, so text, Markdown, images,
/// PDF, office documents and media all get one implementation. A file that is
/// gone, still materializing or outside the workspace shows the surface's
/// explicit error/retry instead of a dead card button.
struct BotFilePreviewSheet: View {
    let target: PreviewTarget

    var body: some View {
        NavigationStack {
            PreviewSurface(target: target)
        }
        .homeSheetChrome()
    }
}

/// The document card's sheet.
///
/// `content` is the preferred source: the payload already carries the markdown
/// and rendering it must not depend on the file being readable. When only
/// `path` is present, the file is read through the same resolver the file
/// browser uses, bounded to 256 KiB, with an explicit truncation notice and an
/// explicit error instead of the old empty page.
struct BotDocumentPreview: View {
    let row: BotUIRow
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePreview = false

    private var title: String {
        row.body.string("title", "name", "fileName") ?? "文档"
    }
    private var summary: String? {
        let value = row.body.string("summary", "description")
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }
    private var content: String? {
        guard let value = row.body.string("content", "markdown"),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private var path: String? {
        guard let value = row.body.string("path", "url"),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Group {
                if let content {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            NativeMarkdownBody(markdown: content)
                        }
                        .padding(HomeSpec.contentInset)
                    }
                } else if let path {
                    BotDocumentFileBody(path: path, title: title, summary: summary)
                } else {
                    ContentUnavailableView(
                        "没有可预览的内容",
                        systemImage: "doc.questionmark",
                        description: Text("这张文档卡既没有内嵌正文，也没有文件路径。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HomeSpec.page)
            .navigationTitle("文档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if path != nil, content != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("打开文件") { showFilePreview = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showFilePreview) {
                if let path { BotFilePreviewSheet(target: .workspaceFile(path)) }
            }
        }
        .homeSheetChrome()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .botTitleFont()
                .foregroundStyle(HomeSpec.textPrimary)
            if let summary {
                Text(summary)
                    .botBodyFont()
                    .foregroundStyle(HomeSpec.textSecondary)
            }
        }
    }
}

/// The path-only document body: resolve → bounded read → markdown/text.
///
/// The resolver and the reader are separate authorities: the App maps the VFS
/// path to the materialized workspace, and `BotDocumentFileReader` owns the
/// 256 KiB/UTF-8 rules. This view only decides what to show for each outcome.
private struct BotDocumentFileBody: View {
    let path: String
    let title: String
    let summary: String?

    @State private var phase: Phase = .loading
    @State private var text = ""
    @State private var truncated = false
    @State private var byteCount = 0
    @State private var rendersMarkdown = false
    @State private var errorMessage: String?
    @State private var showFullPreview = false

    private enum Phase: Equatable {
        case loading, text, binary, failed
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                textBody
            case .binary:
                binaryBody
            case .failed:
                failureBody
            }
        }
        .task(id: path) { await load() }
        .sheet(isPresented: $showFullPreview) {
            BotFilePreviewSheet(target: .workspaceFile(path))
        }
    }

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .botTitleFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                if let summary {
                    Text(summary)
                        .botBodyFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                if truncated {
                    Label("文件较大，仅显示前 256 KiB（共 \(sizeLabel(byteCount))）。",
                          systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(HomeSpec.textSecondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if rendersMarkdown {
                ScrollView {
                    NativeMarkdownBody(markdown: text)
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.bottom, 24)
                }
            } else {
                NativePagedTextView(text: text, isLoading: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if truncated {
                Button {
                    showFullPreview = true
                } label: {
                    Label("用系统预览打开完整文件", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private var binaryBody: some View {
        ContentUnavailableView {
            Label("不是文本文件", systemImage: "doc")
        } description: {
            Text("\(title) 不能用文档正文渲染；请用系统预览打开。")
        } actions: {
            Button("打开文件预览") { showFullPreview = true }
                .buttonStyle(.borderedProminent)
            Button("重新读取") { Task { await load() } }
        }
    }

    private var failureBody: some View {
        ContentUnavailableView {
            Label("无法打开文档", systemImage: "doc.questionmark")
        } description: {
            Text(errorMessage ?? "读取文件失败。")
        } actions: {
            Button("重试") { Task { await load() } }
                .buttonStyle(.borderedProminent)
            Button("用系统预览打开") { showFullPreview = true }
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        errorMessage = nil
        text = ""
        truncated = false
        guard let url = PreviewPathResolver.fileURL(for: path) else {
            errorMessage = "文件不在工作区，或还没有同步到本机。\n\(path)"
            phase = .failed
            return
        }
        switch url.previewKind {
        case .markdown, .text:
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BotDocumentFileReader.readText(at: url)
                }.value
                text = result.text
                truncated = result.truncated
                byteCount = result.byteCount
                rendersMarkdown = url.previewKind == .markdown
                phase = .text
            } catch let error as BotDocumentFileReadError {
                errorMessage = "读取失败：\(error.localizedDescription)\n\(url.path)"
                phase = .failed
            } catch {
                errorMessage = "读取失败：\(error.localizedDescription)"
                phase = .failed
            }
        default:
            phase = .binary
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
