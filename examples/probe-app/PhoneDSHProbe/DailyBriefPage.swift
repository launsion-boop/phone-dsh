// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: native Daily Brief page.

import ProbeKit
import SwiftUI

@MainActor
struct DailyBriefPage: View {
    @State private var model: DailyBriefModel
    @State private var addingSource = false

    init(model: DailyBriefModel = .shared) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.snapshot == nil ? "还没有简报" : "每日简报")
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                            .accessibilityIdentifier("daily-brief-snapshot")
                            .accessibilityValue(model.snapshot?.id ?? "none")
                        if let date = model.lastSuccessfulAt {
                            Text("最近成功 \(date, style: .relative)")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        } else {
                            Text("添加来源后，打开页面就会更新")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let date = model.lastAttemptAt {
                            Text("最近尝试 \(date, style: .relative)")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if model.isRefreshing { ProgressView() }
                    if !model.shareText.isEmpty {
                        ShareLink(item: model.shareText) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let report = model.lastReport {
                    HStack {
                        Text("\(report.itemCount) 条内容")
                        Spacer()
                        Text("新增 \(report.newItemCount)")
                        Spacer()
                        Text("网络 \(ByteCountFormatter().string(fromByteCount: Int64(report.networkBytes))) · 模型 0 · 实际")
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if let items = model.snapshot?.items, !items.isEmpty {
                Section("最新一期") {
                    ForEach(items) { item in
                        if let link = item.link {
                            Link(destination: link) { DailyBriefItemRow(item: item) }
                                .buttonStyle(.plain)
                        } else {
                            DailyBriefItemRow(item: item)
                        }
                    }
                }
            } else {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "newspaper")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有可显示的内容")
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        Text(model.sources.isEmpty
                             ? "先添加一个 RSS 或 Atom 来源。已有内容会保存在本机，离线也能看。"
                             : "下拉或点右上角刷新；失败时不会清空上一期。")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            }

            Section("资讯来源") {
                ForEach(model.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.system(size: HomeSpec.bodySize))
                            Text(source.url.absoluteString)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { enabled in Task { await model.setEnabled(enabled, source: source) } }
                        ))
                        .labelsHidden()
                        .disabled(model.isRefreshing)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.remove(source: source) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .disabled(model.isRefreshing)
                    }
                }
                Button {
                    addingSource = true
                } label: {
                    Label("添加 RSS / Atom 来源", systemImage: "plus")
                }
                .disabled(model.isRefreshing || model.sources.count >= DailyBriefLimits.maximumSources)
            }

            if let issues = model.lastReport?.sourceIssues, !issues.isEmpty {
                Section("本次更新问题") {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 4) {
                            if !issue.sourceName.isEmpty {
                                Text(issue.sourceName).font(.system(size: 13, weight: .semibold))
                            }
                            Text(issue.message).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("每日简报")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.sources.isEmpty)
            }
        }
        .task { await model.refreshIfNeeded() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $addingSource) {
            DailyBriefSourceEditor(model: model)
                .presentationDetents([.medium])
                .homeSheetChrome()
        }
    }
}

private struct DailyBriefItemRow: View {
    let item: DailyBriefItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack {
                Text(item.sourceName)
                Spacer()
                if let date = item.publishedAt {
                    Text(date, style: .relative)
                }
            }
            .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct DailyBriefSourceEditor: View {
    let model: DailyBriefModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选）", text: $name)
                    TextField("https://example.com/feed.xml", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("只支持 HTTPS 的 RSS 或 Atom 地址；不会抓取本机或私网服务。")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .homeGroupedList()
            .navigationTitle("添加资讯来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "添加中…" : "添加") {
                        saving = true
                        Task {
                            let added = await model.addSource(name: name, urlString: urlString)
                            saving = false
                            if added {
                                dismiss()
                            } else {
                                errorText = model.errorMessage
                            }
                        }
                    }
                    .disabled(saving || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
