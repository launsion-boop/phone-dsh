// SPDX-License-Identifier: MIT
// Read-only DSH projections and guarded controls for session activity.

import SwiftUI

struct SessionActivityPage: View {
    let sessionID: String
    @State private var management = DSHManagementModel.shared
    @State private var confirmGoal: String?
    @State private var confirmSchedule: ActivityRow?
    @State private var confirmJob: ActivityRow?
    @State private var confirmSubagent: ActivityRow?

    var body: some View {
        List {
            Section("会话") {
                Text("查看此会话的计划、待办、目标和后台活动。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("计划") {
                if let active = management.planActive {
                    LabeledContent("模式", value: active ? "已启用" : "未启用")
                    if management.planPending { Label("正在应用模式变更", systemImage: "clock") }
                } else {
                    Text("此会话尚未启用计划模式。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("待办") {
                if management.todos.isEmpty {
                    Text("当前会话还没有待办事项。")
                        .foregroundStyle(.secondary)
                }
                ForEach(management.todos) { row in
                    HStack {
                        Image(systemName: todoIcon(row.status))
                            .foregroundStyle(row.status == "completed" ? .green : .secondary)
                        Text(row.title)
                        Spacer()
                        Text(todoLabel(row.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("目标") {
                if let goal = management.goal {
                    Text(goal.objective).font(.body)
                    LabeledContent("阶段", value: goalPhaseLabel(goal.phase))
                    LabeledContent("轮次", value: "\(goal.roundsStarted) / \(goal.maxGoalRounds)")
                    if goal.phase == "active" {
                        Button("暂停目标") { confirmGoal = "pause" }
                    } else if ["paused", "blocked"].contains(goal.phase) {
                        Button("恢复目标") { confirmGoal = "resume" }
                    }
                    if goal.phase != "complete" {
                        Button("标记完成", role: .destructive) { confirmGoal = "complete" }
                    }
                } else {
                    Text("当前会话没有进行中的目标。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("子智能体") {
                if management.subagents.isEmpty {
                    Text("当前会话没有子智能体。")
                        .foregroundStyle(.secondary)
                }
                ForEach(management.subagents) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.body.weight(.medium))
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if row.status == "continuable" {
                            Button("中断子智能体", role: .destructive) { confirmSubagent = row }
                        }
                    }
                }
            }

            Section("计划任务") {
                if management.schedules.isEmpty {
                    Text("当前会话没有计划任务。")
                        .foregroundStyle(.secondary)
                }
                ForEach(management.schedules) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.title).font(.body.weight(.medium))
                            Spacer()
                            Text(statusLabel(row.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("删除计划任务", role: .destructive) { confirmSchedule = row }
                    }
                }
            }

            Section("后台作业") {
                if management.jobs.isEmpty {
                    Text("当前会话没有后台作业。")
                        .foregroundStyle(.secondary)
                }
                ForEach(management.jobs) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.title).font(.body.weight(.medium))
                            Spacer()
                            Text(statusLabel(row.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        if ["running", "stopping"].contains(row.status ?? "") {
                            Button("停止后台作业", role: .destructive) { confirmJob = row }
                        }
                    }
                }
            }

            Section("技能目录") {
                if management.skills.isEmpty {
                    Text("当前没有可用的技能信息。")
                        .foregroundStyle(.secondary)
                }
                ForEach(management.skills) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.title).font(.body.weight(.medium))
                            Spacer()
                            // 认得出的档位翻中文,认不出就整行不出现——不拿原值顶上。
                            if let status = row.status, statusLabel(status) != status {
                                Text(statusLabel(status)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            ForEach(management.activityErrors.keys.sorted(), id: \.self) { key in
                if let value = management.activityErrors[key] {
                    Section("暂不可用") {
                        DisclosureGroup("\(key)的详细原因") {
                            Text(value).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("会话活动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { await management.refreshActivity(sessionID: sessionID) } }.trailingBarText() } }
        .refreshable { await management.refreshActivity(sessionID: sessionID) }
        .task { await management.refreshActivity(sessionID: sessionID) }
        .confirmationDialog(goalConfirmationTitle, isPresented: Binding(
            get: { confirmGoal != nil }, set: { if !$0 { confirmGoal = nil } }), titleVisibility: .visible) {
                Button(goalActionLabel, role: confirmGoal == "complete" ? .destructive : nil) {
                    guard let action = confirmGoal, let goal = management.goal else { return }
                    Task { await management.mutateGoal(action, sessionID: sessionID, goal: goal); confirmGoal = nil }
                }
                Button("取消", role: .cancel) { confirmGoal = nil }
            } message: { Text("此操作会更新当前会话的目标状态。") }
        .confirmationDialog("删除此计划任务？", isPresented: Binding(
            get: { confirmSchedule != nil }, set: { if !$0 { confirmSchedule = nil } }), titleVisibility: .visible) {
                Button("删除计划任务", role: .destructive) {
                    guard let row = confirmSchedule else { return }
                    Task { await management.deleteSchedule(row, sessionID: sessionID); confirmSchedule = nil }
                }
                Button("取消", role: .cancel) { confirmSchedule = nil }
            }
        .confirmationDialog("停止此后台作业？", isPresented: Binding(
            get: { confirmJob != nil }, set: { if !$0 { confirmJob = nil } }), titleVisibility: .visible) {
                Button("停止作业", role: .destructive) {
                    guard let row = confirmJob else { return }
                    Task { await management.killJob(row, sessionID: sessionID); confirmJob = nil }
                }
                Button("取消", role: .cancel) { confirmJob = nil }
            }
        .confirmationDialog("中断此子 Agent？", isPresented: Binding(
            get: { confirmSubagent != nil }, set: { if !$0 { confirmSubagent = nil } }), titleVisibility: .visible) {
                Button("中断", role: .destructive) {
                    guard let row = confirmSubagent else { return }
                    Task { await management.interruptSubagent(row, parentSessionID: sessionID); confirmSubagent = nil }
                }
                Button("取消", role: .cancel) { confirmSubagent = nil }
            }
    }

    private var goalConfirmationTitle: String {
        switch confirmGoal {
        case "pause": "暂停当前目标？"
        case "resume": "恢复当前目标？"
        case "complete": "完成当前目标？"
        default: "更新目标？"
        }
    }

    private var goalActionLabel: String {
        switch confirmGoal {
        case "pause": "暂停"
        case "resume": "恢复"
        case "complete": "标记完成"
        default: "确定"
        }
    }

    private func todoIcon(_ status: String?) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    private func todoLabel(_ status: String?) -> String {
        switch status {
        case "completed": "已完成"
        case "in_progress": "进行中"
        default: "待办"
        }
    }

    private func goalPhaseLabel(_ phase: String) -> String {
        switch phase.lowercased() {
        case "active": "进行中"
        case "paused": "已暂停"
        case "blocked": "受阻"
        case "complete", "completed": "已完成"
        case "failed": "失败"
        default: phase
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status?.lowercased() {
        case "active": "启用"
        case "pending": "等待中"
        case "running": "运行中"
        case "stopping": "正在停止"
        case "completed", "complete": "已完成"
        case "failed", "error": "失败"
        case "cancelled", "canceled": "已取消"
        case "paused": "已暂停"
        case "unknown", nil: "状态未知"
        default: status ?? "状态未知"
        }
    }
}
