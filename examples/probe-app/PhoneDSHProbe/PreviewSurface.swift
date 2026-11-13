// SPDX-License-Identifier: MIT
// Native workspace preview: one target, one full-screen surface, one back.

import AVKit
import PDFKit
import PhoneDSHEngine
import QuickLook
import SwiftUI
import UIKit

/// The only preview target in v1. Presentation parameters (line, scroll) are
/// deliberately not part of the identity.
enum PreviewTarget: Identifiable, Hashable {
    case workspaceFile(String)

    var id: String {
        switch self {
        case .workspaceFile(let path): return "workspace:\(path)"
        }
    }

    var path: String {
        switch self {
        case .workspaceFile(let path): return path
        }
    }
}

struct PreviewPresentation: Equatable {
    var line: Int?
    var scroll: CGFloat?
}

/// Shared path resolution: normalization, NFC/NFD, safe workspace root.
enum PreviewPathResolver {
    static func normalize(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["file://", "sandbox:"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        if let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/dsh/workspace/") {
            path = String(path.dropFirst("/dsh/workspace/".count))
        }
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        return path.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func fileURL(for relativePath: String) -> URL? {
        let root = ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .resolvingSymlinksInPath()
        let path = normalize(relativePath)
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        let candidate = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return candidate
    }
}

enum PreviewKind {
    case text, markdown, html, model, webMedia, image, pdf, office, video, audio, unsupported
}

extension URL {
    var previewKind: PreviewKind {
        switch pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        case "glb", "gltf": return .model
        case "gif", "webm", "ogv": return .webMedia
        case "png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "tiff": return .image
        case "pdf": return .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "epub":
            return .office
        case "mp4", "mov", "m4v": return .video
        case "mp3", "m4a", "wav", "aac", "flac": return .audio
        case "txt", "log", "json", "jsonl", "yaml", "yml", "xml", "toml", "ini", "csv", "tsv",
             "mdx", "swift", "m", "mm", "c", "h", "cpp", "hpp", "go", "rs", "py", "js", "jsx",
             "ts", "tsx", "java", "kt", "kts", "gradle", "sh", "zsh", "bash", "fish", "zshrc",
             "css", "scss", "less", "sql", "patch", "diff", "plist", "entitlements", "pbxproj",
             "makefile", "dockerfile", "gitignore", "lock", "conf", "config":
            return .text
        default: return .unsupported
        }
    }
}

@MainActor
@Observable
final class PreviewModel {
    let path: String
    private(set) var file: WorkspaceFile?
    private(set) var fileURL: URL?
    private(set) var kind: PreviewKind = .unsupported
    private(set) var text = ""
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var eof = true
    private(set) var loadedBytes = 0
    private(set) var totalBytes = 0
    private var byteOffset = 0
    private var loadTask: Task<Void, Never>?
    private var retryCount = 0

    private static let pageBytes = 512 * 1024

    init(path: String) {
        self.path = PreviewPathResolver.normalize(path)
        reload()
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true
        error = nil
        notice = nil
        text = ""
        loadedBytes = 0
        byteOffset = 0
        eof = true
        file = ChatModel.shared.fileIndex.file(atPath: path)
            ?? ChatModel.shared.files.first {
                $0.relativePath.precomposedStringWithCanonicalMapping == path.precomposedStringWithCanonicalMapping
            }
        fileURL = PreviewPathResolver.fileURL(for: path)
        kind = fileURL?.previewKind ?? .unsupported
        if kind == .unsupported, let fileURL, Self.looksLikeText(fileURL) {
            kind = .text
        }
        if let size = file?.size {
            totalBytes = size
        } else if let url = fileURL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize {
            totalBytes = size
        } else {
            totalBytes = 0
        }
        guard let fileURL else {
            // A tool can report a path a moment before the bytes land. Retry
            // briefly in place instead of showing a false "missing" error.
            retryCount += 1
            if retryCount <= 12 {
                isLoading = true
                error = nil
                loadTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self.reload()
                }
            } else {
                isLoading = false
                error = "这个文件还在写入，或已不在工作区。等待同步后重试。"
            }
            return
        }
        retryCount = 0
        switch kind {
        case .text, .markdown:
            loadNextTextPage(url: fileURL)
        case .html:
            isLoading = false
            if fileURL.pathExtension.lowercased() == "html" || fileURL.pathExtension.lowercased() == "htm" {
                notice = "页面在本地 pdsh-page:// 源下运行；JavaScript 已启用，外部网络默认关闭。"
            }
        default:
            isLoading = false
        }
    }

    func retry() {
        retryCount = 0
        reload()
    }

    func loadMore() {
        guard !eof, !isLoading, let fileURL else { return }
        loadNextTextPage(url: fileURL)
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) ?? Data(), !data.isEmpty else { return false }
        if data.contains(0) { return false }
        guard String(data: data, encoding: .utf8) != nil else { return false }
        let controls = data.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }
        return controls.count * 100 <= data.count
    }

    private func loadNextTextPage(url: URL) {
        isLoading = true
        let offset = byteOffset
        let pageBytes = Self.pageBytes
        loadTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (text: String, next: Int, eof: Bool) in
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    var data = try handle.read(upToCount: pageBytes) ?? Data()
                    // Never split a multi-byte UTF-8 scalar across pages.
                    while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
                        data.removeLast()
                    }
                    return (String(decoding: data, as: UTF8.self), offset + data.count,
                            data.count < pageBytes)
                }.value
                guard !Task.isCancelled else { return }
                self.text += result.text
                self.byteOffset = result.next
                self.loadedBytes = result.next
                self.eof = result.eof
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.error = "读取文件失败：\(error.localizedDescription)"
            }
        }
    }
}

struct PreviewSurface: View {
    let target: PreviewTarget
    var presentation = PreviewPresentation()
    var isModal = true
    @Environment(\.dismiss) private var dismiss
    @State private var model: PreviewModel
    @State private var webReloadID = UUID()
    @State private var showShare = false
    @State private var player: AVPlayer?
    @State private var pdfDocument: PDFDocument?
    @State private var networkGranted = false

    init(target: PreviewTarget, presentation: PreviewPresentation = .init(), isModal: Bool = true) {
        self.target = target
        self.presentation = presentation
        self.isModal = isModal
        _model = State(initialValue: PreviewModel(path: target.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice, !notice.isEmpty {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            Group {
                if model.isLoading && model.text.isEmpty {
                    ProgressView("正在读取…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error {
                    VStack(spacing: 16) {
                        ContentUnavailableView("无法预览", systemImage: "doc.questionmark",
                                               description: Text(error))
                        Button("重试") { model.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    PreviewSurfaceContent(path: model.path) { body(for: model.kind) }
                }
            }
            if model.isLoading && !model.text.isEmpty {
                ProgressView("正在加载更多…")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .overlay(alignment: .top) { Divider() }
            } else if !model.eof && (model.kind == .text || model.kind == .markdown) {
                Button {
                    model.loadMore()
                } label: {
                    Label("加载更多", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .background(NativePagePalette.page)
        .navigationTitle(URL(fileURLWithPath: model.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.fileURL) {
            // Keep the player and PDF document across view updates (opening
            // Share must not restart audio or reset the PDF scroll position).
            player?.pause()
            player = nil
            pdfDocument = nil
            guard let url = model.fileURL else { return }
            switch model.kind {
            case .video, .audio:
                player = AVPlayer(url: url)
            case .pdf:
                pdfDocument = PDFDocument(url: url)
            default:
                break
            }
        }
        .onChange(of: networkGranted) { _, _ in
            // A CSP is injected with the response; reload to apply the grant.
            webReloadID = UUID()
        }
        .sheet(isPresented: $showShare) {
            if let url = model.fileURL {
                ActivityView(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        .toolbar {
            if isModal {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
            }
            // Full-screen: 完成 owns the trailing side, the page tools lead.
            ToolbarItem(placement: isModal ? .topBarLeading : .primaryAction) {
                HStack(spacing: 16) {
                    if model.kind == .html {
                        Menu {
                            Toggle("允许本次加载外部图片/字体/媒体", isOn: $networkGranted)
                        } label: {
                            Image(systemName: networkGranted ? "network.badge.shield.half.filled" : "network")
                                .foregroundStyle(NativePagePalette.accent)
                        }
                        .accessibilityLabel("网页网络权限")
                        Button {
                            webReloadID = UUID()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("重新加载页面")
                    }
                    if model.fileURL != nil {
                        Button {
                            showShare = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(NativePagePalette.accent)
                        }
                        .accessibilityLabel("分享")
                    }
                }
                .tint(NativePagePalette.accent)
            }
        }
    }

    @ViewBuilder
    private func body(for kind: PreviewKind) -> some View {
        switch kind {
        case .text:
            NativePagedTextView(text: model.text, isLoading: model.isLoading)
        case .markdown:
            ScrollView(.vertical) {
                NativeMarkdownBody(markdown: model.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        case .html:
            htmlBody
        case .model:
            modelBody
        case .webMedia:
            webMediaBody
        case .image:
            imageBody
        case .pdf:
            pdfBody
        case .office:
            officeBody
        case .video, .audio:
            if let player {
                VideoPlayer(player: player)
            } else if model.fileURL != nil {
                ProgressView("准备播放器…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unsupportedBody
            }
        case .unsupported:
            unsupportedBody
        }
    }

    @ViewBuilder
    private var htmlBody: some View {
        if let entry = pageEntry, let resolver = pageResolver {
            PDSHPageView(entry: entry, resolver: resolver)
                .id(webReloadID)
        } else {
            ContentUnavailableView("这个页面不在工作区里", systemImage: "globe",
                                   description: Text("页面预览需要它所属的工作区；散落文件请用文本或分享打开。"))
        }
    }

    private var pageEntry: PDSHPageEntry? {
        if let owner = ChatModel.shared.pageWorkspaceOwner(for: model.path) {
            return .workspace(sessionID: owner.sessionID, path: owner.relativePath)
        }
        // A session can be live before the management list has caught up; its
        // page origin is still the current materialized workspace.
        if let sessionID = ChatModel.shared.currentSessionID {
            return .workspace(sessionID: sessionID, path: model.path)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
            return .workspace(sessionID: "preview-session", path: model.path)
        }
        #endif
        return nil
    }

    @ViewBuilder
    private var modelBody: some View {
        if let owner = ownerSession() {
            let entry = PDSHPageEntry.model(sessionID: owner.sessionID, path: owner.path)
            if let resolver = pageResolver {
                PDSHPageView(entry: entry, resolver: resolver)
            } else {
                unsupportedBody
            }
        } else {
            ContentUnavailableView("这个模型不在工作区里", systemImage: "cube",
                                   description: Text("3D 预览需要文件所属的会话工作区。"))
        }
    }

    @ViewBuilder
    private var webMediaBody: some View {
        if let owner = ownerSession(), let resolver = pageResolver {
            let kind: PDSHWebMediaKind = model.path.lowercased().hasSuffix(".gif") ? .image : .video
            PDSHPageView(entry: .webMedia(sessionID: owner.sessionID, path: owner.path, kind: kind),
                         resolver: resolver)
        } else {
            ContentUnavailableView("这个媒体不在工作区里", systemImage: "photo.on.rectangle",
                                   description: Text("动图/视频预览需要文件所属的会话工作区。"))
        }
    }

    private func ownerSession() -> (sessionID: String, path: String)? {
        if let owner = ChatModel.shared.pageWorkspaceOwner(for: model.path) {
            return (owner.sessionID, owner.relativePath)
        }
        if let sessionID = ChatModel.shared.currentSessionID {
            return (sessionID, model.path)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
            return ("preview-session", model.path)
        }
        #endif
        return nil
    }

    private var pageResolver: PDSHPageResolver? {
        guard let library = Bundle.main.url(forResource: "Web3DLib", withExtension: nil) else { return nil }
        var map = ChatModel.shared.pageWorkspaceMap()
        #if DEBUG
        map["preview-session"] = ChatModel.shared.workspaceDirectoryURL
        #endif
        return PDSHPageResolver(libraryRoot: library,
                                workspaceRoot: { map[$0] },
                                networkAllowed: { _ in networkGranted })
    }

    @ViewBuilder
    private var imageBody: some View {
        if let url = model.fileURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(16)
        } else {
            ContentUnavailableView("无法显示图片", systemImage: "photo",
                                   description: Text("图片格式不受支持，或文件仍在写入。"))
        }
    }

    @ViewBuilder
    private var pdfBody: some View {
        if let pdfDocument {
            PDFKitView(document: pdfDocument)
        } else if model.fileURL != nil {
            ProgressView("正在打开 PDF…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("无法打开 PDF", systemImage: "doc.richtext",
                                   description: Text("文件可能已加密或仍在写入。"))
        }
    }

    @ViewBuilder
    private var officeBody: some View {
        if let url = model.fileURL {
            QuickLookInline(url: url)
        } else {
            unsupportedBody
        }
    }

    private var unsupportedBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("暂时不能预览这个文件")
                .font(.headline)
            Text("可以分享文件，或使用其他 App 打开。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let file = model.file {
                Text("\(file.relativePath) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let url = model.fileURL {
                ShareLink(item: url) {
                    Label("分享文件", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(NativePagePalette.accentFill, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NativePagedTextView: UIViewRepresentable {
    let text: String
    let isLoading: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textColor = UIColor(NativePagePalette.ink)
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct QuickLookInline: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

#if DEBUG
struct PreviewDebugRoute: View {
    let path: String
    let text: String
    @State private var installed = false

    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.install(path: path, text: text)
            }
    }
}

@MainActor
enum PreviewDebugFixtures {
    static func install(path: String, text: String) {
        let root = ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent(path)
            .deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent((path as NSString).lastPathComponent)
        try? text.data(using: .utf8)?.write(to: url)
        ChatModel.shared.refreshFiles()
    }
}
#endif

#if DEBUG
struct PreviewDebugChat: View {
    let path: String
    var body: some View {
        ChatPage(initialPreviewTarget: .workspaceFile(path))
            .task { PreviewDebugFixtures.install(path: path, text: "会话里的文件：直接打开预览。\n关闭后回到会话。\n") }
    }
}

struct PreviewDebugFiles: View {
    let path: String
    var body: some View {
        FilesPage(initialPath: path)
            .task { PreviewDebugFixtures.install(path: path, text: "# 文件页直接预览\n\n一次返回回到文件列表。\n") }
    }
}
#endif

#if DEBUG
struct PreviewDebugLong: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.installLong(path: path)
            }
    }
}

extension PreviewDebugFixtures {
    static func installLong(path: String) {
        var text = ""
        for index in 1...12_000 {
            text += "\(String(format: "%05d", index))  preview line — 分页加载测试 — \(String(repeating: "x", count: 40))\n"
        }
        install(path: path, text: text)
    }
}
#endif

#if DEBUG
struct PreviewDebugPDF: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.installPDF(path: path)
            }
    }
}

struct PreviewDebugImage: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.installImage(path: path)
            }
    }
}

extension PreviewDebugFixtures {
    static func installPDF(path: String) {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            let title = "Phone DSH PDF Preview"
            title.draw(at: CGPoint(x: 48, y: 64), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor.black,
            ])
            "This page is rendered by PDFKit inside the native preview surface."
                .draw(in: CGRect(x: 48, y: 110, width: 500, height: 80), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16),
                    .foregroundColor: UIColor.darkGray,
                ])
        }
        write(data: data, path: path)
    }

    static func installImage(path: String) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 500))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
            "Preview".draw(at: CGPoint(x: 60, y: 200), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.white,
            ])
        }
        if let data = image.pngData() { write(data: data, path: path) }
    }

    private static func write(data: Data, path: String) {
        let root = ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent(path)
            .deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent((path as NSString).lastPathComponent)
        try? data.write(to: url)
        ChatModel.shared.refreshFiles()
    }
}
#endif

#if DEBUG
struct PreviewDebugOffice: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.installOffice(path: path)
            }
    }
}

extension PreviewDebugFixtures {
    static func installOffice(path: String) {
        let rtf = #"{\rtf1\ansi\ansicpg1252\cocoartf2761{\fonttbl\f0\fswiss\fcharset0 Helvetica;}\f0\fs36 \cf2 Phone DSH Office Preview\par \fs24 This RTF file is opened by Quick Look inside the native preview surface.\par}"#
        install(path: path, text: rtf)
    }
}
#endif

#if DEBUG
struct PreviewDebugAudio: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.installAudio(path: path)
            }
    }
}

extension PreviewDebugFixtures {
    /// A tiny 440 Hz PCM WAV, enough to exercise the AVKit branch without a
    /// binary asset in the repository.
    static func installAudio(path: String) {
        let sampleRate = 22_050
        let seconds = 2
        let sampleCount = sampleRate * seconds
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataBytes = sampleCount * 2
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(dataBytes))
        for index in 0..<sampleCount {
            let sample = sin(2 * .pi * 440 * Double(index) / Double(sampleRate))
            appendLE(Int16(sample * 8_000))
        }
        write(data: data, path: path)
    }
}
#endif

#if DEBUG
struct PreviewDebug3D: View {
    let path: String
    @State private var installed = false
    var body: some View {
        PreviewSurface(target: .workspaceFile(path), isModal: false)
            .task {
                guard !installed else { return }
                installed = true
                PreviewDebugFixtures.install3D(path: path)
            }
    }
}

extension PreviewDebugFixtures {
    static func install3D(path: String) {
        guard let library = Bundle.main.url(forResource: "Web3DLib", withExtension: nil) else { return }
        let source = library.appendingPathComponent("demo/cube.glb")
        guard let data = try? Data(contentsOf: source) else { return }
        let root = ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent(path)
            .deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appendingPathComponent((path as NSString).lastPathComponent))
        ChatModel.shared.refreshFiles()
    }
}
#endif

/// A device panel descriptor opens as the panel it describes, with one tap to
/// adopt it, not as raw JSON (device-panel.md §4.1). Every other file keeps the
/// kind-specific body.
private struct PreviewSurfaceContent<Fallback: View>: View {
    let path: String
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if DevicePanelDescriptorPreview.handles(path) {
            DevicePanelDescriptorPreview(path: path)
        } else {
            fallback()
        }
    }
}
