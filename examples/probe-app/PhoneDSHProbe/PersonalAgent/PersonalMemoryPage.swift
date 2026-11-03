// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct PersonalMemoryPage: View {
    let store: MemoryStore
    let principal: String
    let domainStore: SQLiteDomainStore?
    @State private var records: [MemoryRecord] = []
    @State private var health: DomainStoreHealth = .ready
    @State private var errorMessage: String?
    @State private var correction: MemoryRecord?
    @State private var correctionText = ""
    @State private var correctionScope = ""

    init(store: MemoryStore, principal: String, domainStore: SQLiteDomainStore? = nil) {
        self.store = store
        self.principal = principal
        self.domainStore = domainStore
    }

    var body: some View {
        List {
            if case .readOnlyDiagnostic(let detail) = health {
                Section("存储诊断") {
                    Label("数据库已损坏，未自动重建。当前只能读取诊断信息。\n\(detail)",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
            memorySection("待确认", statuses: [.candidate])
            memorySection("关于我", kinds: [.longTerm], statuses: [.active])
            memorySection("工作进展", kinds: [.taskContext, .event], statuses: [.active])
            memorySection("已过期", statuses: [.expired])
            memorySection("归档", statuses: [.archived, .rejected])
            memorySection("遗忘", statuses: [.forgotten])
        }
        .navigationTitle("个人 Memory")
        .task {
            if let domainStore { health = await domainStore.health }
            await reload()
        }
        .refreshable { await reload() }
        .sheet(item: $correction) { record in
            NavigationStack {
                Form {
                    TextField("修正内容", text: $correctionText, axis: .vertical)
                    TextField("适用范围", text: $correctionScope)
                    Button("保存为新修订") {
                        Task {
                            do {
                                _ = try await store.supersede(record.id, with: correctionText,
                                                              scope: correctionScope)
                                correction = nil
                                await reload()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                .navigationTitle("修正 Memory")
                .toolbar { Button("取消") { correction = nil } }
            }
        }
        .alert("Memory 操作失败", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func memorySection(_ title: String, kinds: Set<MemoryKind>? = nil,
                               statuses: Set<MemoryStatus>) -> some View {
        let values = records.filter { record in
            statuses.contains(record.effectiveStatus()) && (kinds?.contains(record.kind) ?? true) &&
                (record.effectiveStatus() != .active || record.isActive())
        }
        if !values.isEmpty {
            Section(title) {
                ForEach(values) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.text)
                        HStack {
                            Text(record.field?.rawValue ?? record.kind.rawValue)
                            Text("修订 \(record.revision)")
                            Text(record.scope)
                        }
                        .font(.caption).foregroundStyle(HomeSpec.textSecondary)
                        DisclosureGroup("为什么知道这个") {
                            Text("来源：\(record.source.detail)")
                            Text("引用：\(record.source.reference)")
                            Text("更新：\(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            Text("有效期：\(record.validFrom.formatted(date: .abbreviated, time: .omitted)) – \(record.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "长期")")
                            if let supersedes = record.supersedes { Text("替代：\(supersedes.uuidString)") }
                        }
                        .font(.caption)
                        HStack {
                            if record.status == .candidate {
                                Button("记住") { Task { await mutate { _ = try await store.acceptCandidate(record.id) } } }
                                Button("不用") { Task { await mutate { try await store.rejectCandidate(record.id) } } }
                            }
                            if record.status == .active {
                                Button("修正") {
                                    correctionText = record.text
                                    correctionScope = record.scope
                                    correction = record
                                }
                                Button("归档") { Task { await mutate { try await store.archive(record.id) } } }
                                Button("遗忘", role: .destructive) {
                                    Task { await mutate { try await store.forget(record.id) } }
                                }
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func mutate(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reload() async {
        do { records = try await store.records(principal: principal) }
        catch { errorMessage = error.localizedDescription }
    }
}
