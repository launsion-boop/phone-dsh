// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — safe workspace browser.

import SwiftUI
import QuickLook
import WebKit
import PhoneDSHEngine

struct FilesPage: View {
    @State private var directory: String

    init(directory: String = "", initialPath: String? = nil) {
        _directory = State(initialValue: directory)
        self.initialPath = initialPath
    }

    /// 分组标题只写「手机工作区」或当前那一层文件夹名,不写手机上的整条路径。
    /// 工作区在磁盘上的名字仍是 DSH 的 `default-workspace`,这里只改显示名。
    private var fileGroupTitle: String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "手机工作区" }
        return trimmed.split(separator: "/").last.map(String.init) ?? "手机工作区"
    }
    let initialPath: String?
    @State private var query = ""
    @State private var model = ChatModel.shared
    @State private var selectedFile: WorkspaceFile?
    @State private var didOpenInitialPath = false
    @State private var showingDemo = false

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
            .navigationTitle(directory.isEmpty ? "手机工作区" : String(directory.dropLast()).split(separator: "/").last.map(String.init) ?? "手机工作区")
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
            .sheet(isPresented: $showingDemo) {
                NavigationStack {
                    PDSHPageView(entry: .library(path: "demo/spin.html"),
                                 resolver: FilesPage.demoResolver)
                        .navigationTitle("3D 示例")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { showingDemo = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingDemo = true } label: {
                        Label("3D 示例", systemImage: "cube")
                    }
                    .accessibilityLabel("打开 3D 示例")
                }
            }
    }

    /// The demo is served from the bundled library only; it has no session
    /// workspace, so a `pdsh-page://<session>/` request is refused.
    private static var demoResolver: PDSHPageResolver {
        PDSHPageResolver(
            libraryRoot: Bundle.main.url(forResource: "Web3DLib", withExtension: nil)
                ?? Bundle.main.bundleURL,
            workspaceRoot: { _ in nil })
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
        let canonical = normalized.precomposedStringWithCanonicalMapping
        for candidate in model.files where candidate.relativePath == normalized {
            match = candidate
            break
        }
        if match == nil {
            // The list comes from the materialized tree and the requested path
            // from a tool result; a Chinese name can differ only in Unicode
            // normalization, which is not a missing file.
            match = model.files.first { $0.relativePath.precomposedStringWithCanonicalMapping == canonical }
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
    /// JSON/CSV read the materialized copy directly: the Worker read caps at
    /// 256 KiB / 200 lines and truncated ordinary exports (spec-render-media-v1 §C.2).
    private static let directTextExtensions: Set<String> = ["json", "csv", "tsv"]
    private static let directTextPreviewLimit = 8 * 1024 * 1024

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

    /// `pdsh-page:` roots for this preview: the current session's workspace
    /// plus the bundled Web3DLib.
    private var pageResolver: PDSHPageResolver? {
        guard let library = Bundle.main.url(forResource: "Web3DLib", withExtension: nil) else {
            return nil
        }
        let workspace = ChatModel.shared.workspaceDirectoryURL
        let session = ChatModel.shared.currentSessionID
        return PDSHPageResolver(libraryRoot: library, workspaceRoot: { id in
            id == session ? workspace : nil
        })
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
            } else if isHTML, let resolver = pageResolver,
                      let sessionID = ChatModel.shared.currentSessionID {
                // A real origin: relative scripts, textures and .glb models
                // resolve, with the host-enforced CSP per the page's tier.
                PDSHPageView(entry: .workspace(sessionID: sessionID,
                                               path: file.relativePath),
                             resolver: resolver)
            } else if isHTML {
                ContentUnavailableView("无法打开页面预览", systemImage: "globe",
                                       description: Text("需要先启动一个会话；页面在 pdsh-page:// 源下运行。"))
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
            previewNotice = "页面在本地 pdsh-page:// 源下运行；默认不出网。"
            guard safeFileURL != nil else {
                previewError = "此文件已不在安全的本机工作区快照中。请刷新工作区后重试。"
                return
            }
            return
        }
        // HTML above; JSON/CSV come from the materialized copy (no 256 KiB /
        // 200-line cap). The Worker read stays as the fallback for a file
        // written but not yet materialized.
        if Self.directTextExtensions.contains(ext), let safeFileURL {
            do {
                let data = try Data(contentsOf: safeFileURL)
                textPreview = String(decoding: data.prefix(Self.directTextPreviewLimit),
                                     as: UTF8.self)
                if data.count > Self.directTextPreviewLimit {
                    previewNotice = appendNotice(previewNotice,
                                                 "文本预览限制为 8 MiB；可分享文件后用其他应用打开完整内容。")
                }
                return
            } catch {
                previewError = "读取文件失败：\(error.localizedDescription)"
                return
            }
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
            // This browser listed the file from the durable materialized copy,
            // so a Worker read failure must not claim the file does not exist.
            // Show the on-disk copy and name it as such; a write that is still
            // in flight becomes visible after a workspace refresh.
            if let url = safeFileURL, let data = try? Data(contentsOf: url) {
                textPreview = String(decoding: data.prefix(Self.inlineTextPreviewLimit), as: UTF8.self)
                previewNotice = appendNotice(previewNotice, "当前显示本机物化副本；若刚有写入，请稍后刷新工作区。")
            } else {
                previewError = "读取文件失败：\(error.localizedDescription)"
            }
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

