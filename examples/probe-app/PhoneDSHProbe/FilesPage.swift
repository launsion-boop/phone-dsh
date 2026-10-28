// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — safe workspace browser.

import SwiftUI
import QuickLook
import WebKit

struct FilesPage: View {
    @State private var directory: String

    init(directory: String = "", initialPath: String? = nil) {
        _directory = State(initialValue: directory)
        self.initialPath = initialPath
    }

    /// 分组标题只写「工作文件夹」或当前那一层文件夹名,不写手机上的整条路径。
    private var fileGroupTitle: String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "工作文件夹" }
        return trimmed.split(separator: "/").last.map(String.init) ?? "工作文件夹"
    }
    let initialPath: String?
    @State private var query = ""
    @State private var model = ChatModel.shared
    @State private var selectedFile: WorkspaceFile?
    @State private var didOpenInitialPath = false

    private var children: [WorkspaceFile] {
        model.files.filter { file in
            guard file.relativePath.hasPrefix(directory) else { return false }
            let tail = String(file.relativePath.dropFirst(directory.count))
            return query.isEmpty ? !tail.contains("/") : tail.localizedCaseInsensitiveContains(query)
        }
    }

    private var folders: [String] {
        guard query.isEmpty else { return [] }
        return Set(model.files.compactMap { file -> String? in
            guard file.relativePath.hasPrefix(directory) else { return nil }
            let tail = String(file.relativePath.dropFirst(directory.count))
            guard let slash = tail.firstIndex(of: "/") else { return nil }
            return String(tail[..<slash])
        }).sorted()
    }

    var body: some View {
        fileList
            .navigationTitle(directory.isEmpty ? "文件" : String(directory.dropLast()).split(separator: "/").last.map(String.init) ?? "文件")
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.white)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文件")
            .refreshable { model.refreshFiles() }
            .task { await openInitialPathIfNeeded() }
            .sheet(item: $selectedFile) { file in
                NavigationStack {
                    FilePreviewPage(file: file, workspaceRoot: model.workspaceRoot)
                }
                .presentationDragIndicator(.visible)
            }
    }

    /// Kept out of `body`: the grouped list expression alone is too large for
    /// the type checker once the row buttons and folders are inlined.
    private var fileList: some View {
        List {
            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有文件")
                        .font(.system(size: 17, weight: .semibold))
                    Text("智能体做的文件会出现在这里。")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
            } else {
                Section(fileGroupTitle) {
                    ForEach(folders, id: \.self) { folder in
                        NavigationLink {
                            FilesPage(directory: directory + folder + "/")
                        } label: {
                            Label(folder, systemImage: "folder")
                                .frame(minHeight: 44)
                        }
                    }
                    ForEach(children) { file in
                        Button {
                            // Always open the preview page: it either shows the
                            // file, Quick Look, or says why it cannot, instead
                            // of a tap that silently does nothing.
                            selectedFile = file
                        } label: {
                            FileRow(file: file)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("预览或分享此工作区文件")
                    }
                }
            }
        }
    }

    /// Opens the requested file once: lands in its folder and presents it.
    private func openInitialPathIfNeeded() async {
        model.refreshFiles()
        guard !didOpenInitialPath, let initialPath else { return }
        didOpenInitialPath = true
        let normalized = ChatPage.normalizedWorkspacePath(initialPath)
        if let slashIndex = normalized.lastIndex(of: "/") {
            directory = String(normalized[..<slashIndex]) + "/"
        }
        var match: WorkspaceFile?
        for candidate in model.files where candidate.relativePath == normalized {
            match = candidate
            break
        }
        if match == nil {
            match = ChatPage.uniqueBasenameMatch(normalized, in: model.files)
        }
        if let match {
            selectedFile = match
        }
    }

    private static func safeURL(for file: WorkspaceFile, model: ChatModel) -> URL? {
        let root = model.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .resolvingSymlinksInPath()
        guard !file.relativePath.hasPrefix("/"),
              !file.relativePath.split(separator: "/").contains("..") else { return nil }
        let candidate = root.appendingPathComponent(file.relativePath).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return candidate
    }
}

private struct FileRow: View {
    let file: WorkspaceFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: file.relativePath).lastPathComponent)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let folder = folderName {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    /// 只露所在文件夹的名字,整条相对路径一个字符都不上屏。
    private var folderName: String? {
        let parent = URL(fileURLWithPath: file.relativePath).deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != ".", parent != "/" else { return nil }
        return parent
    }

    private var icon: String {
        let ext = URL(fileURLWithPath: file.relativePath).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext) { return "photo" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        if ["zip", "tar", "gz"].contains(ext) { return "archivebox" }
        return "doc.text"
    }
}

private struct FilePreviewPage: View {
    /// App-side rendering budget after the host has applied its own page caps.
    private static let inlineTextPreviewLimit = 256 * 1024
    private static let inlineTextPreviewLines = 200

    let file: WorkspaceFile
    let workspaceRoot: URL
    @Environment(\.dismiss) private var dismiss
    @State private var quickLookURL: URL?
    @State private var textPreview: String?
    @State private var previewError: String?
    @State private var isHTML = false
    @State private var isMarkdown = false
    @State private var previewNotice: String?

    private var workspaceURL: URL {
        workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// Reject absolute paths and `..` components before offering any file operation.
    private var safeFileURL: URL? {
        let root = workspaceURL
        guard !file.relativePath.hasPrefix("/"),
              !file.relativePath.split(separator: "/").contains("..") else { return nil }
        let candidate = root.appendingPathComponent(file.relativePath).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return candidate
    }

    private var needsQuickLook: Bool {
        let ext = URL(fileURLWithPath: file.relativePath).pathExtension.lowercased()
        return !["txt", "md", "markdown", "json", "yaml", "yml", "xml", "html", "htm", "csv", "tsv", "log",
                 "swift", "py", "js", "ts", "sh", "toml", "ini", "patch", "diff", "css", "c", "h", "go", "rs"].contains(ext)
    }

    var body: some View {
        Group {
            if quickLookURL != nil {
                ContentUnavailableView("正在打开预览…", systemImage: "doc.viewfinder")
            } else if isHTML, let textPreview {
                IsolatedHTMLPreview(html: textPreview)
            } else if isMarkdown, let textPreview {
                ScrollView(.vertical) { NativeMarkdownBody(markdown: textPreview) }
            } else if let textPreview {
                ScrollView([.vertical, .horizontal]) {
                    Text(textPreview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView("这个文件已经不在了。", systemImage: "doc.questionmark",
                                       description: Text(previewError ?? "请使用分享功能打开此文件。"))
            }
        }
        .navigationTitle(URL(fileURLWithPath: file.relativePath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }.leadingBarText()
            }
            ToolbarItem(placement: .primaryAction) {
                if let url = safeFileURL {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享文件")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let previewNotice {
                Text(previewNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            } else if safeFileURL == nil {
                Text("此文件已不在工作区中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .quickLookPreview($quickLookURL)
        .task { await loadPreview() }
    }

    private func loadPreview() async {
        guard let sessionID = ChatModel.shared.currentSessionID else {
            previewError = "没有当前会话，无法读取会话工作区。"
            return
        }
        let ext = URL(fileURLWithPath: file.relativePath).pathExtension.lowercased()
        isHTML = ["html", "htm"].contains(ext)
        isMarkdown = ["md", "markdown"].contains(ext)
        if isHTML {
            previewNotice = "此预览允许页面内脚本；网络请求、外部资源、文件访问与宿主桥均被禁用。"
        }
        if needsQuickLook {
            guard let safeFileURL else {
                previewError = "此文件已不在安全的本机工作区快照中。请刷新工作区后重试。"
                return
            }
            // Quick Look streams the bounded, path-checked file URL; avoid
            // copying large PDFs, Office files, archives or images into Data.
            quickLookURL = safeFileURL
            return
        }
        do {
            let transport = try await ChatModel.shared.transportForManagement()
            let response = try await transport.call("workspaceFiles/read", args: .object([
                "workspaceFileScopeId": .string(sessionID),
                "path": .string(file.relativePath),
                "range": .object(["offset": .number(1), "limit": .number(Double(Self.inlineTextPreviewLines))])
            ]))
            let received = response["text"]?.stringValue ?? ""
            let capped = Self.utf8Prefix(received, byteLimit: Self.inlineTextPreviewLimit)
            textPreview = capped.text
            if !capped.complete {
                previewNotice = appendNotice(previewNotice, "文本预览限制为 256 KiB。可分享文件后用其他应用打开完整内容。")
            }
            if response["eof"]?.boolValue == false {
                previewNotice = appendNotice(previewNotice, "仅显示前 \(Self.inlineTextPreviewLines) 行；可继续使用分享功能打开完整文件。")
            }
        } catch {
            previewError = "读取文件失败：\(error.localizedDescription)"
        }
    }

    private func appendNotice(_ current: String?, _ next: String) -> String {
        guard let current, !current.isEmpty else { return next }
        return current + " " + next
    }

    private static func utf8Prefix(_ text: String, byteLimit: Int) -> (text: String, complete: Bool) {
        var scalars = String.UnicodeScalarView()
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard usedBytes + scalarBytes <= byteLimit else { return (String(scalars), false) }
            scalars.append(scalar)
            usedBytes += scalarBytes
        }
        return (String(scalars), true)
    }
}

/// HTML runs only its own inline page code inside an ephemeral WebKit view.
/// It has no native message bridge, file access, network access or navigation.
private struct IsolatedHTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isInspectable = false
        view.scrollView.isScrollEnabled = true
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let policy = "default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let safe = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" + html
        view.loadHTMLString(safe, baseURL: URL(string: "about:blank"))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
