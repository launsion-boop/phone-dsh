// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: Daily Brief presentation model.

import Darwin
import Foundation
import Observation
import ProbeKit

@MainActor
@Observable
final class DailyBriefModel {
    static let shared = DailyBriefModel.makeShared()

    @ObservationIgnored private let store: DailyBriefStore
    @ObservationIgnored private let pipeline: DailyBriefRefreshPipeline
    private var state = DailyBriefPersistedState()
    private var didLoad = false

    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    var sources: [DailyBriefSource] { state.sources }
    var snapshot: DailyBriefSnapshot? { state.snapshot }
    var lastReport: DailyBriefRefreshReport? { state.lastReport }
    var shareText: String { state.snapshot?.shareText ?? "" }
    var lastSuccessfulAt: Date? { state.snapshot?.createdAt }
    var lastAttemptAt: Date? { state.lastReport?.finishedAt }

    init(store: DailyBriefStore, pipeline: DailyBriefRefreshPipeline) {
        self.store = store
        self.pipeline = pipeline
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            state = try await store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshIfNeeded() async {
        await load()
        let isStale = lastAttemptAt.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
        if snapshot == nil || isStale { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        await load()
        guard didLoad else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            terminateForAutomation("fetch")
            let outcome = try await pipeline.refresh(sources: state.sources,
                                                     previous: state.snapshot)
            terminateForAutomation("summary")
            let updated = DailyBriefPersistedState(
                sources: outcome.sources,
                snapshot: outcome.currentSnapshot,
                lastReport: outcome.report)
            terminateForAutomation("publish")
            try await store.save(updated)
            state = updated
            if !outcome.report.sourceIssues.isEmpty {
                errorMessage = outcome.report.sourceIssues.count == 1
                    ? "一个来源更新失败，已保留上一期内容"
                    : "\(outcome.report.sourceIssues.count) 个来源更新失败，已保留上一期内容"
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addSource(name: String, urlString: String) async -> Bool {
        await load()
        guard didLoad, !isRefreshing else { return false }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = DailyBriefError.invalidSource("地址格式无效").localizedDescription
            return false
        }
        do {
            let validated = try DailyBriefSourceValidator.validate(url)
            guard state.sources.count < DailyBriefLimits.maximumSources else {
                errorMessage = "来源数量已达上限"
                return false
            }
            guard !state.sources.contains(where: { $0.url == validated }) else {
                errorMessage = "这个来源已经添加过了"
                return false
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = DailyBriefSource(
                name: trimmedName.isEmpty ? (validated.host ?? "资讯来源") : trimmedName,
                url: validated)
            var updated = state
            updated.sources.append(source)
            try await store.save(updated)
            state = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setEnabled(_ enabled: Bool, source: DailyBriefSource) async {
        guard !isRefreshing, let index = state.sources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        var updated = state
        updated.sources[index].isEnabled = enabled
        do {
            try await store.save(updated)
            state = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(source: DailyBriefSource) async {
        guard !isRefreshing else { return }
        var updated = state
        updated.sources.removeAll { $0.id == source.id }
        do {
            try await store.save(updated)
            state = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func terminateForAutomation(_ phase: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PDSH_DAILY_BRIEF_KILL_PHASE"] == phase else { return }
        Darwin._exit(0)
        #endif
    }

    private static func makeShared() -> DailyBriefModel {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            #if DEBUG
            let transport: any DailyBriefTransport = DailyBriefAutomationTransport()
            #else
            let transport = DailyBriefURLSessionTransport()
            #endif
            return DailyBriefModel(store: try DailyBriefStore(root: root),
                                   pipeline: DailyBriefRefreshPipeline(transport: transport))
        } catch {
            fatalError("Daily Brief store unavailable: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
extension DailyBriefModel {
    static var preview: DailyBriefModel {
        let source = DailyBriefSource(name: "示例资讯", url: URL(string: "https://feed.test/daily")!)
        let now = Date()
        let items = [
            DailyBriefItem(
                id: "preview-1", sourceID: source.id, sourceName: source.name,
                title: "本地快照在离线时仍然可用",
                summary: "这一期内容已经保存在设备上，飞行模式下也能阅读和分享。",
                link: URL(string: "https://example.com/offline"), publishedAt: now.addingTimeInterval(-3600)),
            DailyBriefItem(
                id: "preview-2", sourceID: source.id, sourceName: source.name,
                title: "打开应用时增量更新",
                summary: "只有完整的新一期准备好之后，才会替换当前快照。",
                link: URL(string: "https://example.com/refresh"), publishedAt: now.addingTimeInterval(-7200)),
        ]
        let snapshot = DailyBriefSnapshot(
            id: DailyBriefIDs.snapshot(createdAt: now, items: items, sourceCursors: [:]),
            createdAt: now, items: items)
        let model = DailyBriefModel(
            store: try! DailyBriefStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("DailyBriefPreview-\(UUID().uuidString)")),
            pipeline: DailyBriefRefreshPipeline(transport: DailyBriefPreviewTransport()))
        model.state = DailyBriefPersistedState(sources: [source], snapshot: snapshot)
        model.didLoad = true
        return model
    }
}

private struct DailyBriefPreviewTransport: DailyBriefTransport {
    func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse {
        .notModified
    }
}

private struct DailyBriefAutomationTransport: DailyBriefTransport {
    private let base = DailyBriefURLSessionTransport()

    func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse {
        if ProcessInfo.processInfo.environment["PDSH_DAILY_BRIEF_OFFLINE"] == "1" {
            throw URLError(.notConnectedToInternet)
        }
        return try await base.fetch(source)
    }
}
#endif
