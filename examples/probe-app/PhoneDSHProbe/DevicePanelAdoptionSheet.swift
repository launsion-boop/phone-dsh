// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native adoption sheet for a device panel descriptor
// (device-panel.md §4.1).
//
// This file is app-only: it reads the workspace through `ChatModel.shared`.
// It is deliberately outside every WebView. Nothing here calls a device tool;
// the only device-adjacent action is the host-private descriptor copy through
// `DevicePanelModel` → `DevicePanelStore`.
//
// The model writes descriptors to the workspace convention
// `device-panels/<link-device-id>.json`. The name is a convention only: the
// evaluation below uses the file bytes, never the file name.

import Foundation
import SwiftUI
import PhoneDSHBLE

@MainActor
struct DevicePanelAdoptionSheet: View {
    let model: DevicePanelModel

    @State private var files: [WorkspaceFile] = []
    @State private var selectedPath: String?
    @State private var bytes: Data?
    @State private var review: DevicePanelDescriptorReview?
    @State private var readError: String?
    @State private var refreshing = false
    @State private var adopting = false
    @State private var adoptOutcome: DevicePanelDescriptorResult?
    @State private var adoptError: String?
    @State private var showRemoveConfirmation = false
    @State private var removeError: String?

    var body: some View {
        List {
            activeDescriptorSection
            workspaceSection
            if let readError {
                Section("读取失败") {
                    Text(verbatim: readError).font(.footnote).foregroundStyle(.red).lineLimit(4)
                }
            }
            if let review {
                reviewSection(review)
            }
            adoptOutcomeSection
            readmeSection
        }
        .homeGroupedList()
        .task {
            // Local reads only: the adopted copy and the current workspace file
            // snapshot. The workspace scan itself is manual (刷新).
            model.refresh()
            reloadFileList()
        }
        .confirmationDialog("移除已采用的描述？", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("移除描述", role: .destructive) {
                Task {
                    let removed = await model.removeDescriptor()
                    removeError = removed ? nil : (model.errorText ?? "移除失败")
                    if removed { adoptOutcome = nil }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("面板会回到设备自报的工具列表。工作区里的文件不会被改动。")
        }
    }

    // MARK: Active descriptor

    @ViewBuilder
    private var activeDescriptorSection: some View {
        if model.hasAdoptedDescriptor {
            Section("当前已采用的描述") {
                if let descriptor = model.descriptor {
                    Text(verbatim: descriptor.title ?? "未命名描述")
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        .lineLimit(2)
                    Text(verbatim: "显示 \(descriptor.controls.count) 个控件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let result = model.adoptedDescriptorResult {
                    Text(verbatim: "当前不生效：\(DevicePanelPage.descriptorReason(result))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Text("面板已经回到设备自报的工具列表。描述副本仍保留，工具表恢复后可能重新生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let removeError {
                    Text(verbatim: removeError).font(.footnote).foregroundStyle(.red).lineLimit(4)
                }
                Button("移除描述", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .accessibilityIdentifier("device-panel-remove-descriptor")
            }
        }
    }

    // MARK: Workspace file list

    private var workspaceSection: some View {
        Section {
            if files.isEmpty {
                Text("工作区 device-panels/ 下没有 .json 文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    Button {
                        select(file)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: file.relativePath)
                                    .lineLimit(1)
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size),
                                                                         countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if selectedPath == file.relativePath {
                                Image(systemName: "checkmark")
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("device-panel-descriptor-file")
                }
            }
            Button {
                Task { await refreshFiles() }
            } label: {
                if refreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在刷新工作区…")
                    }
                } else {
                    Text("刷新文件列表")
                }
            }
            .disabled(refreshing)
            .accessibilityIdentifier("device-panel-refresh-files")
        } header: {
            Text("工作区里的描述文件")
        } footer: {
            Text("模型应把描述写到 device-panels/<Link device ID>.json。文件名只是约定，采用时以文件内容为准。这里不会自动扫描，点「刷新文件列表」才会重新读取工作区。")
        }
    }

    // MARK: Review

    @ViewBuilder
    private func reviewSection(_ review: DevicePanelDescriptorReview) -> some View {
        Section {
            HStack {
                Text("求值结果")
                Spacer()
                Text(verbatim: review.result.rawValue)
                    .font(.system(.footnote, design: .monospaced))
            }
            if review.isOK, let descriptor = review.descriptor {
                if let title = descriptor.title {
                    Text(verbatim: title)
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        .lineLimit(2)
                }
                ForEach(Array(descriptor.controls.enumerated()), id: \.offset) { _, control in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: control.label)
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                            .lineLimit(2)
                        Text(verbatim: "调用的工具：\(control.tool)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let group = control.group {
                            Text(verbatim: "分组：\(group)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let preset = control.preset {
                            Text("完整预设参数")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: DevicePanelJSONText.pretty(preset))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text("无预设：使用这个工具的参数编辑器，未设置的参数不会发送。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text(verbatim: DevicePanelPage.descriptorReason(review.result))
                    .font(.footnote)
                    .foregroundStyle(.red)
                if model.hasAdoptedDescriptor {
                    Text("此前已采用的描述保持不变。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("描述预览")
        } footer: {
            if review.isOK {
                Text("确认后才会写入宿主私有副本。采用描述不会授权任何工具，也不会批准 home.http 的 origin；控件仍受设备当前授权约束。")
            }
        }
    }

    @ViewBuilder
    private var adoptOutcomeSection: some View {
        if let adoptOutcome {
            Section("采用结果") {
                if adoptOutcome == .ok {
                    Text("已采用。面板会按这份描述显示。")
                        .font(.footnote)
                        .foregroundStyle(HomeSpec.success)
                } else {
                    Text(verbatim: "采用被拒绝：\(DevicePanelPage.descriptorReason(adoptOutcome))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Text("此前已采用的描述保持不变。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let adoptError {
            Section("采用失败") {
                Text(verbatim: adoptError).font(.footnote).foregroundStyle(.red).lineLimit(4)
            }
        }
        if review?.isOK == true, bytes != nil {
            Section {
                Button {
                    adopt()
                } label: {
                    if adopting {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("正在采用…")
                        }
                    } else {
                        Text("采用这份描述")
                    }
                }
                .disabled(adopting)
                .accessibilityIdentifier("device-panel-confirm-adopt")
            }
        }
    }

    private var readmeSection: some View {
        Section {
            if model.linkDeviceID.isEmpty {
                Text("本机尚未取得这台设备的 Link device ID；此时采用会在求值时报 device_mismatch。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text(verbatim: "这台设备的 Link device ID：\(model.linkDeviceID)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Text("描述副本存放在宿主私有目录，按 Link device ID 存放，每台设备至多一份。工作区文件之后被改写或删除不影响已采用的副本；要生效必须再次采用。")
            Text("已采用的描述在每次取得新工具表时重新求值；结果不是 ok 时不生效，面板回到工具列表并显示原因。")
        } header: {
            Text("说明")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func reloadFileList() {
        files = Self.descriptorFiles(in: ChatModel.shared.files)
        if let selectedPath, !files.contains(where: { $0.relativePath == selectedPath }) {
            self.selectedPath = nil
            bytes = nil
            review = nil
        }
    }

    private func refreshFiles() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await ChatModel.shared.refreshFilesAndWait()
        reloadFileList()
    }

    private func select(_ file: WorkspaceFile) {
        selectedPath = file.relativePath
        bytes = nil
        review = nil
        readError = nil
        adoptOutcome = nil
        adoptError = nil
        guard let url = Self.descriptorURL(for: file.relativePath),
              let data = Self.readCapped(url) else {
            readError = "无法读取这个工作区文件。"
            return
        }
        bytes = data
        review = model.reviewDescriptor(data)
    }

    private func adopt() {
        guard let bytes, review?.isOK == true else { return }
        adopting = true
        adoptOutcome = nil
        adoptError = nil
        Task {
            let result = await model.adoptDescriptor(bytes)
            adopting = false
            if let result {
                adoptOutcome = result
                if result == .ok {
                    selectedPath = nil
                    self.bytes = nil
                    self.review = nil
                }
            } else {
                adoptError = model.errorText ?? "采用失败。"
            }
        }
    }

    // MARK: Workspace access (same safe resolution as FilesPage)

    /// Descriptor files live under `device-panels/` and must be `.json`.
    static func descriptorFiles(in files: [WorkspaceFile]) -> [WorkspaceFile] {
        files.filter { file in
            let path = file.relativePath
            return path.hasPrefix("device-panels/") && path.hasSuffix(".json")
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private static var workspaceRoot: URL {
        ChatModel.shared.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// Mirrors `FilesPage.safeURL`: no absolute path, no `..` component, the
    /// resolved file must stay under the materialized workspace, and it must be
    /// a regular file. Nothing is read before the user selects a file.
    static func descriptorURL(for relativePath: String) -> URL? {
        let root = workspaceRoot
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return candidate
    }

    /// Reads at most one byte past the 16384-byte descriptor limit. Feeding the
    /// evaluator 16385 bytes makes it return `too_large` without loading an
    /// arbitrarily large workspace file into memory.
    static func readCapped(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            return try handle.read(upToCount: 16_385) ?? Data()
        } catch {
            return nil
        }
    }
}
