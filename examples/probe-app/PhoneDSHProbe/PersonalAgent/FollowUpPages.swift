// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct FollowUpListPage: View {
    let store: FollowUpStore
    @State private var records: [FollowUpRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if records.isEmpty {
                Text("没有进行中的跟进").foregroundStyle(HomeSpec.textSecondary)
            }
            ForEach(records) { record in
                NavigationLink(record.followUp.goal) {
                    FollowUpDetailPage(store: store, record: record)
                }
                .accessibilityHint(record.needsAttention ? "需要你处理" : "跟进中")
            }
        }
        .navigationTitle("持续跟进")
        .task { await reload() }
        .alert("无法读取跟进", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async {
        do { records = try await store.records() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct FollowUpDetailPage: View {
    let store: FollowUpStore
    @State var record: FollowUpRecord
    @State private var checkExpression: String
    @State private var stopExpression: String
    @State private var errorMessage: String?

    init(store: FollowUpStore, record: FollowUpRecord) {
        self.store = store
        self._record = State(initialValue: record)
        self._checkExpression = State(initialValue: record.followUp.nextCheckCondition.expression)
        self._stopExpression = State(initialValue: record.followUp.stopCondition.expression)
    }

    var body: some View {
        Form {
            Section("目标与当前结果") {
                Text(record.followUp.goal)
                if let reason = record.followUp.waitingReason { LabeledContent("等待", value: reason) }
                if let summary = record.lastChangeSummary { Text(summary) }
                if let verified = record.followUp.lastVerifiedAt {
                    LabeledContent("最近核验", value: verified.formatted(date: .abbreviated, time: .shortened))
                }
                if let notified = record.lastNotificationAt {
                    LabeledContent("最近通知", value: notified.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("条件") {
                TextField("检查条件", text: $checkExpression, axis: .vertical)
                TextField("停止条件", text: $stopExpression, axis: .vertical)
                Picker("通知", selection: Binding(
                    get: { record.followUp.notificationPolicy },
                    set: { record.followUp.notificationPolicy = $0 })) {
                    Text("安静").tag(NotificationPolicy.quiet)
                    Text("仅变化").tag(NotificationPolicy.changesOnly)
                    Text("所有新结果").tag(NotificationPolicy.allResults)
                }
                Button("保存条件") {
                    Task {
                        do {
                            record = try await store.updateConditions(
                                record.id, check: CheckCondition(expression: checkExpression),
                                stop: StopCondition(expression: stopExpression),
                                notificationPolicy: record.followUp.notificationPolicy)
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            Section {
                Button("暂停到周五") {
                    Task {
                        do { record = try await store.pause(record.id, until: Self.nextFriday()) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                Button("结束跟进", role: .destructive) {
                    Task {
                        do {
                            try await store.end(record.id)
                            record.endedAt = Date()
                            record.needsAttention = false
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("跟进详情")
        .alert("操作失败", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private static func nextFriday(now: Date = Date()) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let weekday = calendar.component(.weekday, from: now)
        var days = (6 - weekday + 7) % 7
        if days == 0 { days = 7 }
        return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(9 * 3_600)
    }
}
