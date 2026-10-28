// SPDX-License-Identifier: MIT
// Native iPhone catalog and editor for DSH scheduled automation.

import SwiftUI
import PhoneDSHAgentCore
import PhoneDSHWire

struct NativeAutomationPage: View {
    @State private var management = DSHManagementModel.shared
    @State private var creating = false
    @State private var editing: ManagedSchedule?
    @State private var deleting: ManagedSchedule?

    var body: some View {
        List {
            if management.scheduleRecords.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有定时任务")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("到点让它自己跑,结果回到原会话。")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        creating = true
                    } label: {
                        Text("新建任务")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color(uiColor: .systemBackground))
                .listRowSeparator(.hidden)
            } else {
                ForEach(management.scheduleRecords) { schedule in
                    NavigationLink {
                        ScheduleDetailPage(scheduleID: schedule.id, sessionID: schedule.sessionID, management: management)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(schedule.title).font(.body.weight(.medium))
                                Spacer()
                                Text(schedule.status == "active" ? "活动" : "已停止")
                                    .font(.caption).foregroundStyle(schedule.status == "active" ? .green : .secondary)
                            }
                            Text(schedule.prompt).font(.subheadline).lineLimit(2)
                            Text("\(sessionTitle(schedule.sessionID)) · \(schedule.detail)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("编辑") { editing = schedule }.tint(.blue)
                        Button("删除", role: .destructive) { deleting = schedule }
                    }
                }
            }

            if let error = management.error {
                Section("需要处理") { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("定时任务")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await management.refreshAutomations() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新自动化任务")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建") { creating = true }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
                    .accessibilityLabel("新建")
                    .disabled(ChatModel.shared.currentSessionID == nil)
            }
        }
        .refreshable { await management.refreshAutomations() }
        .task { await management.refreshAutomations() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ScheduleEditorPage(schedule: nil,
                                   sessionID: ChatModel.shared.currentSessionID ?? "",
                                   management: management)
            }
        }
        .sheet(item: $editing) { schedule in
            NavigationStack { ScheduleEditorPage(schedule: schedule, sessionID: schedule.sessionID, management: management) }
        }
        .confirmationDialog("删除此自动化任务？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除任务", role: .destructive) {
                    guard let schedule = deleting else { return }
                    Task { await management.deleteSchedule(schedule); deleting = nil }
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("删除会停止后续投递，并保留已保存的会话历史。") }
    }

    private func sessionTitle(_ sessionID: String) -> String {
        management.sessions.first(where: { $0.id == sessionID })?.title ?? String(sessionID.prefix(8))
    }
}

private struct ScheduleDetailPage: View {
    let scheduleID: String
    let sessionID: String
    let management: DSHManagementModel
    @State private var editing = false
    @State private var deleting = false

    private var schedule: ManagedSchedule? { management.scheduleRecords.first(where: { $0.id == scheduleID }) }

    var body: some View {
        List {
            if let schedule {
                Section("提醒") {
                    LabeledContent("名称", value: schedule.title)
                    LabeledContent("规则", value: schedule.kind)
                    LabeledContent("下次计划", value: schedule.scheduledAt)
                    LabeledContent("状态", value: schedule.status)
                    Text(schedule.prompt).textSelection(.enabled)
                }
                Section("投递记录") {
                    NavigationLink {
                        ScheduleHistoryPage(schedule: schedule, management: management)
                    } label: {
                        Label("查看 DSH 已保存的投递记录", systemImage: "clock.arrow.circlepath")
                    }
                    if let latestDeliveryAt = schedule.latestDeliveryAt {
                        Text("最近投递：\(latestDeliveryAt)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("任务不存在", systemImage: "clock.badge.xmark")
            }
            if let error = management.error { Section("错误") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑") { editing = true }
                    Button("删除", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await management.refreshAutomations() }
        .sheet(isPresented: $editing) {
            if let schedule {
                NavigationStack { ScheduleEditorPage(schedule: schedule, sessionID: sessionID, management: management) }
            }
        }
        .confirmationDialog("删除此自动化任务？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let schedule else { return }
                Task { await management.deleteSchedule(schedule) }
            }
            Button("取消", role: .cancel) { }
        }
    }
}

private struct ScheduleHistoryPage: View {
    let schedule: ManagedSchedule
    let management: DSHManagementModel

    var body: some View {
        List {
            if let notice = management.scheduleHistoryNotice {
                Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if management.scheduleHistory.isEmpty {
                ContentUnavailableView("没有投递记录", systemImage: "tray", description: Text("这次还没留下结果。"))
            } else {
                ForEach(management.scheduleHistory) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.deliveredAt).font(.subheadline.weight(.medium))
                        Text("计划时间：\(item.scheduledAt)").font(.caption).foregroundStyle(.secondary)
                        if let prompt = item.prompt { Text(prompt).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            if management.scheduleHistoryHasMore {
                Button("加载更早记录") {
                    Task { await management.loadScheduleHistory(schedule, before: management.scheduleHistoryCursor) }
                }
            }
            if let error = management.error { Section("错误") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .navigationTitle("投递记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await management.loadScheduleHistory(schedule) }
        .refreshable { await management.loadScheduleHistory(schedule) }
    }
}

private struct ScheduleEditorPage: View {
    let schedule: ManagedSchedule?
    let sessionID: String
    let management: DSHManagementModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prompt = ""
    @State private var rule = "after"
    @State private var delaySeconds = "3600"
    @State private var targetAt = ""
    @State private var intervalSeconds = "3600"
    @State private var localTime = "09:00:00"
    @State private var timeZone = TimeZone.current.identifier
    @State private var weekdays = "1,2,3,4,5"
    @State private var cronExpression = "0 9 * * 1-5"
    @State private var changeTiming = false
    @State private var saving = false

    private let rules = ["after", "at", "every", "daily", "weekly", "cron"]

    init(schedule: ManagedSchedule?, sessionID: String, management: DSHManagementModel) {
        self.schedule = schedule
        self.sessionID = sessionID
        self.management = management
        _title = State(initialValue: schedule?.title ?? "")
        _prompt = State(initialValue: schedule?.prompt ?? "")
        _rule = State(initialValue: schedule?.kind ?? "after")
        _delaySeconds = State(initialValue: String(schedule?.expectedRecord["afterSeconds"]?.intValue ?? 3600))
        _targetAt = State(initialValue: schedule?.scheduledAt ?? ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))
        _intervalSeconds = State(initialValue: String(schedule?.expectedRecord["everySeconds"]?.intValue ?? 3600))
        _localTime = State(initialValue: schedule?.expectedRecord["time"]?.stringValue ?? "09:00:00")
        _timeZone = State(initialValue: schedule?.expectedRecord["timeZone"]?.stringValue ?? TimeZone.current.identifier)
        _weekdays = State(initialValue: (schedule?.expectedRecord["weekdays"]?.arrayValue ?? []).compactMap(\.intValue).map(String.init).joined(separator: ","))
        _cronExpression = State(initialValue: schedule?.expectedRecord["expression"]?.stringValue ?? "0 9 * * 1-5")
        _changeTiming = State(initialValue: schedule == nil)
    }

    var body: some View {
        Form {
            Section("任务内容") {
                TextField("名称", text: $title)
                    .textInputAutocapitalization(.sentences)
                TextField("提醒内容", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section("计划时间") {
                if schedule != nil {
                    Toggle("修改计划时间", isOn: $changeTiming)
                }
                if schedule == nil || changeTiming {
                    Picker("规则", selection: $rule) {
                        Text("延迟一次").tag("after")
                        Text("指定时间").tag("at")
                        Text("固定间隔").tag("every")
                        Text("每天").tag("daily")
                        Text("每周").tag("weekly")
                        Text("自定义时间表").tag("cron")
                    }
                    ruleFields
                } else if let schedule {
                    LabeledContent("当前规则", value: schedule.scheduledAt)
                }
            }
            if let error = management.error { Section("错误") { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(schedule == nil ? "新建自动化" : "编辑自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.leadingBarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }
                    .disabled(saving || sessionID.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var ruleFields: some View {
        switch rule {
        case "after":
            TextField(schedule == nil ? "延迟秒数" : "延迟到期秒数", text: $delaySeconds).keyboardType(.numberPad)
        case "at":
            Text("需要包含时区，例如 2026-10-26T09:00:00+08:00。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("ISO-8601 日期时间", text: $targetAt).textInputAutocapitalization(.never).autocorrectionDisabled()
        case "every":
            TextField("间隔秒数（至少 60）", text: $intervalSeconds).keyboardType(.numberPad)
        case "daily":
            TextField("本地时间 HH:mm:ss", text: $localTime).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("IANA 时区", text: $timeZone).textInputAutocapitalization(.never).autocorrectionDisabled()
        case "weekly":
            TextField("本地时间 HH:mm:ss", text: $localTime).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("IANA 时区", text: $timeZone).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("星期（ISO 1–7，以逗号分隔）", text: $weekdays).keyboardType(.numbersAndPunctuation)
        case "cron":
            TextField("五段 Cron 表达式", text: $cronExpression).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("IANA 时区", text: $timeZone).textInputAutocapitalization(.never).autocorrectionDisabled()
        default:
            EmptyView()
        }
    }

    private func save() {
        saving = true
        Task {
            let timing: JSONValue?
            if schedule == nil || changeTiming {
                guard let validated = timingChange() else {
                    management.reportError(timingValidationMessage())
                    saving = false
                    return
                }
                timing = validated
            } else { timing = nil }
            let saved: Bool
            if let schedule {
                saved = await management.updateSchedule(schedule,
                                                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        timing: changeTiming ? timing : nil)
            } else if let timing {
                var request: [String: JSONValue] = [
                    "sessionId": .string(sessionID),
                    "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                ]
                addCreationRule(timing, to: &request)
                saved = await management.createSchedule(request: request)
            } else {
                saved = false
            }
            saving = false
            if saved { dismiss() }
        }
    }

    private func timingChange() -> JSONValue? {
        switch rule {
        case "after":
            guard let seconds = Int(delaySeconds), seconds > 0 else { return nil }
            if schedule == nil { return .object(["kind": .string("after"), "after_seconds": .number(Double(seconds))]) }
            let target = Date().addingTimeInterval(TimeInterval(seconds))
            return .object(["kind": .string("at"), "at": .string(ISO8601DateFormatter().string(from: target))])
        case "at":
            guard validISO8601(targetAt) else { return nil }
            return .object(["kind": .string("at"), "at": .string(targetAt)])
        case "every":
            guard let seconds = Int(intervalSeconds), seconds >= 60 else { return nil }
            return .object(["kind": .string("every"), "every_seconds": .number(Double(seconds))])
        case "daily":
            guard isValidTime(localTime), TimeZone(identifier: timeZone) != nil else { return nil }
            return .object(["kind": .string("daily"), "daily": .object([
                "time": .string(localTime), "time_zone": .string(timeZone),
            ])])
        case "weekly":
            let days = weekdays.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !days.isEmpty, Set(days).count == days.count, days.allSatisfy({ (1...7).contains($0) }),
                  isValidTime(localTime), TimeZone(identifier: timeZone) != nil else { return nil }
            return .object(["kind": .string("weekly"), "weekly": .object([
                "time": .string(localTime), "time_zone": .string(timeZone),
                "weekdays": .array(days.map { .number(Double($0)) }),
            ])])
        case "cron":
            guard cronExpression.split(whereSeparator: \.isWhitespace).count == 5,
                  TimeZone(identifier: timeZone) != nil else { return nil }
            return .object(["kind": .string("cron"), "cron": .object([
                "expression": .string(cronExpression), "time_zone": .string(timeZone),
            ])])
        default: return nil
        }
    }

    private func isValidTime(_ value: String) -> Bool {
        value.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,3})?)?$"#, options: .regularExpression) != nil
    }

    private func validISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private func timingValidationMessage() -> String {
        switch rule {
        case "after": "请输入大于0的延迟秒数。"
        case "at": "请输入带时区的有效 ISO-8601 日期时间。"
        case "every": "固定间隔至少为60秒。"
        case "daily": "每天提醒需要有效的本地时间和 IANA 时区。"
        case "weekly": "每周提醒需要有效时间/时区，并选择 1–7 的星期。"
        case "cron": "Cron 需要五段表达式和有效 IANA 时区。"
        default: "请检查计划规则。"
        }
    }

    private func addCreationRule(_ timing: JSONValue, to request: inout [String: JSONValue]) {
        switch timing["kind"]?.stringValue {
        case "after": request["after_seconds"] = timing["after_seconds"]
        case "at": request["at"] = timing["at"]
        case "every": request["every_seconds"] = timing["every_seconds"]
        case "daily": request["daily"] = timing["daily"]
        case "weekly": request["weekly"] = timing["weekly"]
        case "cron": request["cron"] = timing["cron"]
        default: break
        }
    }
}
