// SPDX-License-Identifier: MIT

import ProbeKit
import QuickLook
import SwiftUI

struct SessionArtifactsPage: View {
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var model = ChatModel.shared
    @State private var artifacts: [OfficeArtifactRef] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var openingID: String?
    @State private var openError: String?
    @State private var preview: SessionArtifactPreview?

    private var currentArtifactIDs: Set<String> {
        guard model.currentSessionID == sessionID else { return [] }
        return SessionArtifactAttribution.generatedArtifactIDs(in: model.items)
    }

    private var sessionArtifacts: [OfficeArtifactRef] {
        artifacts.filter { currentArtifactIDs.contains($0.artifactID) }
    }

    private var unassignedArtifacts: [OfficeArtifactRef] {
        artifacts.filter { !currentArtifactIDs.contains($0.artifactID) }
    }

    var body: some View {
        List {
            if isLoading && artifacts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取产物…")
                        .foregroundStyle(ChatPage.inkSecondary)
                }
                .frame(minHeight: 44)
                .listRowSeparator(.hidden)
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(ChatPage.danger)
                    Button("重试") { Task { await loadArtifacts() } }
                        .foregroundStyle(ChatPage.accent)
                        .frame(minHeight: 44)
                }
            }

            if sessionArtifacts.isEmpty && !isLoading {
                Section {
                    VStack(spacing: 8) {
                        Text("本 session 还没有已确认归属的产物")
                            .font(.system(size: 17, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("此会话生成或导入的文件会显示在这里。没有真实会话来源的记录不会被归入本 session。")
                            .font(.system(size: 13))
                            .foregroundStyle(ChatPage.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                }
            } else if !sessionArtifacts.isEmpty {
                Section("本 session") {
                    ForEach(sessionArtifacts, id: \.artifactID) { artifact in
                        artifactRow(artifact, unassigned: false)
                    }
                }
            }

            if !unassignedArtifacts.isEmpty {
                Section {
                    ForEach(unassignedArtifacts, id: \.artifactID) { artifact in
                        artifactRow(artifact, unassigned: true)
                    }
                } header: {
                    Text("未归属")
                } footer: {
                    Text("这些记录没有当前会话的真实来源信息，不计为本 session 产物。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("本 session 产物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }.leadingBarText()
            }
        }
        .task(id: currentArtifactIDs) { await loadArtifacts() }
        .refreshable { await loadArtifacts() }
        .navigationDestination(item: $preview) { item in
            SessionArtifactPreviewPage(preview: item)
        }
        .alert("无法打开产物", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("好", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    private func artifactRow(_ artifact: OfficeArtifactRef, unassigned: Bool) -> some View {
        Button {
            Task { await open(artifact) }
        } label: {
            HStack(spacing: 12) {
                FileTypeGlyph.icon(for: artifact.name, size: 24)
                    .frame(width: 34, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if unassigned {
                        Text("未归属")
                            .font(.caption2)
                            .foregroundStyle(ChatPage.inkSecondary)
                    }
                }
                Spacer(minLength: 8)
                if openingID == artifact.artifactID {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(openingID != nil)
        .accessibilityHint(unassigned ? "预览未归属产物" : "预览本 session 产物")
    }

    private func loadArtifacts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var loaded: [OfficeArtifactRef] = []
            var cursor = 0
            while true {
                let page = try await OfficeArtifactStore.shared.list(cursor: cursor, limit: OfficeLimits.maximumPageItems)
                loaded.append(contentsOf: page.items)
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            artifacts = loaded
            loadError = nil
        } catch {
            loadError = "无法读取产物：\(error.localizedDescription)"
        }
    }

    private func open(_ artifact: OfficeArtifactRef) async {
        guard openingID == nil else { return }
        openingID = artifact.artifactID
        defer { openingID = nil }
        do {
            let url = try await OfficeArtifactStore.shared.fileURL(for: artifact.artifactID)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw NSError(domain: "SessionArtifactsPage", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "文件已不在本机产物存储中。",
                ])
            }
            preview = SessionArtifactPreview(artifact: artifact, url: url)
        } catch {
            openError = error.localizedDescription
        }
    }
}

enum SessionArtifactAttribution {
    private static let producingTools: Set<String> = [
        "doc.write", "sheet.write", "slides.write", "chart.render", "files.pick", "mail.compose_draft",
    ]

    static func generatedArtifactIDs(in items: [ChatItem]) -> Set<String> {
        var result: Set<String> = []
        for item in items {
            guard item.toolState == .ok, producingTool(for: item) != nil,
                  let output = item.toolOutput ?? (item.text.isEmpty ? nil : item.text),
                  let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectArtifactIDs(in: json, into: &result)
        }
        return result
    }

    private static func producingTool(for item: ChatItem) -> String? {
        guard let rawName = item.toolName else { return nil }
        let directName = rawName.hasPrefix("phone.") ? String(rawName.dropFirst("phone.".count)) : rawName
        if producingTools.contains(directName) { return directName }
        if rawName == "phone", let name = item.arguments?["name"]?.stringValue {
            return producingTools.contains(name) ? name : nil
        }
        guard ["bash", "shell"].contains(rawName),
              let command = item.arguments?["command"]?.stringValue else { return nil }
        let invocations = phoneInvocations(in: command)
        // A mixed shell output cannot prove which phone call produced each ID.
        guard invocations.count == 1, let name = invocations.first,
              producingTools.contains(name) else { return nil }
        return name
    }

    private static func phoneInvocations(in command: String) -> [String] {
        var segments: [String] = []
        var segment = ""
        var quote: Character?
        var escaped = false
        func endSegment() {
            segments.append(segment)
            segment = ""
        }
        for character in command {
            if escaped {
                segment.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                segment.append(character)
                escaped = true
                continue
            }
            if let activeQuote = quote {
                segment.append(character)
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                segment.append(character)
            } else if character == ";" || character == "&" || character == "|" || character.isNewline {
                endSegment()
            } else {
                segment.append(character)
            }
        }
        endSegment()
        return segments.compactMap { segment in
            let tokens = segment.split(whereSeparator: { $0.isWhitespace })
            guard tokens.first == "phone" else { return nil }
            return tokens.count > 1 ? String(tokens[1]) : ""
        }
    }

    private static func collectArtifactIDs(in value: Any, into result: inout Set<String>) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "fileId", let id = child as? String,
                   id.hasPrefix("art_"), id.count <= 128 {
                    result.insert(id)
                } else {
                    collectArtifactIDs(in: child, into: &result)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectArtifactIDs(in: child, into: &result) }
        }
    }
}

private struct SessionArtifactPreview: Identifiable, Hashable {
    let artifact: OfficeArtifactRef
    let url: URL
    var id: String { artifact.artifactID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
    }
}

private struct SessionArtifactPreviewPage: View {
    let preview: SessionArtifactPreview

    var body: some View {
        Group {
            if QLPreviewController.canPreview(preview.url as NSURL) {
                SessionArtifactQuickLook(url: preview.url)
            } else {
                ContentUnavailableView("此文件无法预览", systemImage: "doc.questionmark",
                                       description: Text("可通过系统分享用其他应用打开。"))
            }
        }
        .navigationTitle(preview.artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: preview.url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("分享文件")
            }
        }
    }
}

private struct SessionArtifactQuickLook: UIViewControllerRepresentable {
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

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
