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
        guard !trimmed.isEmpty else { return NativeText("手机工作区", "Phone Workspace") }
        return trimmed.split(separator: "/").last.map(String.init) ?? NativeText("手机工作区", "Phone Workspace")
    }
    let initialPath: String?
    @State private var query = ""
    @State private var model = ChatModel.shared
    @State private var previewTarget: PreviewTarget?
    @State private var didOpenInitialPath = false
    @State private var showingDemo = false

    private var children: [WorkspaceFile] {
        model.fileIndex.orderedFiles.filter { file in
            guard file.relativePath.hasPrefix(directory) else { return false }
            let tail = String(file.relativePath.dropFirst(directory.count))
            return query.isEmpty ? !tail.contains("/") : tail.localizedCaseInsensitiveContains(query)
        }
    }

    private var folders: [String] {
        guard query.isEmpty else { return [] }
        return Set(model.fileIndex.orderedFiles.compactMap { file -> String? in
            guard file.relativePath.hasPrefix(directory) else { return nil }
            let tail = String(file.relativePath.dropFirst(directory.count))
            guard let slash = tail.firstIndex(of: "/") else { return nil }
            return String(tail[..<slash])
        }).sorted()
    }

    var body: some View {
        fileList
            .navigationTitle(directory.isEmpty ? NativeText("手机工作区", "Phone Workspace") : String(directory.dropLast()).split(separator: "/").last.map(String.init) ?? NativeText("手机工作区", "Phone Workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .homeGroupedList()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: NativeText("搜索文件", "Search files"))
            .refreshable { await model.refreshFilesAndWait() }
            .task { await openInitialPathIfNeeded() }
            .navigationDestination(item: $previewTarget) { target in
                PreviewSurface(target: target, isModal: false)
            }
            .sheet(isPresented: $showingDemo) {
                NavigationStack {
                    PDSHPageView(entry: .library(path: "demo/spin.html"),
                                 resolver: FilesPage.demoResolver)
                        .navigationTitle(NativeText("3D 示例", "3D Example"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(NativeText("完成", "Done")) { showingDemo = false }.fontWeight(.semibold)
                            }
                        }
                }
                .homeSheetChrome()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingDemo = true } label: {
                        Label(NativeText("3D 示例", "3D Example"), systemImage: "cube")
                    }
                    .accessibilityLabel(NativeText("打开 3D 示例", "Open 3D example"))
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
                    Text(NativeText("还没有文件", "No Files Yet"))
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    Text(NativeText("智能体做的文件会出现在这里。", "Files created by the agent appear here."))
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
                            previewTarget = .workspaceFile(file.relativePath)
                        } label: {
                            FileRow(file: file)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(NativeText("预览或分享此工作区文件", "Preview or share this workspace file"))
                    }
                }
            }
        }
        .homeGroupedList()
    }

    /// Opens the requested file once: lands in its folder and presents it.
    private func openInitialPathIfNeeded() async {
        await model.refreshFilesAndWait()
        guard !didOpenInitialPath, let initialPath else { return }
        didOpenInitialPath = true
        let normalized = ChatPage.normalizedWorkspacePath(initialPath)
        if let slashIndex = normalized.lastIndex(of: "/") {
            directory = String(normalized[..<slashIndex]) + "/"
        }
        var match: WorkspaceFile?
        let canonical = normalized.precomposedStringWithCanonicalMapping
        match = model.fileIndex.file(atPath: normalized)
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
            previewTarget = .workspaceFile(match.relativePath)
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
            FileTypeGlyph.icon(for: file.relativePath, size: 24)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: file.relativePath).lastPathComponent)
                    .font(.system(size: HomeSpec.bodySize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let folder = folderName {
                    Text(folder)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
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

}
