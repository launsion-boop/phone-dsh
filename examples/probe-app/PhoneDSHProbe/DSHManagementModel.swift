// SPDX-License-Identifier: MIT
// Native management surfaces over the pinned DSH Remote contract.

import Foundation
import Observation
import PhoneDSHAgentCore
import PhoneDSHWire

struct ManagedSession: Identifiable, Hashable {
    let id: String
    var title: String
    var updatedAt: Date
    var running: Bool
    var blank: Bool
    var cwd: String?
    var parentSessionID: String?
    var searchSnippet: String?
}

struct ManagedWorkspace: Identifiable, Hashable {
    let id: String
    var title: String
    var path: String
    var sessionIDs: [String]
}

struct ManagedReasoningEffort: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ManagedModelRoute: Identifiable, Hashable {
    let provider: String
    let providerName: String
    let model: String
    let reasoningEfforts: [ManagedReasoningEffort]
    let defaultEffort: String?
    var id: String { "\(provider)/\(model)" }
    var label: String { "\(providerName) · \(model)" }
}

struct ManagedModelSelection: Hashable {
    let provider: String
    let model: String
    let reasoningEffort: String?
    var label: String { "\(provider) · \(model)" + (reasoningEffort.map { " · \($0)" } ?? "") }
}

struct ManagedQueueItem: Identifiable, Hashable {
    let id: String
    let sessionID: String
    let lane: String
    var text: String
}

struct ManagedSchedule: Identifiable {
    let id: String
    let sessionID: String
    var title: String
    var prompt: String
    var kind: String
    var scheduledAt: String
    var status: String
    var latestDeliveryAt: String?
    var expectedRecord: JSONValue
    var detail: String { "\(kind) · \(scheduledAt)" }
}

struct ManagedDelivery: Identifiable, Hashable {
    let id: String
    var scheduledAt: String
    var deliveredAt: String
    var prompt: String?
}

struct ManagedTool: Identifiable, Hashable {
    let id: String
    var description: String
}

struct ActivityRow: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var status: String?
}

struct ManagedGoal: Hashable {
    let id: String
    let revision: Int
    var objective: String
    var phase: String
    var roundsStarted: Int
    var maxGoalRounds: Int
}

@MainActor
@Observable
final class DSHManagementModel {
    static let shared = DSHManagementModel()

    private(set) var sessions: [ManagedSession] = []
    private(set) var workspaces: [ManagedWorkspace] = []
    private(set) var workspaceOrder: [String] = []
    #if DEBUG
    /// 预览造了假数据之后,refresh() 不许把界面冲空。
    private(set) var previewDataInstalled = false
    #endif
    private(set) var pinnedSessionIDs: [String] = []
    private(set) var archivedIDs: Set<String> = []
    private(set) var modelRoutes: [ManagedModelRoute] = []
    private(set) var currentModelSelection: ManagedModelSelection?
    private(set) var searchSnippets: [String: String] = [:]
    private(set) var searchResultIDs: Set<String>?
    private(set) var queueItems: [ManagedQueueItem] = []
    private(set) var queueSessionID: String?
    private(set) var scheduleRecords: [ManagedSchedule] = []
    private(set) var scheduleHistory: [ManagedDelivery] = []
    private(set) var scheduleHistorySessionID: String?
    private(set) var scheduleHistoryHasMore = false
    private(set) var scheduleHistoryCursor: String?
    private(set) var scheduleHistoryNotice: String?
    private(set) var tools: [ManagedTool] = []
    private(set) var planActive: Bool?
    private(set) var planPending = false
    private(set) var todos: [ActivityRow] = []
    private(set) var goal: ManagedGoal?
    private(set) var subagents: [ActivityRow] = []
    private(set) var schedules: [ActivityRow] = []
    private(set) var skills: [ActivityRow] = []
    private(set) var jobs: [ActivityRow] = []
    private(set) var activityErrors: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var notice: String?
    private var transport: (any DSHRemoteTransport)?
    private var workspaceMux: (any DSHMuxConnection)?
    private var workspaceTask: Task<Void, Never>?

    var activeSessions: [ManagedSession] { sessions.filter { !archivedIDs.contains($0.id) } }
    var archivedSessions: [ManagedSession] { sessions.filter { archivedIDs.contains($0.id) } }
    var pinnedSessions: [ManagedSession] {
        pinnedSessionIDs.compactMap { id in sessions.first(where: { $0.id == id && !archivedIDs.contains(id) }) }
    }
    func sessions(in workspace: ManagedWorkspace) -> [ManagedSession] {
        workspace.sessionIDs.compactMap { id in sessions.first(where: { $0.id == id && !archivedIDs.contains(id) }) }
    }
    var ungroupedSessions: [ManagedSession] {
        let members = Set(workspaces.flatMap(\.sessionIDs))
        return activeSessions.filter { !members.contains($0.id) }
    }

    var currentWorkspaceID: String? {
        guard let sessionID = ChatModel.shared.currentSessionID else { return nil }
        return workspaces.first(where: { $0.sessionIDs.contains(sessionID) })?.id
    }
    var recentWorkspaceID: String? {
        workspaces.max { lhs, rhs in
            latestActivity(in: lhs) < latestActivity(in: rhs)
        }?.id
    }

    func refresh() async {
        #if DEBUG
        // 预览造的假数据不许被宿主刷新冲掉,否则预览一进去就空了。
        if previewDataInstalled { return }
        #endif
        guard !isLoading else { return }
        guard ChatModel.shared.isStarted else {
            sessions = []
            archivedIDs = []
            error = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await ChatModel.shared.transportForManagement()
            transport = client
            // This Remote has a reserved optional input in its TypeScript
            // contract, but the wire method takes no arguments at this pin.
            let sessionValue = try await client.call("session/list", args: .object([:]))
            sessions = Self.decodeSessions(sessionValue)
            // Optional catalog failures must not hide the valid session list.
            async let catalogResponse = try? client.call("session/modelCatalog", args: .object([:]))
            if let catalogValue = await catalogResponse {
                modelRoutes = Self.decodeModelRoutes(catalogValue)
            } else { modelRoutes = [] }
            if let currentSessionID = ChatModel.shared.currentSessionID {
                await refreshModelSelection(for: currentSessionID, using: client)
            } else { currentModelSelection = nil }
            await observeWorkspaceState(using: client)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createSession(workspaceID: String? = nil) async -> String? {
        do {
            guard !ChatModel.shared.turnRunning && !ChatModel.shared.keepingAlive && !ChatModel.shared.busy else {
                throw ManagementError.sessionBusy
            }
            let targetWorkspaceID = workspaceID ?? currentWorkspaceID ?? recentWorkspaceID
            if let targetWorkspaceID {
                guard let transport else { throw ManagementError.notConnected }
                let result = try await transport.call("session/create", args: .object(["request": .object([
                    "workspaceId": .string(targetWorkspaceID),
                ])]))
                guard let id = result["sessionId"]?.stringValue else { throw ManagementError.invalidResponse }
                await ChatModel.shared.selectSession(id)
                guard ChatModel.shared.currentSessionID == id else {
                    throw ManagementError.openFailed(ChatModel.shared.userFacingError)
                }
                notice = "会话已添加到工作区"
                await refresh()
                return id
            }
            let priorID = ChatModel.shared.currentSessionID
            await ChatModel.shared.newSession()
            guard let id = ChatModel.shared.currentSessionID, id != priorID else {
                throw ManagementError.openFailed(ChatModel.shared.userFacingError)
            }
            notice = "已创建新会话"
            await refresh()
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }

    func createWorkspace(at path: String) async -> ManagedWorkspace? {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/create", args: .object(["request": .object(["path": .string(path)])]))
            let row = result["workspace"] ?? .null
            guard let workspace = Self.decodeWorkspace(row) else { throw ManagementError.invalidResponse }
            if !workspaceOrder.contains(workspace.id) { workspaceOrder.append(workspace.id) }
            upsertWorkspace(workspace)
            notice = "工作区已添加"
            return workspace
        } catch { self.error = error.localizedDescription; return nil }
    }

    func renameWorkspace(_ workspace: ManagedWorkspace, to title: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/rename", args: .object(["request": .object([
                "workspaceId": .string(workspace.id), "title": .string(title),
            ])]))
            if let updated = Self.decodeWorkspace(result["workspace"] ?? result) { upsertWorkspace(updated) }
            notice = "工作区已重命名"
        } catch { self.error = error.localizedDescription }
    }

    /// 删掉的只是「文件夹」这个分组,里面的会话不跟着走:从 registry 里拿掉之后,
    /// 它们自动落回不归属文件夹的那一段(ungroupedSessions 是按 folders 反推的)。
    func deleteWorkspace(_ workspace: ManagedWorkspace) async {
        // 预览(没连宿主)时只在本地拿掉,好把「删完会话落到上面那一段」看到;
        // 真机上没有本地兜底,删就是宿主说了算。
        if transport == nil {
            workspaces.removeAll { $0.id == workspace.id }
            workspaceOrder.removeAll { $0 == workspace.id }
            notice = "工作文件夹已删除"
            return
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("workspace/delete", args: .object(["request": .object([
                "workspaceId": .string(workspace.id),
            ])]))
            workspaces.removeAll { $0.id == workspace.id }
            workspaceOrder.removeAll { $0 == workspace.id }
            notice = "工作文件夹已删除"
        } catch { self.error = error.localizedDescription }
    }

    func insertSession(_ session: ManagedSession, into workspace: ManagedWorkspace) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/insertSessionBefore", args: .object(["request": .object([
                "workspaceId": .string(workspace.id), "sessionId": .string(session.id),
            ])]))
            if let updated = Self.decodeWorkspace(result["workspace"] ?? result) { upsertWorkspace(updated) }
            notice = "会话已移入工作区"
        } catch { self.error = error.localizedDescription }
    }

    func setPinned(_ session: ManagedSession, pinned: Bool) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call(pinned ? "workspace/pinSession" : "workspace/unpinSession", args: .object(["request": .object([
                "sessionId": .string(session.id),
            ])]))
            pinnedSessionIDs = result["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            notice = pinned ? "会话已置顶" : "已取消置顶"
        } catch { self.error = error.localizedDescription }
    }

    func select(_ session: ManagedSession) async -> Bool {
        let chat = ChatModel.shared
        if chat.currentSessionID == session.id { error = nil; return true }
        // A drawer tap must work from any state the user can actually be in:
        // a stopped host (cold launch, manual stop) or a parked one (after a
        // trip to another app) gets started/resumed first, and a running turn
        // is stopped first — refusing to switch used to look like "the session
        // cannot be read".
        if !chat.isStarted {
            await chat.start()
            guard chat.isStarted else {
                error = chat.userFacingError ?? "主机没有启动，无法打开会话"
                return false
            }
        }
        if chat.parked {
            await chat.resumeParkedHost()
        }
        if chat.turnRunning || chat.pendingPermission != nil || chat.pendingQuestion != nil {
            await chat.cancelTurn()
            chat.dismissPendingRequests()
            guard !chat.turnRunning else {
                error = "当前回合停不下来，请稍后重试或重启主机"
                return false
            }
        }
        await chat.selectSession(session.id)
        guard chat.currentSessionID == session.id else {
            error = chat.userFacingError ?? "无法打开会话 \(session.id.prefix(8))"
            return false
        }
        error = nil
        return true
    }

    func rename(_ session: ManagedSession, to title: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("session/rename", args: .object(["request": .object([
                "sessionId": .string(session.id), "title": .string(title),
            ])]))
            notice = "Session renamed"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func fork(_ session: ManagedSession) async -> String? {
        do {
            guard !ChatModel.shared.turnRunning && !ChatModel.shared.keepingAlive && !ChatModel.shared.busy else {
                throw ManagementError.sessionBusy
            }
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("session/fork", args: .object(["request": .object(["sessionId": .string(session.id)])]))
            guard let id = result["sessionId"]?.stringValue else { throw ManagementError.invalidResponse }
            await ChatModel.shared.selectSession(id)
            guard ChatModel.shared.currentSessionID == id else {
                throw ManagementError.openFailed(ChatModel.shared.userFacingError)
            }
            notice = "Fork created from the latest completed turn"
            await refresh()
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }

    func search(_ query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            searchResultIDs = nil
            searchSnippets = [:]
            return
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            let value = try await transport.call("session/search", args: .object(["request": .object(["query": .string(normalized)])]))
            let rows = value["items"]?.arrayValue ?? []
            searchResultIDs = Set(rows.compactMap { $0["sessionId"]?.stringValue })
            searchSnippets = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["sessionId"]?.stringValue, let snippet = row["snippet"]?.stringValue else { return nil }
                return (id, snippet)
            })
        } catch {
            // Retain local title/ID filtering when full-text search is unavailable.
            searchResultIDs = []
        }
    }

    func selectModel(_ route: ManagedModelRoute, reasoningEffort: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            guard let sessionID = ChatModel.shared.currentSessionID else { throw ManagementError.noActiveSession }
            var request: [String: JSONValue] = [
                "sessionId": .string(sessionID), "provider": .string(route.provider), "model": .string(route.model),
            ]
            if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
            let result = try await transport.call("session/selectModel", args: .object(["request": .object(request)]))
            let selected = result["selected"] ?? .object(request)
            currentModelSelection = Self.decodeModelSelection(selected)
            notice = "已为当前会话选择模型"
        } catch { self.error = error.localizedDescription }
    }

    func reportError(_ message: String) { error = message }

    private func refreshModelSelection(for sessionID: String, using transport: any DSHRemoteTransport) async {
        do {
            let result = try await transport.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            let projection = result["values"]?["modelSelection"]
            currentModelSelection = Self.decodeModelSelection(projection?["next"] ?? projection?["lastUsed"] ?? .null)
        } catch { currentModelSelection = nil }
    }

    func refreshQueue(for sessionID: String) async {
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await ChatModel.shared.transportForManagement()
                transport = client
            }
            let result = try await client.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            let values = result["values"] ?? .null
            queueItems = ["next-turn", "next-step"].flatMap { lane in
                (values["inbox"]?[lane]?.arrayValue ?? []).compactMap { item in
                    guard let id = item["id"]?.stringValue else { return nil }
                    let text = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                        guard part["type"]?.stringValue == "text" else { return nil }
                        return part["text"]?.stringValue
                    }.joined(separator: "\n")
                    return ManagedQueueItem(id: id, sessionID: sessionID, lane: lane, text: text)
                }
            }
            queueSessionID = sessionID
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func updateQueue(_ item: ManagedQueueItem, action: String, replacement: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            var value: [String: JSONValue] = ["kind": .string(action)]
            if action == "edit" {
                value["content"] = .array([.object(["type": .string("text"), "text": .string(replacement ?? "")])])
            }
            _ = try await transport.call("session/updateQueue", args: .object(["request": .object([
                "sessionId": .string(item.sessionID), "itemId": .string(item.id), "action": .object(value),
            ])]))
            notice = action == "remove" ? "已从队列移除" : (action == "steer" ? "已将消息设为当前引导" : "队列内容已更新")
            await refreshQueue(for: item.sessionID)
        } catch { self.error = error.localizedDescription }
    }

    func refreshActivity(sessionID: String) async {
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await ChatModel.shared.transportForManagement()
                transport = client
            }
            activityErrors = [:]
            async let projectionResponse = try? client.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            async let skillResponse = try? client.call("skills/list", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            async let scheduleResponse = try? client.call("schedule/catalog", args: .object([:]))
            async let goalResponse = try? client.call("goals/get", args: .object(["sessionId": .string(sessionID)]))
            let (projectionValue, skillValue, scheduleValue, goalValue) = await
                (projectionResponse, skillResponse, scheduleResponse, goalResponse)

            if let projectionValue {
                decodeActivityProjections(projectionValue["values"] ?? .null)
            } else {
                activityErrors["状态"] = "DSH 没有返回此会话的投影数据。"
            }
            skills = skillValue?["skills"]?.arrayValue?.compactMap { row in
                guard let name = row["name"]?.stringValue else { return nil }
                return ActivityRow(id: name, title: name,
                                   detail: [row["description"]?.stringValue, row["whenToUse"]?.stringValue]
                                    .compactMap { $0 }.joined(separator: "\n"), status: row["modelInvocable"]?.boolValue == true ? "可由模型调用" : "仅用户调用")
            } ?? []
            if skillValue == nil { activityErrors["技能"] = "技能目录暂不可用；请检查当前预设的技能配置。" }
            schedules = scheduleValue?.arrayValue?.compactMap { row in
                guard row["id"]?.stringValue != nil else { return nil }
                guard row["sessionId"]?.stringValue == sessionID else { return nil }
                let id = row["id"]?.stringValue ?? UUID().uuidString
                let title = row["title"]?.stringValue ?? "计划任务"
                let rule = row["kind"]?.stringValue ?? row["type"]?.stringValue ?? "提醒"
                return ActivityRow(id: id, title: title,
                                   detail: "\(rule) · \(row["sessionId"]?.stringValue ?? "")",
                                   status: row["status"]?.stringValue)
            } ?? []
            scheduleRecords = (scheduleValue?.arrayValue ?? []).compactMap(Self.decodeSchedule)
                .filter { $0.sessionID == sessionID }
            if scheduleValue == nil { activityErrors["计划任务"] = "schedule/catalog 未返回数据。" }
            if let goalValue, goalValue != .null {
                let ref = goalValue["goal"] ?? goalValue
                goal = ManagedGoal(id: ref["id"]?.stringValue ?? "",
                                   revision: ref["revision"]?.intValue ?? 0,
                                   objective: ref["objective"]?.stringValue ?? "",
                                   phase: ref["phase"]?.stringValue ?? "unknown",
                                   roundsStarted: goalValue["roundsStarted"]?.intValue ?? 0,
                                   maxGoalRounds: ref["maxGoalRounds"]?.intValue ?? 0)
            } else {
                goal = nil
            }
            jobs = await readJobs(sessionID: sessionID, using: client)
        } catch {
            activityErrors["运行活动"] = error.localizedDescription
        }
    }

    private func decodeActivityProjections(_ values: JSONValue) {
        let plan = values["plan"]
        planActive = plan?["active"]?.boolValue
        planPending = plan?["pending"]?.boolValue ?? false
        todos = (values["todos"]?.arrayValue ?? []).enumerated().compactMap { index, row in
            guard let content = row["content"]?.stringValue else { return nil }
            return ActivityRow(id: String(index), title: content, detail: "", status: row["status"]?.stringValue)
        }
        let goalValue = values["goal"]?["goal"]
        if let goalValue, goalValue != .null {
            goal = ManagedGoal(id: goalValue["id"]?.stringValue ?? "",
                               revision: goalValue["revision"]?.intValue ?? 0,
                               objective: goalValue["objective"]?.stringValue ?? "",
                               phase: goalValue["phase"]?.stringValue ?? "unknown",
                               roundsStarted: values["goal"]?["roundsStarted"]?.intValue ?? 0,
                               maxGoalRounds: goalValue["maxGoalRounds"]?.intValue ?? 0)
        } else { goal = nil }
        subagents = (values["subagentCatalog"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            return ActivityRow(id: id,
                               title: row["label"]?.stringValue ?? "子 Agent \(id.prefix(8))",
                               detail: "\(row["mode"]?.stringValue ?? "unknown") · \(id)", status: row["mode"]?.stringValue)
        }
    }

    private func readJobs(sessionID: String, using client: any DSHRemoteTransport) async -> [ActivityRow] {
        do {
            let mux = try await client.openMux()
            defer { Task { await mux.close() } }
            let streamID = "jobs-\(UUID().uuidString)"
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string(streamID),
                "endpoint": .string("job/list"),
                "payload": .object(["args": .object(["request": .object(["sessionId": .string(sessionID)])])]),
            ]))
            while let frame = try await mux.receive() {
                guard frame["streamId"]?.stringValue == streamID else { continue }
                switch frame["type"]?.stringValue {
                case "error": throw ManagementError.remoteStream(frame["error"]?["message"]?.stringValue ?? "DSH job stream failed")
                case "end": return []
                case "item":
                    let value = frame["value"] ?? .null
                    if value["type"]?.stringValue == "rows" {
                        return (value["jobs"]?.arrayValue ?? []).compactMap { job in
                            guard let id = job["id"]?.stringValue else { return nil }
                            return ActivityRow(id: id, title: job["label"]?.stringValue ?? id,
                                               detail: job["kind"]?.stringValue ?? "job",
                                               status: job["status"]?.stringValue)
                        }
                    }
                default: continue
                }
            }
            return []
        } catch {
            activityErrors["Background jobs"] = error.localizedDescription
            return []
        }
    }

    func mutateGoal(_ operation: String, sessionID: String, goal: ManagedGoal) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("goals/\(operation)", args: .object([
                "sessionId": .string(sessionID),
                "ref": .object(["id": .string(goal.id), "revision": .number(Double(goal.revision))]),
            ]))
            await refreshActivity(sessionID: sessionID)
        } catch { activityErrors["Goal"] = error.localizedDescription }
    }

    func deleteSchedule(_ row: ActivityRow, sessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("schedule/delete", args: .object(["request": .object([
                "id": .string(row.id), "sessionId": .string(sessionID),
            ])]))
            await refreshActivity(sessionID: sessionID)
        } catch { activityErrors["计划任务"] = error.localizedDescription }
    }

    func deleteSchedule(_ schedule: ManagedSchedule) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("schedule/delete", args: .object(["request": .object([
                "id": .string(schedule.id), "sessionId": .string(schedule.sessionID),
            ])]))
            await refreshAutomations()
        } catch { self.error = error.localizedDescription }
    }

    func killJob(_ row: ActivityRow, sessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("job/kill", args: .object(["request": .object([
                "jobId": .string(row.id), "sessionId": .string(sessionID),
            ])]))
            jobs = await readJobs(sessionID: sessionID, using: transport)
        } catch { activityErrors["Background jobs"] = error.localizedDescription }
    }

    func interruptSubagent(_ row: ActivityRow, parentSessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("subagents/interruptByParent", args: .object([
                "childSessionId": .string(row.id), "parentSessionId": .string(parentSessionID), "mode": .string("continuable"),
            ]))
            notice = "已向子 Agent 发送中断请求"
        } catch { activityErrors["子 Agent"] = error.localizedDescription }
    }

    func createSchedule(sessionID: String, title: String, prompt: String, afterSeconds: Int) async -> Bool {
        await createSchedule(request: [
            "sessionId": .string(sessionID),
            "title": .string(title),
            "prompt": .string(prompt),
            "after_seconds": .number(Double(afterSeconds)),
        ])
    }

    func createSchedule(request: [String: JSONValue]) async -> Bool {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("phone/createSchedule", args: .object(["request": .object(request)]))
            await refreshAutomations()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func refreshAutomations() async {
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await ChatModel.shared.transportForManagement()
                transport = client
            }
            async let schedulesResponse = try? client.call("schedule/catalog", args: .object([:]))
            async let toolsResponse = try? client.call("phone/listTools", args: .object([:]))
            let (schedulesValue, toolsValue) = await (schedulesResponse, toolsResponse)
            var failures: [String] = []
            if let schedulesValue {
                scheduleRecords = schedulesValue.arrayValue?.compactMap(Self.decodeSchedule) ?? []
            } else {
                failures.append("DSH schedule catalog is unavailable.")
            }
            if let toolsValue {
                tools = toolsValue["tools"]?.arrayValue?.compactMap { row in
                    guard let name = row["name"]?.stringValue else { return nil }
                    return ManagedTool(id: name, description: row["description"]?.stringValue ?? "")
                } ?? []
            } else {
                failures.append("DSH tool inventory is unavailable.")
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
    }

    func updateSchedule(_ schedule: ManagedSchedule, title: String, prompt: String, timing: JSONValue? = nil) async -> Bool {
        do {
            guard let transport else { throw ManagementError.notConnected }
            var request: [String: JSONValue] = [
                "sessionId": .string(schedule.sessionID),
                "id": .string(schedule.id),
                "expected": schedule.expectedRecord,
                "title": .string(title),
                "prompt": .string(prompt),
            ]
            if let timing { request["change"] = timing }
            let result = try await transport.call("schedule/update", args: .object(["request": .object(request)]))
            if result["updated"]?.boolValue == false {
                error = "计划任务已变化或停止，请刷新后再编辑。"
                return false
            }
            await refreshAutomations()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func loadScheduleHistory(_ schedule: ManagedSchedule, before: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let cursor = scheduleHistorySessionID == schedule.id ? before : nil
            if cursor == nil {
                scheduleHistorySessionID = schedule.id
                scheduleHistory = []
                scheduleHistoryCursor = nil
                scheduleHistoryHasMore = false
                scheduleHistoryNotice = nil
            }
            var request: [String: JSONValue] = [
                "sessionId": .string(schedule.sessionID),
                "id": .string(schedule.id),
                "limit": .number(50),
            ]
            if let cursor { request["before"] = .string(cursor) }
            let result = try await transport.call("schedule/history", args: .object(["request": .object(request)]))
            guard result["code"] == nil else {
                scheduleHistory = []
                scheduleHistoryHasMore = false
                scheduleHistoryNotice = "此计划任务不存在，或历史游标已失效。"
                return
            }
            let rows = (result["records"]?.arrayValue ?? []).compactMap { row -> ManagedDelivery? in
                guard let id = row["messageId"]?.stringValue else { return nil }
                return ManagedDelivery(id: id,
                                       scheduledAt: row["scheduledAt"]?.stringValue ?? "",
                                       deliveredAt: row["deliveredAt"]?.stringValue ?? "",
                                       prompt: row["prompt"]?.stringValue)
            }
            if cursor == nil { scheduleHistory = rows }
            else { scheduleHistory.append(contentsOf: rows) }
            scheduleHistoryCursor = result["nextBefore"]?.stringValue
            scheduleHistoryHasMore = scheduleHistoryCursor != nil
            scheduleHistoryNotice = result["earlierRecordsUnavailable"]?.boolValue == true
                ? "部分较早记录不可用（保留期或旧版本数据）。"
                : nil
        } catch { self.error = error.localizedDescription }
    }

    func loadToolInventory() async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("phone/listTools", args: .object([:]))
            tools = result["tools"]?.arrayValue?.compactMap { row in
                guard let name = row["name"]?.stringValue else { return nil }
                return ManagedTool(id: name, description: row["description"]?.stringValue ?? "")
            } ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func archive(_ session: ManagedSession, stopActivity: Bool = false) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/archiveSession", args: .object(["request": .object([
                "sessionId": .string(session.id), "stopActivity": .bool(stopActivity),
            ])]))
            archivedIDs = Set(result["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            notice = "Session archived"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func unarchive(_ session: ManagedSession) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/unarchiveSession", args: .object(["request": .object(["sessionId": .string(session.id)])]))
            archivedIDs = Set(result["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            notice = "Session restored"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func observeWorkspaceState(using client: any DSHRemoteTransport) async {
        guard workspaceTask == nil else { return }
        do {
            let mux = try await client.openMux()
            workspaceMux = mux
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string("workspace"),
                "endpoint": .string("workspace/follow"),
                "payload": .object(["args": .object([:])]),
            ]))
            workspaceTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        guard let frame = try await mux.receive() else { break }
                        guard frame["streamId"]?.stringValue == "workspace",
                              frame["type"]?.stringValue == "item",
                              let value = frame["value"] else { continue }
                        await self?.applyWorkspaceFrame(value)
                    } catch { await self?.setStreamError(error); break }
                }
            }
            // Allow the initial Host baseline to arrive before the refresh returns.
            for _ in 0..<40 where !workspaceBaselineReceived {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { break }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func applyWorkspaceFrame(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            workspaceBaselineReceived = true
            applyWorkspaceBaseline(frame["value"] ?? .null)
        case "replace":
            applyWorkspaceBaseline(frame["value"] ?? .null)
        case "upsert":
            if let workspace = Self.decodeWorkspace(frame["workspace"] ?? .null) { upsertWorkspace(workspace) }
        case "remove":
            if let id = frame["workspaceId"]?.stringValue {
                workspaces.removeAll { $0.id == id }
                workspaceOrder.removeAll { $0 == id }
            }
        case "order":
            workspaceOrder = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case "archived":
            archivedIDs = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case "pinned":
            pinnedSessionIDs = frame["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        default:
            break
        }
    }

    private func applyWorkspaceBaseline(_ value: JSONValue) {
        workspaces = (value["items"]?.arrayValue ?? []).compactMap(Self.decodeWorkspace)
        workspaceOrder = workspaces.map(\.id)
        archivedIDs = Set(value["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        pinnedSessionIDs = value["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func upsertWorkspace(_ workspace: ManagedWorkspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[index] = workspace }
        else {
            workspaces.append(workspace)
            workspaceOrder.append(workspace.id)
        }
    }

    private func latestActivity(in workspace: ManagedWorkspace) -> Date {
        workspace.sessionIDs.compactMap { id in sessions.first(where: { $0.id == id })?.updatedAt }.max()
            ?? .distantPast
    }

    private static func decodeWorkspace(_ value: JSONValue) -> ManagedWorkspace? {
        guard let id = value["workspaceId"]?.stringValue,
              let title = value["title"]?.stringValue,
              let path = value["path"]?.stringValue else { return nil }
        return ManagedWorkspace(id: id, title: title, path: path,
                               sessionIDs: value["sessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    private func setStreamError(_ error: Error) { self.error = error.localizedDescription }
    private var workspaceBaselineReceived = false

    /// Default session names. The host sends no title for a fresh session, so
    /// these are the only names the user ever sees for one.
    static let newSessionName = "新会话"
    static let untitledSessionName = "未命名会话"


private static func decodeSessions(_ value: JSONValue) -> [ManagedSession] {
        (value["items"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            let projected = item["projections"]?["values"]?["title"]?["title"]?.stringValue
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let title = projected
                ?? SessionTitleHints.title(for: id)
                ?? (item["blank"]?.boolValue == true ? "\(Self.newSessionName)" : "\(Self.untitledSessionName)")
            return ManagedSession(
                id: id, title: title,
                // DSH stores wall-clock timestamps in milliseconds (Date.now).
                updatedAt: Date(timeIntervalSince1970: (item["updatedAt"]?.numberValue ?? 0) / 1_000),
                running: item["running"]?.boolValue ?? false,
                blank: item["blank"]?.boolValue ?? false,
                cwd: item["cwd"]?.stringValue,
                parentSessionID: item["parentSessionId"]?.stringValue,
                searchSnippet: nil)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func decodeModelRoutes(_ value: JSONValue) -> [ManagedModelRoute] {
        (value["groups"]?.arrayValue ?? []).flatMap { group in
            (group["models"]?.arrayValue ?? []).compactMap { model in
                guard let modelName = model["id"]?.stringValue else { return nil }
                return ManagedModelRoute(
                    provider: group["id"]?.stringValue ?? "",
                    providerName: group["name"]?.stringValue ?? group["id"]?.stringValue ?? "Provider",
                    model: modelName,
                    reasoningEfforts: model["reasoning"]?["efforts"]?.arrayValue?.compactMap { effort in
                        guard let id = effort["id"]?.stringValue else { return nil }
                        return ManagedReasoningEffort(id: id, name: effort["name"]?.stringValue ?? id)
                    } ?? [],
                    defaultEffort: model["reasoning"]?["defaultEffort"]?.stringValue)
            }
        }
    }

    private static func decodeModelSelection(_ value: JSONValue) -> ManagedModelSelection? {
        guard value != .null,
              let provider = value["provider"]?.stringValue,
              let model = value["model"]?.stringValue else { return nil }
        return ManagedModelSelection(provider: provider, model: model,
                                     reasoningEffort: value["reasoningEffort"]?.stringValue)
    }

    private static func decodeSchedule(_ value: JSONValue) -> ManagedSchedule? {
        guard let id = value["id"]?.stringValue,
              let sessionID = value["sessionId"]?.stringValue,
              let kind = value["kind"]?.stringValue else { return nil }
        var expected: [String: JSONValue] = ["id": .string(id), "kind": .string(kind)]
        for key in ["title", "prompt", "scheduledAt", "afterSeconds", "everySeconds", "time", "timeZone", "expression"] {
            if let field = value[key] { expected[key] = field }
        }
        if let weekdays = value["weekdays"] { expected["weekdays"] = weekdays }
        return ManagedSchedule(id: id, sessionID: sessionID,
                               title: value["title"]?.stringValue ?? "提醒",
                               prompt: value["prompt"]?.stringValue ?? "",
                               kind: kind,
                               scheduledAt: value["scheduledAt"]?.stringValue ?? "",
                               status: value["status"]?.stringValue ?? "active",
                               latestDeliveryAt: value["lastDelivery"]?["deliveredAt"]?.stringValue,
                               expectedRecord: .object(expected))
    }
}

private enum ManagementError: LocalizedError {
    case notConnected
    case invalidResponse
    case openFailed(String?)
    case noActiveSession
    case sessionBusy
    case remoteStream(String)
    var errorDescription: String? {
        switch self {
        // 界面上不出现宿主的英文原话:认不出的只说这一句,原话进诊断。
        case .notConnected: "本地引擎还没起来。"
        case .invalidResponse: "本地引擎这次的回答不完整。"
        case .openFailed: "这个会话打不开。"
        case .noActiveSession: "先打开一个会话,再换它的模型。"
        case .sessionBusy: "这一轮还在跑,等它结束再换会话。"
        case .remoteStream: "这一步没做成,重试一次。"
        }
    }

}

#if DEBUG
// 只给 -uiPreview 用:造 N 个会话和 M 个工作文件夹,不碰宿主,不进正式包。
extension DSHManagementModel {
    /// 只给 -uiPreview 用:把「读不到会话」那一行摆出来,不碰宿主。
    func installPreviewError(_ text: String) { error = text }

    func installPreviewData(sessionCount: Int, workspaceCount: Int = 2) {
        previewDataInstalled = true
        let base = ChatModel.shared.workspaceRoot.path
        workspaces = (0..<max(workspaceCount, 0)).map { index in
            let title = index == 0 ? "项目资料" : "设计稿 \(index)"
            return ManagedWorkspace(id: "preview-ws-\(index)",
                                    title: title,
                                    path: base + "/" + title,
                                    sessionIDs: [])
        }
        let now = Date()
        let count = max(workspaceCount, 1)
        sessions = (0..<sessionCount).map { index in
            ManagedSession(id: "preview-s-\(index)",
                           title: index % 7 == 3 ? "" : "预览会话 \(index + 1)",
                           updatedAt: now.addingTimeInterval(Double(-index) * 3600),
                           running: index == 1,
                           blank: false,
                           cwd: workspaces.isEmpty ? base : workspaces[index % count].path,
                           parentSessionID: nil,
                           searchSnippet: nil)
        }
        for index in workspaces.indices {
            workspaces[index].sessionIDs = sessions
                .filter { $0.cwd == workspaces[index].path }
                .map(\.id)
        }
        workspaceOrder = workspaces.map(\.id)
    }
}
#endif

/// Local, first-prompt title hints.
///
/// DSH fills the `title` projection when its title row runs; until then (or
/// when the phone profile omits it) the drawer would show every row as
/// "新会话". Remember the first prompt per session so the list is readable
/// immediately, and prefer the projection whenever DSH provides one.
enum SessionTitleHints {
    private static let defaultsKey = "phone-dsh.session.title-hints"
    private static let limit = 18

    static func remember(_ prompt: String, for sessionID: String) {
        let line = prompt
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return }
        var hints = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard hints[sessionID] == nil else { return }
        hints[sessionID] = line.count > limit ? String(line.prefix(limit)) + "…" : line
        UserDefaults.standard.set(hints, forKey: defaultsKey)
    }

    static func title(for sessionID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[sessionID]
    }
}
