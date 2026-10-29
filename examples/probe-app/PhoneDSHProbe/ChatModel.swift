// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: interactive chat over the phone host.
//
// The Chat page boots the same `PhoneDSHHost` the scenario runner uses, opens
// one harness session on `/dsh/workspace` and lets a person type prompts and
// watch the agent work: streamed assistant text, every tool call with its
// arguments, every tool result, turn endings and usage. The model credential
// stays on the host side (Keychain → `CredentialProvider`); the Worker only
// ever sees a placeholder key, exactly like the scenario runner.

import Foundation
import Observation
import ProbeKit
import SwiftUI
import UIKit
import CryptoKit
import PhoneDSHAgentCore
import PhoneDSH
import enum PhoneDSHController.DeviceTier
import struct PhoneDSHController.BudgetTable
import struct PhoneDSHController.RestartPolicy
import PhoneDSHEngine
import PhoneDSHShell

// MARK: - Settings persistence

/// Non-model preferences still live in UserDefaults. The model service,
/// endpoint and API key live only in `PhoneModelProviderSettings` (one
/// non-secret document plus the device Keychain); both the native Chat page and
/// the complete Web page read that same authority at every host start. There is
/// no second base-URL/key fallback to keep an old service alive after deletion.
enum ChatSettings {
    private static let egressKey = "chat.egress.allow"
    /// Hosts the Worker may fetch anonymously through the host gateway (exact host names; the gateway has no wildcard).
    static let defaultEgressAllow = "wttr.in, api.open-meteo.com, geocoding-api.open-meteo.com, api.github.com, raw.githubusercontent.com, github.com, pypi.org, files.pythonhosted.org, registry.npmjs.org, cdn.jsdelivr.net, unpkg.com, en.wikipedia.org, zh.wikipedia.org, httpbin.org, example.com"
    /// A single `*` admits every host; the gateway and the credential provider both understand it.
    static let allowAllEgress = "*"
    static var egressAllow: String {
        get { UserDefaults.standard.string(forKey: egressKey) ?? ProcessInfo.processInfo.environment["PDSH_EGRESS_ALLOW"] ?? defaultEgressAllow }
        set { UserDefaults.standard.set(newValue, forKey: egressKey) }
    }

    private static let keepAliveKey = "chat.background.keepalive"
    /// Keep the agent running in the background with a silent audio session
    /// (instead of parking the host). On by default.
    static var backgroundKeepAlive: Bool {
        get { UserDefaults.standard.object(forKey: keepAliveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepAliveKey) }
    }
}

// MARK: - Transcript items

/// One row of the chat transcript.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case context
        case assistant
        /// The model's streamed reasoning for the current step.
        case reasoning
        case toolCall
        case toolResult(isError: Bool)
        case status
    }

    let id: String
    let kind: Kind
    var title: String
    var text: String
    var streaming = false

    init(id: String = UUID().uuidString, kind: Kind, title: String, text: String, streaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.streaming = streaming
    }
}

/// One server-registered command exposed by the active DSH session.
struct NativeCommandDescriptor: Identifiable, Equatable {
    let name: String
    let description: String
    let inputHint: String?
    let acceptsAttachments: Bool
    var id: String { name }
}

/// The immediate canonical Remote acknowledgment for a command invocation.
struct NativeCommandExecution: Identifiable, Equatable {
    let id: String
    let name: String
    let line: String
    let kind: String
    let text: String?
}

/// One durable DSH session journal record shown in the native trajectory ledger.
/// `payload` preserves the original event envelope for detail inspection.
struct NativeTrajectoryEntry: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case systemPrompt, userMessage, steeringMessage, developerMessage, assistantMessage, toolCall, toolResult
        case requestBoundary, compaction, command, sessionBoundary, otherBusiness
        var id: String { rawValue }
    }

    let id: String
    let sessionID: String
    let seq: Int
    let timestamp: Date
    let eventType: String
    let category: Category
    let preview: String
    let payload: JSONValue
}

/// A permission the harness asked for and the person has not answered yet.
struct ChatPermission: Identifiable, Equatable {
    let id: String
    let tool: String
    let summary: String
    /// 这次工具调用的参数,只用来在卡上写相对路径/命令原文;拿不到就是空。
    var arguments: [String: String] = [:]
}

/// One current-session permission mode returned by the active DSH Worker.
struct NativeAccessMode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
}

/// UI wording for permission modes, keyed only by the stable catalog id.
/// The host's `name` is deliberately ignored: it can be an internal English
/// code (`danger-full-access`, `workspace-write`) that must never reach the UI.
/// An id without a mapping is not shown at all.
enum AccessModeWording {
    static func title(for id: String) -> String? {
        switch id {
        // 名字只翻成中文,不合并档位、不改宿主的顺序;翻不出中文的一律不露代号。
        case "read-only", "phone-read-only": return "仅可查看"
        case "workspace-write", "phone": return "工作区内修改"
        case "danger-full-access", "bypassPermissions": return "完全权限"
        case "auto": return "自动判断"
        case "plan": return "只出方案"
        case "acceptEdits": return "改前不问"
        default: return nil
        }
    }

    /// 只能拿来报状态、不能给人选的两档:当前组合没匹配上任何预设时的那一格。
    static func statusText(forCurrent id: String?) -> String? {
        guard let id else { return nil }
        if id == "custom" { return "自定义 · 当前" }
        return title(for: id) == nil ? "其它模式 · 当前" : nil
    }

    /// 没有命名映射的模式(落到「其它模式」),菜单里选它之前先说明一句。
    static func isUnnamed(_ id: String) -> Bool { title(for: id) == "其它模式" }

    /// Extra sentence for the modes that widen what the agent may do without
    /// asking. Keyed by the same ids so both ids that mean 全部放开 share one
    /// sentence.
    static func confirmationMessage(for id: String) -> String? {
        switch id {
        case "bypassPermissions", "danger-full-access":
            return "之后改文件、跑命令都不再问你。"
        case "acceptEdits":
            return "开了之后，改文件不再问，跑命令还会问。"
        default:
            // 未命名的模式:选它之前把「这是它自己决定的」说清楚。
            return title(for: id) == "其它模式"
                ? "这个模式没在这个版本里命名,行为由它自己决定。"
                : nil
        }
    }
}

/// One file under the materialized workspace.
struct WorkspaceFile: Identifiable, Hashable {
    let relativePath: String
    let size: Int
    var id: String { relativePath }
}

// MARK: - Model

/// Owns the host, the harness session and the transcript. One instance per app
/// launch; the page observes it.
@MainActor
@Observable
final class ChatModel {
    static let shared = ChatModel()

    /// 参数只取一层标量,拼成 [键:字符串];嵌套结构换成 JSON 文本,够卡上用。
    static func flattenedArguments(_ value: JSONValue) -> [String: String] {
        guard let object = value.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, item) in object {
            if let string = item.stringValue { result[key] = string }
            else if let number = item.numberValue { result[key] = String(describing: number) }
            else if let data = try? item.encoded(), let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    private static let currentSessionDefaultsKey = "chat.dsh.currentSessionID"
    private static let retryableRequestIDsDefaultsKey = "chat.dsh.retryableRequestIDs"

    /// Visible one-point anchor the Chat page embeds; WebKit needs the page in
    /// a window for the Worker to run (G2-FIX-21).
    let anchor = VisibleEngineAnchor()

    /// Display label for the model the selected provider asked the DSH
    /// session to use. The provider document itself is the source of truth;
    /// this value is refreshed from it whenever the host starts.
    var modelName = ""
    var egressAllow = ChatSettings.egressAllow
    var backgroundKeepAlive = ChatSettings.backgroundKeepAlive

    private(set) var hostState = "stopped"
    private var lastPrompt: (String, [HarnessAttachment])?
    private(set) var statusLine = "Host not started"
    private(set) var busy = false
    private(set) var turnRunning = false
    private(set) var userFacingError: String?
    /// Non-secret, user-facing explanation of the last search launch decision.
    /// A normal first launch without a model service leaves this nil.
    private(set) var searchLaunchWarning: String?
    /// Exact MCP admission/credential policy for this host. The native MCP
    /// editor and the Web bridge update the same object in place.
    private(set) var mcpAccessPolicy = MCPEgressPolicy()
    private(set) var items: [ChatItem] = []
    private(set) var transcriptHasMore = false
    private(set) var transcriptError: String?
    private(set) var trajectoryEntries: [NativeTrajectoryEntry] = []
    private(set) var trajectoryHasMore = false
    private(set) var trajectoryError: String?
    private(set) var availableCommands: [NativeCommandDescriptor] = []
    private(set) var commandsLoading = false
    private(set) var commandsError: String?
    private(set) var pendingPermission: ChatPermission?
    /// 工具名到最近一次参数:权限请求本身不带参数,靠这层对上这次调用。
    private var recentToolArguments: [String: [String: String]] = [:]
    private(set) var pendingQuestion: HarnessQuestion?
    private(set) var availableAccessModes: [NativeAccessMode] = []
    private(set) var currentAccessMode: String?
    private(set) var accessModeError: String?
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var modelRequests = 0
    /// 这次引擎起来的时间点,「运行状态」第一行要报「已运行多久」;停掉就清空。
    private(set) var startedAt: Date?
    private(set) var files: [WorkspaceFile] = []
    private(set) var previewPath: String?
    private(set) var previewText: String?

    var isStarted: Bool { host != nil }
    /// True between the background park and the foreground resume (D14).
    private(set) var parked = false
    /// True while the app is in the background and the silent audio session
    /// keeps the host (and, if WebKit cooperates, the Worker) running.
    private(set) var keepingAlive = false

    private var host: PhoneDSHHost?
    private let keepAlive = SilentAudioKeepAlive()
    private var backgroundHeartbeat: Task<Void, Never>?
    /// Harness events handled so far; the background heartbeat logs the delta
    /// so the status log shows whether the Worker made progress while hidden.
    private var eventsHandled = 0
    /// Keeps the process alive while the host drains and parks after the
    /// app left the foreground (the drain window is up to `drainDeadline`).
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var harness: (any AgentHarness)?
    private var sessionID: String?
    var currentSessionID: String? { sessionID }
    private var transcriptReady = false
    var isTranscriptReady: Bool { transcriptReady }
    /// The last transcript is on screen from disk while the engine boots.
    private(set) var isShowingCachedTranscript = false
    private var transcriptThroughSeq: Int?
    private var transcriptBeforeSeq: Int?
    private var hostLifecycleTransition = false
    // Planned-restart policy (see RestartPolicy): one sample per minute,
    // executed only at a tool-call boundary.
    private var restartPolicyTask: Task<Void, Never>?
    private var restartPolicyHighSamples = 0
    private var restartPolicySawTermination = false
    private var restartPolicyBudget: BudgetTable?
    private var foregroundResumeRequested = false
    private var backgroundParkRequested = false
    private(set) var modelProviderIssue: String? = "请先配置模型服务和 API Key"
    var canSend: Bool { modelProviderIssue == nil && harness != nil && sessionID != nil && transcriptReady && !busy && !parked && !hostLifecycleTransition }

    /// Cache only readiness for the UI; recheck the Keychain before dispatching a message.
    func refreshModelProviderReadiness() {
        let settings = PhoneModelProviderSettings.shared
        do {
            guard let profile = try settings.load().selected else {
                modelProviderIssue = "请先配置模型服务和 API Key"
                return
            }
            switch try settings.apiKeyStatus(for: profile.id) {
            case .present: modelProviderIssue = nil
            case .missing: modelProviderIssue = "请先配置模型服务的 API Key"
            case .unreadable: modelProviderIssue = "无法读取 API Key，请解锁设备后重试"
            }
        } catch {
            modelProviderIssue = "无法读取模型服务配置，请检查设置"
        }
    }
    var displayStatus: String {
        if parked { return "已暂停" }
        if host == nil { return "已停止" }
        if userFacingError != nil || hostState.lowercased().contains("fail") { return "失败" }
        if busy || hostLifecycleTransition { return "处理中" }
        if pendingQuestion != nil || pendingPermission != nil { return "等待回复" }
        if turnRunning { return "运行中" }
        if transcriptReady { return "运行中" }
        return "未连接"
    }
    var canSteer: Bool { modelProviderIssue == nil && harness != nil && sessionID != nil && transcriptReady && turnRunning && !busy && !parked && !hostLifecycleTransition }
    private var pumpTask: Task<Void, Never>?
    private var hostEventTask: Task<Void, Never>?
    private var lastSeq: UInt64?
    private var trajectoryThroughSeq: Int?
    private var trajectoryBeforeSeq: Int?
    private var trajectoryRefreshTask: Task<Void, Never>?
    private(set) var lastCommandExecution: NativeCommandExecution?

    func clearError() { userFacingError = nil }

    /// Read the active Worker catalog and this Session's durable permission fold.
    /// Missing Remote support stays explicit instead of being replaced by a local default.
    func refreshAccessModes() async {
        guard let sessionID else {
            availableAccessModes = []
            currentAccessMode = nil
            accessModeError = "本地引擎还没启动,启动之后才能看权限。"
            return
        }
        do {
            let transport = try await transportForManagement()
            async let catalogCall = transport.call("permissionPresets/catalog", args: .object([:]))
            async let projectionCall = transport.call("session/projections", args: .object([
                "request": .object(["sessionId": .string(sessionID)]),
            ]))
            let (catalog, projections) = try await (catalogCall, projectionCall)
            guard self.sessionID == sessionID else { return }
            availableAccessModes = (catalog["options"]?.arrayValue ?? []).compactMap { option in
                guard let id = option["value"]?.stringValue,
                      let name = option["name"]?.stringValue else { return nil }
                return NativeAccessMode(id: id, name: name,
                                        description: option["description"]?.stringValue)
            }
            guard let current = projections["values"]?["permissions"]?["currentValue"]?.stringValue else {
                currentAccessMode = nil
                accessModeError = "没读到权限,再试一次。"
                return
            }
            currentAccessMode = current
            accessModeError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            availableAccessModes = []
            currentAccessMode = nil
            accessModeError = "没读到权限,再试一次。"
        }
    }

    /// Switch this Session using DSH's canonical `/permission` command, then
    /// verify the committed value through the Session projection.
    func selectAccessMode(_ id: String) async -> Bool {
        guard let sessionID else {
            accessModeError = "本地引擎还没启动,启动之后才能改权限。"
            return false
        }
        guard id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              availableAccessModes.contains(where: { $0.id == id }) else {
            accessModeError = "这一档现在选不了。"
            return false
        }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("commands/execute", args: .object([
                "agentId": .string(sessionID),
                "line": .string("/permission \(id)"),
                "submittedAttachments": .array([]),
            ]))
            guard self.sessionID == sessionID else { return false }
            guard response["result"]?["kind"]?.stringValue == "success" else {
                accessModeError = "没改成这一档,再试一次。"
                return false
            }
            await refreshAccessModes()
            return self.sessionID == sessionID && currentAccessMode == id
        } catch {
            guard self.sessionID == sessionID else { return false }
            accessModeError = "没读到权限,再试一次。"
            return false
        }
    }

    /// Fetch the command descriptors registered for this exact DSH session.
    /// Names and hints come from the Worker command registry, never a local list.
    func loadCommands() async {
        guard let sessionID else {
            availableCommands = []
            commandsError = "本地引擎还没启动,启动之后才能看命令。"
            return
        }
        commandsLoading = true
        defer { commandsLoading = false }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("commands/list", args: .object([
                "agentId": .string(sessionID),
            ]))
            guard self.sessionID == sessionID else { return }
            let rows = response.arrayValue
                ?? response["commands"]?.arrayValue
                ?? response["value"]?.arrayValue
                ?? []
            availableCommands = rows.compactMap { row in
                guard let name = row["name"]?.stringValue,
                      !name.isEmpty,
                      let description = row["description"]?.stringValue else { return nil }
                return NativeCommandDescriptor(name: name, description: description,
                                               inputHint: row["input"]?["hint"]?.stringValue,
                                               acceptsAttachments: row["input"]?["attachments"]?.boolValue ?? false)
            }
            commandsError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            availableCommands = []
            commandsError = "没执行成功,再试一次。"
        }
    }

    /// Execute one command admitted by the live DSH registry. Returned text is
    /// kept as a UI result; durable command/run and command/done records are
    /// separately refreshed into the trajectory ledger.
    @discardableResult
    func executeCommand(name: String, input: String = "",
                        attachments: [HarnessAttachment] = []) async -> NativeCommandExecution? {
        guard let sessionID, !parked, !hostLifecycleTransition,
              let descriptor = availableCommands.first(where: { $0.name == name }) else {
            commandsError = "这条命令现在用不了。"
            return nil
        }
        guard attachments.isEmpty || descriptor.acceptsAttachments else {
            commandsError = "这条命令不能带附件。"
            return nil
        }
        let line = "/\(descriptor.name)" + (input.isEmpty ? "" : " \(input)")
        do {
            let transport = try await transportForManagement()
            let submittedAttachments: [JSONValue] = attachments.map { attachment in
                .object(["type": .string("image"), "mediaType": .string(attachment.mimeType),
                         "data": .string(attachment.data.base64EncodedString()), "name": .string(attachment.name)])
            }
            let response = try await transport.call("commands/execute", args: .object([
                "agentId": .string(sessionID),
                "line": .string(line),
                "submittedAttachments": .array(submittedAttachments),
            ]))
            guard self.sessionID == sessionID else { return nil }
            let result = response["result"] ?? .null
            guard let kind = result["kind"]?.stringValue else {
                commandsError = "The DSH command Remote returned no execution result."
                return nil
            }
            let execution = NativeCommandExecution(
                id: response["commandId"]?.stringValue ?? UUID().uuidString,
                name: descriptor.name, line: line, kind: kind,
                text: result["text"]?.stringValue)
            lastCommandExecution = execution
            commandsError = kind == "error" ? (execution.text ?? "Command failed.") : nil
            await refreshTrajectory()
            return execution
        } catch {
            guard self.sessionID == sessionID else { return nil }
            commandsError = "没执行成功,再试一次。"
            return nil
        }
    }

    /// Durable session journal entries in ascending DSH sequence order.
    /// The record envelope and payload are preserved for native detail views.
    func refreshTrajectory() async {
        guard let sessionID else {
            trajectoryEntries = []
            trajectoryHasMore = false
            trajectoryError = "Start a DSH session to read its trajectory."
            return
        }
        do {
            let transport = try await transportForManagement()
            let cursor = try await currentJournalCursor(sessionID: sessionID, transport: transport)
            guard self.sessionID == sessionID else { return }
            guard cursor >= 0 else {
                trajectoryEntries = []
                trajectoryThroughSeq = nil
                trajectoryBeforeSeq = nil
                trajectoryHasMore = false
                trajectoryError = nil
                return
            }
            let request: [String: JSONValue] = [
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ]
            let page = try await transport.call("session/page", args: .object(["request": .object(request)]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            let fresh = Self.trajectoryEntries(from: events, sessionID: sessionID)
            let hadOlderLoaded = trajectoryBeforeSeq != nil && trajectoryEntries.count > fresh.count
            var byID = Dictionary(uniqueKeysWithValues: trajectoryEntries.map { ($0.id, $0) })
            for entry in fresh { byID[entry.id] = entry }
            trajectoryEntries = byID.values.sorted { $0.seq < $1.seq }
            trajectoryThroughSeq = cursor
            trajectoryHasMore = hadOlderLoaded || (page["hasMore"]?.boolValue ?? false)
            trajectoryBeforeSeq = events.compactMap { $0["seq"]?.intValue }.min()
            trajectoryError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            trajectoryError = error.localizedDescription
        }
    }

    /// Prepend one older page from the authoritative Session journal.
    func loadEarlierTrajectory() async {
        guard trajectoryHasMore, let sessionID, let throughSeq = trajectoryThroughSeq,
              let beforeSeq = trajectoryBeforeSeq else { return }
        do {
            let transport = try await transportForManagement()
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(60),
            ])]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            guard let nextBeforeSeq = events.compactMap({ $0["seq"]?.intValue }).min(),
                  nextBeforeSeq < beforeSeq else {
                trajectoryHasMore = false
                trajectoryError = "The DSH history page did not advance before seq \(beforeSeq)."
                return
            }
            let older = Self.trajectoryEntries(from: events, sessionID: sessionID)
            let existingIDs = Set(trajectoryEntries.map(\.id))
            trajectoryEntries = (older.filter { !existingIDs.contains($0.id) } + trajectoryEntries)
                .sorted { $0.seq < $1.seq }
            trajectoryBeforeSeq = nextBeforeSeq
            trajectoryHasMore = page["hasMore"]?.boolValue ?? false
            trajectoryError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            trajectoryError = error.localizedDescription
        }
    }

    /// Reload the committed MCP grants into the live policy after the native
    /// editor changes a route or credential.
    func refreshMCPAccessPolicy() {
        PhoneMCPAccessSettings.shared.apply(to: mcpAccessPolicy)
    }

    /// Returns the host's DSH RPC transport for session-management surfaces.
    func transportForManagement() async throws -> any DSHRemoteTransport {
        guard let host else { throw ProbeHostError.notStarted }
        return try await host.makeTransport()
    }

    let workspaceRoot: URL = ChatHostConfiguration.workspaceRoot()

    private var materializedWorkspace: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// The materialized workspace directory: what the browser lists and the
    /// PAGE surface serves from `pdsh-page://<session>/...`.
    var workspaceDirectoryURL: URL { materializedWorkspace }

    /// A file's owning workspace: the page origin must be that workspace's
    /// directory, and the path must be relative to it.
    struct PageWorkspaceOwner {
        let sessionID: String
        let relativePath: String
    }

    /// Finds the workspace that owns `relativePath` (relative to
    /// `/dsh/workspace`) and a session of it. The longest workspace directory
    /// wins; a workspace registered at `/dsh/workspace` owns every path.
    func pageWorkspaceOwner(for relativePath: String) -> PageWorkspaceOwner? {
        let workspaces = DSHManagementModel.shared.workspaces.map {
            (path: $0.path, sessionIDs: $0.sessionIDs)
        }
        guard let owner = PDSHPageWorkspaceMap.owner(relativePath: relativePath,
                                                    workspaces: workspaces) else {
            return nil
        }
        return PageWorkspaceOwner(sessionID: owner.sessionID,
                                  relativePath: owner.relativePath)
    }

    /// sessionID → the materialized directory its page origin serves. The
    /// host supports several workspaces (`workspace/create`, `workspace/follow`),
    /// and each record's `path` is its sessions' cwd: `/dsh/workspace/proj2`
    /// serves `materialized/workspace/proj2`, so two workspaces with the same
    /// file name do not read each other's bytes. A session the host does not
    /// list stays unmapped (the handler then refuses the URL).
    func pageWorkspaceMap() -> [String: URL] {
        let root = workspaceDirectoryURL
        var map = PDSHPageWorkspaceMap.directories(
            root: root,
            workspaces: DSHManagementModel.shared.workspaces.map {
                (path: $0.path, sessionIDs: $0.sessionIDs)
            })
        if let sessionID = currentSessionID, map[sessionID] == nil {
            map[sessionID] = root
        }
        return map
    }

    private var materializedHome: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    // MARK: Lifecycle

    func start() async {
        refreshModelProviderReadiness()
        guard host == nil, !busy else { return }
        busy = true
        defer { busy = false }
        guard let bundle = WorkerBundleLocator.bundle() else {
            reportError("引擎停了")
            return
        }
        guard anchor.isInWindow else {
            reportError("The page anchor is not in a window yet; try again")
            return
        }
        do {
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        } catch {
            reportError("Cannot create the workspace: \(error)")
            return
        }

        let egressHosts = Set(egressAllow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        // The provider document is the only model configuration authority.
        // It is read at every start, so deleting or switching a service can
        // never leave the previous endpoint/key active in this process. A
        // missing selection still boots the complete Web surface: model calls
        // fail later with the host credential provider's unauthorized error,
        // and Settings → 模型服务 stays reachable.
        var selectedProfile: ProviderProfile?
        var allowedModelHosts = Set<String>()
        var credentialProvider: any CredentialProvider = PhoneModelProviderSettings.shared
            .makeEgressOnlyCredentialProvider(egressAllowHosts: egressHosts)
        var environment: [String: String] = [
            // The host gateway injects the real key; the Worker never holds it.
            "DEEPSEEK_API_KEY": "phone-host-injects-key",
            "DSH_TELEMETRY_DISABLED": "1",
        ]
        do {
            let settings = PhoneModelProviderSettings.shared
            let snapshot = try settings.load()
            if let profile = snapshot.selected {
                var plan = ModelProviderLaunchPlan()
                try settings.apply(to: &plan, egressAllowHosts: egressHosts)
                selectedProfile = profile
                allowedModelHosts = plan.allowedModelHosts
                credentialProvider = plan.credentialProvider
                environment.merge(plan.environment) { _, new in new }
                modelName = profile.model
            } else {
                modelName = ""
            }
        } catch {
            modelName = ""
            appendStatus("Model service settings are invalid; booting without a model route: \(error.localizedDescription)")
        }
        // The same independent-search plan the Web surface uses: independent
        // mode adds its exact gateway host rule and wraps only the search
        // paths with the dedicated Keychain; follow-model is limited to the
        // official DeepSeek Messages endpoint the shipped provider supports.
        var launchPlan = ModelProviderLaunchPlan(allowedModelHosts: allowedModelHosts,
                                                 credentialProvider: credentialProvider,
                                                 environment: environment)
        let searchPlan = WebSearchHostConfiguration.apply(to: &launchPlan,
                                                          modelProfile: selectedProfile)
        allowedModelHosts = launchPlan.allowedModelHosts
        credentialProvider = launchPlan.credentialProvider
        environment = launchPlan.environment
        searchLaunchWarning = searchPlan.warning
        if let warning = searchLaunchWarning {
            appendStatus("Web search: \(warning)")
        }
        PhoneMCPAccessSettings.shared.reconcile(materializedHome: materializedHome)
        let mcpPolicy = MCPHostConfiguration.apply(to: &launchPlan,
                                                   settings: .shared)
        mcpAccessPolicy = mcpPolicy
        allowedModelHosts = launchPlan.allowedModelHosts
        credentialProvider = launchPlan.credentialProvider
        environment = launchPlan.environment
        // Model POSTs keep the gateway's 429/5xx backoff; egress POSTs do not
        // (PR #1 review finding). Only the selected profile's standard model
        // endpoints are replay-safe, so expand its base URL here.
        let replaySafeModelEndpoints = selectedProfile?.endpointURL
            .map { PhoneDSHConfiguration.standardModelEndpoints(baseURL: $0) } ?? []
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            // Budgets follow the device: the 12 GiB row is selected only at or
            // above 12 GiB (budgets.md §4).
            deviceTier: DeviceTier.forPhysicalMemory(ProcessInfo.processInfo.physicalMemory),
            bundle: bundle,
            allowedModelHosts: allowedModelHosts,
            egressAllowHosts: egressHosts,
            replaySafeModelEndpoints: replaySafeModelEndpoints,
            credentialProvider: credentialProvider,
            egressAuthorizer: mcpPolicy,
            drainDeadline: ChatHostConfiguration.defaultDrainDeadline,
            helloTimeout: ChatHostConfiguration.defaultHelloTimeout)
        // One line states what the host actually enforces. The Worker's
        // published manifest can lag behind a rebuilt bundle; this is the
        // number the write path uses.
        appendStatus("Engine budgets: tier=\(configuration.deviceTier) "
            + "workspace=\(configuration.budgets.workspaceBytes / 1_048_576) MiB "
            + "vfs=\(configuration.budgets.vfsLogicalBytes / 1_048_576) MiB "
            + "single=\(configuration.budgets.singleFileBytes / 1_048_576) MiB "
            + "hot=\(configuration.budgets.wasiHotInstanceBytes / 1_048_576) MiB")
        // Publish the real read-only accelerators only when the linked Rust
        // library advertises them. Without the XCFramework `acceleratorNames`
        // is empty, so the host keeps advertising none instead of faking a
        // capability. `phone`/`ctx` are registered by the library but need an
        // injected PhoneToolBridge (there is no MCP bridge in this host yet),
        // so `channelAcceleratorNames` keeps them out of the host HELLO and the
        // EXEC_REQ whitelist instead of advertising commands that would exit 69.
        let shell = PDSHShellProvider(materializedWorkspace: materializedWorkspace,
                                      materializedHome: materializedHome)
        if !shell.acceleratorNames.isEmpty {
            configuration.accelerators = shell
            let names = shell.channelAcceleratorNames
            if !names.isEmpty {
                configuration.acceleratorNames = names
            }
        }
        configuration.engine.bootTimeout = ChatHostConfiguration.defaultBootTimeout
        configuration.engine.environment = environment
        let anchor = self.anchor
        let newHost = PhoneDSHHost(configuration: configuration, engineFactory: { configuration in
            await anchor.makeEngine(configuration)
        })
        // Show the last conversation from disk immediately; the engine boots
        // in the background and replaces it when the host history arrives.
        restoreCachedTranscriptIfAvailable()
        statusLine = "Booting the Worker…"
        appendStatus("Booting the host (Worker bundle + image)…")
        observeHost(newHost)
        do {
            try await newHost.start()
        } catch {
            Self.appendDiagnostic("host start failed: \(error)")
            reportError("引擎停了：\(Self.condensed(String(describing: error)))")
            hostEventTask?.cancel(); hostEventTask = nil
            return
        }
        host = newHost
        startedAt = Date()
        restartPolicyBudget = configuration.budgets
        startRestartPolicyMonitor()
        do {
            let harness = try await newHost.harness()
            self.harness = harness
            let requestedSessionID = UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey)
            let session = try await harness.openSession(HarnessSessionRequest(
                sessionID: requestedSessionID, workspace: "/dsh/workspace"))
            resetSessionLedgers()
            self.sessionID = session.id
            UserDefaults.standard.set(session.id, forKey: Self.currentSessionDefaultsKey)
            lastSeq = nil
            let transport = try await newHost.makeTransport()
            if let selectedProfile {
                do {
                    try await selectProviderModel(selectedProfile, sessionID: session.id, transport: transport)
                } catch {
                    appendStatus("The provider model could not be selected for this session: \(error.localizedDescription)")
                }
            }
            let history: SessionHistory
            do {
                history = try await loadSessionHistory(sessionID: session.id,
                                                        transport: transport)
                items = history.items
                transcriptHasMore = history.hasMore
                transcriptBeforeSeq = history.beforeSeq
                transcriptThroughSeq = history.throughSeq
                isShowingCachedTranscript = false
                persistTranscriptSnapshot()
            } catch {
                reportError("Session opened, but its DSH history could not be loaded: \(error)")
                transcriptReady = false
                refreshFiles()
                return
            }
            transcriptReady = true
            clearError()
            turnRunning = history.turnRunning
            startPump(harness: harness, sessionID: session.id, after: history.after)
            Task { await self.refreshAccessModes() }
            Task { await self.refreshTrajectory() }
            Task { await self.loadCommands() }
            statusLine = "Session \(session.id.prefix(8)) open — type a task"
            appendStatus("Session \(requestedSessionID == nil ? "created" : "resumed"): \(session.id); egress allow-list: \(egressHosts.isEmpty ? "(none)" : egressHosts.sorted().joined(separator: ", "))")
        } catch {
            reportError("Session failed: \(error)")
        }
        refreshFiles()
    }

    /// Apply the selected provider's model and reasoning effort to the DSH
    /// session. The endpoint/base URL is host configuration, but DSH still
    /// needs the session-local model route: without this call it keeps the
    /// profile default and the user's provider model/effort would be inert.
    private func selectProviderModel(_ profile: ProviderProfile,
                                     sessionID: String,
                                     transport: any DSHRemoteTransport) async throws {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionID),
            // llm-deepseek registers this route; DEEPSEEK_BASE_URL selects
            // the endpoint and the host CredentialProvider supplies its key.
            "provider": .string("deepseek-official"),
            "model": .string(profile.model),
        ]
        if let effort = profile.reasoningEffort, !effort.isEmpty {
            request["reasoningEffort"] = .string(effort)
        }
        _ = try await transport.call("session/selectModel",
                                     args: .object(["request": .object(request)]))
    }

    /// Opens a new session through DSH and makes it the active chat.
    func newSession() async {
        await openManagedSession(id: nil)
    }

    /// Resumes an existing DSH session by its server-issued identifier.
    func selectSession(_ id: String) async {
        let requested = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { reportError("Session ID cannot be empty"); return }
        await openManagedSession(id: requested)
    }

    private func openManagedSession(id: String?) async {
        guard let host else { reportError("Start the host before opening a session"); return }
        guard !busy else { return }
        guard !hostLifecycleTransition else {
            reportError("Wait for the host to finish pausing or resuming before switching sessions")
            return
        }
        guard !turnRunning && !keepingAlive && pendingQuestion == nil && pendingPermission == nil else {
            reportError("Finish the current turn and answer pending requests before switching sessions")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let harness: any AgentHarness
            if let activeHarness = self.harness {
                harness = activeHarness
            } else {
                harness = try await host.harness()
                self.harness = harness
            }
            let session = try await harness.openSession(HarnessSessionRequest(
                sessionID: id, workspace: "/dsh/workspace"))
            let transport = try await transportForManagement()
            if let profile = try? PhoneModelProviderSettings.shared.load().selected {
                try? await selectProviderModel(profile, sessionID: session.id, transport: transport)
            }
            let history = try await loadSessionHistory(sessionID: session.id, transport: transport)
            pumpTask?.cancel()
            resetSessionLedgers()
            self.sessionID = session.id
            UserDefaults.standard.set(session.id, forKey: Self.currentSessionDefaultsKey)
            lastSeq = history.after
            items = history.items
            isShowingCachedTranscript = false
            persistTranscriptSnapshot()
            transcriptHasMore = history.hasMore
            transcriptBeforeSeq = history.beforeSeq
            transcriptThroughSeq = history.throughSeq
            transcriptReady = true
            pendingPermission = nil
            pendingQuestion = nil
            turnRunning = history.turnRunning
            startPump(harness: harness, sessionID: session.id, after: history.after)
            Task { await self.refreshAccessModes() }
            Task { await self.refreshTrajectory() }
            Task { await self.loadCommands() }
            statusLine = "Session \(session.id.prefix(8)) open — type a task"
            clearError()
            appendStatus("Session \(id == nil ? "created" : "resumed"): \(session.id)")
        } catch {
            reportError("Could not \(id == nil ? "create" : "resume") session: \(error)")
        }
    }

    /// Applies a saved model-service change to the running host.
    ///
    /// The host captures its credential provider when it boots, so a key added
    /// while it runs is invisible to the gateway: every model request then
    /// fails with the provider's 401 and the app can only say "密钥不被接受".
    /// Restarting re-reads the provider document and rebinds the key.
    func reloadModelProvider() async {
        refreshModelProviderReadiness()
        guard isStarted, !hostLifecycleTransition else {
            appendStatus("模型服务已保存；引擎下次启动时生效")
            return
        }
        guard !turnRunning else {
            appendStatus("模型服务已保存；当前回合结束后重启引擎生效")
            return
        }
        let previousSession = sessionID
        await stop()
        await start()
        if let previousSession, sessionID != previousSession {
            await selectSession(previousSession)
        }
        appendStatus("模型服务已保存，引擎已重启")
    }

    /// 归档的正好是当前打开的那个会话:把它从页面上摘掉,回到空屏,
    /// 不让用户停在一个已经不在列表里的对话上。不关宿主、不动别的会话。
    func detachArchivedSession() async {
        if let harness, let sessionID { await harness.closeSession(sessionID) }
        harness = nil
        sessionID = nil
        transcriptReady = false
        items = []
        pendingPermission = nil
        pendingQuestion = nil
        turnRunning = false
        startedAt = nil
    }

    func stop() async {
        guard let host else { return }
        guard !busy && !hostLifecycleTransition else {
            reportError("Wait for the current host operation to finish before stopping")
            return
        }
        busy = true
        defer { busy = false }
        pumpTask?.cancel(); pumpTask = nil
        if let harness, let sessionID { await harness.closeSession(sessionID) }
        harness = nil; sessionID = nil
        transcriptReady = false
        pendingPermission = nil; pendingQuestion = nil
        availableAccessModes = []; currentAccessMode = nil; accessModeError = nil
        do { try await host.stop() } catch { reportError("Stop reported: \(error)") }
        hostEventTask?.cancel(); hostEventTask = nil
        self.host = nil
        startedAt = nil
        turnRunning = false
        parked = false
        foregroundResumeRequested = false
        backgroundParkRequested = false
        hostLifecycleTransition = false
        syncIdleTimer()
        statusLine = "Host stopped"
        appendStatus("Host stopped")
    }

    private func resetSessionLedgers() {
        trajectoryRefreshTask?.cancel()
        trajectoryRefreshTask = nil
        trajectoryEntries = []
        trajectoryHasMore = false
        trajectoryError = nil
        trajectoryThroughSeq = nil
        trajectoryBeforeSeq = nil
        transcriptHasMore = false
        transcriptError = nil
        transcriptThroughSeq = nil
        transcriptBeforeSeq = nil
        availableCommands = []
        commandsError = nil
        lastCommandExecution = nil
        availableAccessModes = []
        currentAccessMode = nil
        accessModeError = "正在读取新会话的权限状态。"
    }

    // MARK: Scene phase (D14 park / resume)

    /// Parks the host when the app leaves the foreground and resumes it when
    /// the app is active again. Without this the WKWebView Worker is simply
    /// frozen by iOS mid-turn and every connection it holds dies, so the next
    /// event after returning is an error. A park drains the work in flight
    /// (up to `drainDeadline`, 20 s here) and cancels what is still open; a
    /// resume replays the WAL and the same session continues.
    func scenePhaseChanged(_ phase: ScenePhase) async {
        if phase == .active { refreshModelProviderReadiness() }
        guard let host else { return }
        switch phase {
        case .background:
            if hostLifecycleTransition {
                foregroundResumeRequested = false
                backgroundParkRequested = true
                return
            }
            guard !parked, !keepingAlive else { return }
            beginBackgroundTask()
            // A running turn is kept alive (the user's task continues); an idle
            // host is parked as before, which costs no battery.
            if backgroundKeepAlive && turnRunning {
                keepAlive.onEvent = { [weak self] message in self?.appendStatus(message) }
                do {
                    try keepAlive.start()
                    keepingAlive = true
                    appendStatus("App in background: keeping the agent alive with a silent audio session; the turn continues")
                    startBackgroundHeartbeat()
                    return
                } catch {
                    appendStatus("Keep-alive audio failed (\(error)); parking the host instead")
                }
            }
            await parkHost(host)
        case .active:
            if keepingAlive {
                stopBackgroundHeartbeat()
                keepAlive.stop()
                keepingAlive = false
                appendStatus("Back in the foreground; keep-alive audio stopped")
                endBackgroundTask()
                refreshFiles()
            }
            if hostLifecycleTransition {
                backgroundParkRequested = false
                foregroundResumeRequested = true
                appendStatus("Foreground return queued until the host pause completes")
                return
            }
            guard parked else { return }
            await resumeHost(host)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func parkHost(_ host: PhoneDSHHost) async {
        guard !hostLifecycleTransition else { return }
        hostLifecycleTransition = true
        // Every early return, thrown error or lost continuation must release
        // the flag: while it is set the composer reads "处理中" and every
        // send/session switch/park/resume is refused. The watchdog is the
        // last resort behind the host's own 20 s drain bound.
        let watchdog = transitionWatchdog(seconds: 60, label: "Host park")
        defer {
            watchdog.cancel()
            hostLifecycleTransition = false
        }
        appendStatus("App in background: parking the host (in-flight work gets the drain window, then the turn is cancelled)…")
        do {
            try await host.park()
            parked = true
            appendStatus("Host parked; resume by returning to the app")
        } catch {
            parked = false
            reportError("Park failed: \(error)")
        }
        endBackgroundTask()
        let shouldResume = foregroundResumeRequested
        foregroundResumeRequested = false
        let shouldParkAgain = backgroundParkRequested
        backgroundParkRequested = false
        // Release before the queued follow-up so it passes its own guard.
        hostLifecycleTransition = false
        if shouldResume && parked {
            await resumeHost(host)
        } else if shouldParkAgain && !parked {
            await parkHost(host)
        }
    }

    /// Resumes a parked host from the UI (the drawer opens sessions from any
    /// state). Returns once the resume attempt finished.
    func resumeParkedHost() async {
        guard let host, parked, !hostLifecycleTransition else { return }
        await resumeHost(host)
    }

    private func resumeHost(_ host: PhoneDSHHost) async {
        guard parked, !hostLifecycleTransition else { return }
        hostLifecycleTransition = true
        // See parkHost: the flag must never stay set. A resume waits for the
        // host's own 240 s hello timeout, so the watchdog clears only past it.
        let watchdog = transitionWatchdog(seconds: 300, label: "Host resume")
        defer {
            watchdog.cancel()
            hostLifecycleTransition = false
        }
        do {
            try await host.resume()
            parked = false
            appendStatus("Host resumed; the session continues from the WAL")
            refreshFiles()
            await reconcileTurnStateAfterResume()
        } catch {
            reportError("Resume failed: \(error)")
        }
        let shouldPark = backgroundParkRequested
        foregroundResumeRequested = false
        backgroundParkRequested = false
        // Release before the queued follow-up so it passes its own guard.
        hostLifecycleTransition = false
        if shouldPark && !parked { await parkHost(host) }
    }

    /// Releases a latched host transition after a bound the host's own
    /// drain/hello timeouts cannot exceed, so a wedged host fails loud on the
    /// status line instead of pinning the composer at "处理中" forever.
    private func transitionWatchdog(seconds: UInt64, label: String) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.hostLifecycleTransition else { return }
            self.hostLifecycleTransition = false
            self.appendStatus("\(label) did not finish in time; the host transition was released")
        }
    }

    /// Reconciles `turnRunning` with the host after a park/resume cycle.
    ///
    /// A parked host drains and cancels its open turn; the terminal event can
    /// be lost across the resume, which used to leave this app believing a
    /// turn was still running. Every later send was then queued behind a turn
    /// that no longer existed and every session switch was refused.
    private func reconcileTurnStateAfterResume() async {
        guard let sessionID else { return }
        do {
            let transport = try await transportForManagement()
            let value = try await transport.call("session/list", args: .object([:]))
            let running = (value["items"]?.arrayValue ?? []).first { item in
                item["sessionId"]?.stringValue == sessionID
            }?["running"]?.boolValue
            guard running == false, turnRunning else { return }
            finishStreamingAssistant()
            turnRunning = false
            syncIdleTimer()
            queueLabel.removeAll()
            statusLine = "已恢复：上一次回合在后台被取消"
            appendStatus("Turn was cancelled while the app was in the background; state cleared")
        } catch {
            // A failed probe leaves the previous behaviour in place; the next
            // turn event or an explicit stop still corrects the state.
        }
    }

    /// The turn finished while the app was hidden: release the audio session
    /// and park the idle host so the keep-alive never outlives the work.
    private func finishBackgroundKeepAlive() async {
        guard keepingAlive, let host else { return }
        stopBackgroundHeartbeat()
        keepAlive.stop()
        keepingAlive = false
        appendStatus("Turn finished in the background; keep-alive audio stopped, parking the idle host")
        await parkHost(host)
    }

    /// Every 10 s while hidden: how many harness events arrived since the last
    /// beat. Written to the status log only (not the transcript), so the log
    /// answers "did the Worker keep working?" after the fact.
    private func startBackgroundHeartbeat() {
        backgroundHeartbeat?.cancel()
        let started = Date()
        backgroundHeartbeat = Task { [weak self] in
            var lastCount = self?.eventsHandled ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let now = self.eventsHandled
                let elapsed = Int(Date().timeIntervalSince(started))
                // With an active audio session iOS reports the remaining time as
                // DBL_MAX (finite!); converting that to Int traps, so clamp.
                let remainingSeconds = UIApplication.shared.backgroundTimeRemaining
                let remaining = remainingSeconds > 1_000_000 ? "unlimited" : String(Int(max(0, min(remainingSeconds, 1_000_000))))
                Self.persistStatus("bg-heartbeat t=\(elapsed)s events+=\(now - lastCount) total=\(now) turnRunning=\(self.turnRunning) host=\(self.hostState) audio=\(self.keepAlive.isActive) remaining=\(remaining)")
                lastCount = now
            }
        }
    }

    private func stopBackgroundHeartbeat() {
        backgroundHeartbeat?.cancel()
        backgroundHeartbeat = nil
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "phone-dsh.chat.park") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Keeps the screen on while a turn runs so auto-lock does not park the
    /// host in the middle of a long task.
    private func syncIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = turnRunning && host != nil
    }

    private func observeHost(_ host: PhoneDSHHost) {
        hostEventTask?.cancel()
        let stream = host.eventStream()
        hostEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(_, let to):
                    self.hostState = "\(to)"
                case .error(let message):
                    // Keep the raw host text: the friendly summary alone made
                    // a WAL recovery failure look like a model-service error.
                    Self.appendDiagnostic("host error: \(message)")
                    self.reportError("引擎报错：\(Self.condensed(message))")
                case .webContentTerminated(let count):
                    self.restartPolicySawTermination = true
                    self.appendStatus("WebContent terminated (\(count)); the host restarts the Worker")
                case .restarted:
                    self.restartPolicyHighSamples = 0
                    self.restartPolicySawTermination = false
                    self.startedAt = Date()
                    self.appendStatus("Worker restarted; the session resumes from the WAL")
                default:
                    break
                }
            }
        }
    }

    // MARK: Unattended test hook

    /// Launch-time automation for device tests driven from the Mac: with
    /// `PDSH_CHAT_AUTOSTART=1` the page starts the host as soon as its anchor is
    /// in a window and, when `PDSH_CHAT_AUTOPROMPT` is set, sends that prompt.
    /// `devicectl device process launch --environment-variables` supplies
    /// both; the model key still comes from the provider settings.
    private var autostartDone = false

    func autostartIfRequested() {
        guard !autostartDone else { return }
        let environment = ProcessInfo.processInfo.environment
        guard environment["PDSH_CHAT_AUTOSTART"] == "1" else { return }
        autostartDone = true
        let prompt = environment["PDSH_CHAT_AUTOPROMPT"]
        Task { [weak self] in
            // The anchor view attaches to its window a moment after onAppear.
            for _ in 0..<20 {
                if self?.anchor.isInWindow == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            appendStatus("Autostart requested by the launch environment")
            await start()
            if let prompt, !prompt.isEmpty, isStarted {
                await send(prompt)
            }
        }
    }

    // MARK: Turns

    func send(_ text: String) async -> Bool {
        await send(text, attachments: [])
    }

    /// 重发时把 `reusing` 传进来:仍用原来那条气泡,不再长出新的一行。
    func send(_ text: String, attachments: [HarnessAttachment], reusing itemID: String? = nil) async -> Bool {
        refreshModelProviderReadiness()
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), canSend, let harness, let sessionID else { return false }
        busy = true
        defer { busy = false }
        let (fingerprint, requestID) = Self.retryableRequest(operation: "prompt", text: prompt,
                                                            attachments: attachments)
        do {
            try await harness.send(.prompt(text: prompt, attachments: attachments, requestID: requestID), to: sessionID)
            Self.completeRetryableRequest(fingerprint: fingerprint, requestID: requestID)
            // The drawer needs a readable row before DSH publishes its own
            // title projection.
            SessionTitleHints.remember(prompt, for: sessionID)
            let attachmentLabel = attachments.map { "[\($0.name)]" }.joined(separator: " ")
            let visiblePrompt = [prompt, attachmentLabel].filter { !$0.isEmpty }.joined(separator: "\n")
            if itemID == nil {
                let newID = "\(sessionID):prompt:\(requestID)"
                // 同一个 requestID 是同一句话(重发时逐字相同),那一条已经在列表里了。
                // 再追加一条同 id 的行,界面会把两条挤进同一块,新字就像拼进了旧气泡。
                if !items.contains(where: { $0.id == newID }) {
                    items.append(ChatItem(id: newID, kind: .user, title: "You", text: visiblePrompt))
                }
            }
            turnRunning = true
            syncIdleTimer()
            clearError()
            lastPrompt = (prompt, attachments)
            return true
        } catch {
            syncIdleTimer()
            reportError("Prompt failed: \(error)")
            return false
        }
    }

    func steer(_ text: String) async -> Bool {
        refreshModelProviderReadiness()
        let guidance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty, canSteer, let harness, let sessionID else { return false }
        busy = true
        defer { busy = false }
        let (fingerprint, requestID) = Self.retryableRequest(operation: "steer", text: guidance,
                                                            attachments: [])
        do {
            try await harness.send(.steer(text: guidance, requestID: requestID), to: sessionID)
            Self.completeRetryableRequest(fingerprint: fingerprint, requestID: requestID)
            items.append(ChatItem(id: "\(sessionID):steer:\(requestID)", kind: .user, title: "You (steering)", text: guidance))
            clearError()
            return true
        } catch {
            reportError("Steer failed: \(error)")
            return false
        }
    }

    /// Drops the permission/question cards without answering them.
    ///
    /// The runtime re-delivers pending approvals to every new connection, so a
    /// local dismiss loses nothing. It is what lets Stop and a session switch
    /// proceed while a card is on screen instead of being refused forever.
    func dismissPendingRequests() {
        pendingPermission = nil
        pendingQuestion = nil
    }

    func cancelTurn() async {
        // The card belongs to the turn being stopped; leaving it on screen
        // locked the composer and every session switch afterwards.
        dismissPendingRequests()
        guard let harness, let sessionID else { return }
        // The cancel RPC has no transport timeout: a busy Worker (a heavy
        // bash step, a WebContent restart) can swallow its response and this
        // await would never return, leaving `turnRunning` and the stop
        // spinner locked forever. Bound it; the local fallback below always
        // ends the turn for the person who pressed stop.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await harness.send(.cancel, to: sessionID)
                } catch {
                    // A wedged Worker can also fail the cancel call itself.
                    await MainActor.run { self.appendStatus("取消请求发送失败：\(error.localizedDescription)") }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
            }
            await group.next()
            group.cancelAll()
        }
        clearError()
        // The pinned runtime journals turn/end on cancel in the normal case.
        // When the turn is already stalled (no session events at all) that
        // terminal never arrives, and the composer would stay locked; give it
        // a short window, then end the turn on this side and say so.
        let deadline = Date().addingTimeInterval(3)
        while turnRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard turnRunning else { return }
        finishStreamingAssistant()
        turnRunning = false
        syncIdleTimer()
        queueLabel.removeAll()
        clearError()
        statusLine = "已停止（运行时未确认）"
        appendStatus("已停止（运行时未确认）。若之后没有响应，请在 ⋯ 菜单里停止主机再重新启动。")
    }

    func respond(to permission: ChatPermission, decision: PermissionDecision) async {
        guard let harness, let sessionID else { return }
        do {
            try await harness.send(.permissionResponse(requestID: permission.id, decision: decision), to: sessionID)
            if pendingPermission?.id == permission.id { pendingPermission = nil }
            clearError()
            appendStatus("Permission for \(permission.tool): \(decision.rawValue)")
        } catch {
            reportError("Permission response failed: \(error)")
        }
    }

    func respondToQuestion(answer: String) async {
        guard let question = pendingQuestion, let harness, let sessionID else { return }
        do {
            try await harness.send(.questionResponse(requestID: question.requestID, answer: answer), to: sessionID)
            if pendingQuestion?.requestID == question.requestID { pendingQuestion = nil }
            clearError()
            appendStatus("Answered the agent's question")
        } catch {
            reportError("Question response failed: \(error)")
        }
    }

    private struct SessionHistory {
        var items: [ChatItem]
        var after: UInt64?
        var turnRunning: Bool
        var hasMore: Bool
        var beforeSeq: Int?
        var throughSeq: Int?
    }

    /// Reads DSH's durable event log directly so user prompts, which are not
    /// projected by AgentHarness.events, appear in their original position.
    private func loadSessionHistory(sessionID: String,
                                   transport: any DSHRemoteTransport) async throws -> SessionHistory {
        let mux = try await transport.openMux()
        let streamID = "phone-chat-history-\(UUID().uuidString)"
        let cursor: Int
        do {
            try await mux.send(.object([
                "type": .string("open"),
                "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1),
                    "assistantStream": .bool(false),
                ])])]),
            ]))
            cursor = try await receiveHistoryCursor(from: mux, streamID: streamID)
            await mux.close()
        } catch {
            await mux.close()
            throw error
        }

        var records: [JSONValue] = []
        var hasMore = false
        var beforeSeq: Int?
        if cursor >= 0 {
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ])]))
            records = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            hasMore = page["hasMore"]?.boolValue ?? false
            beforeSeq = records.compactMap { $0["seq"]?.intValue }.min()
        }
        let after = cursor >= 0
            ? UInt64(cursor + 1) * DSHEventMapper.partsPerEvent - 1
            : nil
        let running: Bool?
        if let sessions = try? await transport.call("session/list", args: .object([:])),
           let row = sessions["items"]?.arrayValue?.first(where: { $0["sessionId"]?.stringValue == sessionID }) {
            running = row["running"]?.boolValue
        } else { running = nil }
        return SessionHistory(items: Self.transcriptItems(from: records, sessionID: sessionID), after: after,
                              turnRunning: running ?? Self.isTurnRunning(in: records),
                              hasMore: hasMore, beforeSeq: beforeSeq,
                              throughSeq: cursor >= 0 ? cursor : nil)
    }

    /// Loads one older message-aligned page and prepends unseen durable events.
    /// The existing tail remains untouched so the view can preserve its anchor.
    func loadEarlierTranscript() async {
        guard transcriptHasMore, let sessionID, let throughSeq = transcriptThroughSeq,
              let beforeSeq = transcriptBeforeSeq else { return }
        do {
            let transport = try await transportForManagement()
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(60),
            ])]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            guard let nextBeforeSeq = events.compactMap({ $0["seq"]?.intValue }).min(),
                  nextBeforeSeq < beforeSeq else {
                transcriptHasMore = false
                transcriptError = "The DSH history page did not advance before seq \(beforeSeq)."
                return
            }
            let existingIDs = Set(items.map(\.id))
            let older = Self.transcriptItems(from: events, sessionID: sessionID)
                .filter { !existingIDs.contains($0.id) }
            items = older + items
            transcriptBeforeSeq = nextBeforeSeq
            transcriptHasMore = page["hasMore"]?.boolValue ?? false
            transcriptError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            transcriptError = error.localizedDescription
        }
    }

    private func receiveHistoryCursor(from mux: any DSHMuxConnection, streamID: String) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    guard let frame = try await mux.receive() else {
                        throw ProviderError.unavailable(retryAfter: nil)
                    }
                    guard frame["streamId"]?.stringValue == streamID else { continue }
                    switch frame["type"]?.stringValue {
                    case "error":
                        throw ProviderError.invalidResponse("session/follow failed: \(frame["error"]?["message"]?.stringValue ?? "unknown error")")
                    case "end":
                        throw ProviderError.invalidResponse("session/follow ended before its history cursor")
                    case "item":
                        let value = frame["value"] ?? .null
                        if value["type"]?.stringValue == "snapshot" {
                            guard let cursor = value["cursor"]?.intValue else {
                                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
                            }
                            return cursor
                        }
                    default:
                        continue
                    }
                }
                throw ProviderError.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await mux.close()
                throw ProviderError.unavailable(retryAfter: nil)
            }
            guard let cursor = try await group.next() else {
                throw ProviderError.invalidResponse("session/follow did not publish a history cursor")
            }
            group.cancelAll()
            return cursor
        }
    }

    private func currentJournalCursor(sessionID: String,
                                      transport: any DSHRemoteTransport) async throws -> Int {
        let mux = try await transport.openMux()
        let streamID = "phone-trajectory-cursor-\(UUID().uuidString)"
        do {
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1), "assistantStream": .bool(false),
                ])])]),
            ]))
            let cursor = try await receiveHistoryCursor(from: mux, streamID: streamID)
            await mux.close()
            return cursor
        } catch {
            await mux.close()
            throw error
        }
    }

    private func scheduleTrajectoryRefresh(sessionID: String) {
        trajectoryRefreshTask?.cancel()
        trajectoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
            await self.refreshTrajectory()
        }
    }

    private static func trajectoryEntries(from events: [JSONValue],
                                          sessionID: String) -> [NativeTrajectoryEntry] {
        events.compactMap { event in
            guard let seq = event["seq"]?.intValue,
                  let eventType = event["type"]?.stringValue,
                  !eventType.hasSuffix(".status"), eventType != "host/status" else { return nil }
            let data = event["data"] ?? .null
            let category: NativeTrajectoryEntry.Category
            switch eventType {
            case "system/message": category = .systemPrompt
            case "user/message": category = .userMessage
            case "agent/steering/message": category = .steeringMessage
            case "developer/message": category = .developerMessage
            case "assistant/message": category = .assistantMessage
            case "tool/call": category = .toolCall
            case "tool/result": category = .toolResult
            case "turn/start", "turn/end", "step/start", "step/end", "assistant/attempt",
                 "llm/retry", "request/header", "agent/inbox/spliced": category = .requestBoundary
            case _ where eventType.hasPrefix("compaction/"): category = .compaction
            case "command/run", "command/done": category = .command
            case "session/start", "session/end", "session/close": category = .sessionBoundary
            default: category = .otherBusiness
            }
            let preview: String
            switch category {
            case .systemPrompt, .userMessage, .steeringMessage: preview = contentText(data["content"])
            case .developerMessage: preview = contentText(data["message"]?["content"])
            case .assistantMessage: preview = contentText(data["message"]?["content"])
            case .toolCall:
                preview = "\(data["name"]?.stringValue ?? "tool") · \(render(data["arguments"] ?? .null))"
            case .toolResult:
                let message = data["message"] ?? .null
                preview = contentText(message["content"]).isEmpty
                    ? (data["error"]?["reason"]?.stringValue ?? render(data))
                    : contentText(message["content"])
            case .command:
                preview = [data["name"]?.stringValue, data["args"]?.stringValue,
                           data["text"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
            default: preview = render(data)
            }
            let date = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return NativeTrajectoryEntry(id: "\(sessionID):\(seq)", sessionID: sessionID,
                                         seq: seq, timestamp: date, eventType: eventType,
                                         category: category, preview: String(preview.prefix(1_200)), payload: event)
        }.sorted { $0.seq < $1.seq }
    }

    private static func transcriptItems(from records: [JSONValue], sessionID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        for event in records {
            guard let seq = event["seq"]?.intValue else { continue }
            let id = "\(sessionID):\(seq)"
            let data = event["data"] ?? .null
            switch event["type"]?.stringValue {
            case "user/message":
                let text = contentText(data["content"])
                if !text.isEmpty {
                    switch DSHMessageSourceClassifier.classify(data) {
                    case .user:
                        result.append(ChatItem(id: id, kind: .user, title: "You", text: text))
                    case .context(let source):
                        result.append(ChatItem(id: id, kind: .context,
                                               title: "DSH context · \(source)", text: text))
                    }
                }
            case "assistant/message":
                let text = contentText(data["message"]?["content"])
                if !text.isEmpty { result.append(ChatItem(id: id, kind: .assistant, title: "Assistant", text: text)) }
            case "tool/call":
                let raw = data["arguments"]?.stringValue
                let arguments = raw.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                    ?? data["arguments"] ?? .null
                let name = data["name"]?.stringValue ?? "tool"
                result.append(ChatItem(id: id, kind: .toolCall, title: "Tool call: \(name)", text: render(arguments)))
            case "tool/result":
                let message = data["message"] ?? .null
                let text = contentText(message["content"])
                let isError = message["isError"]?.boolValue ?? (data["error"] != nil)
                result.append(ChatItem(id: id, kind: .toolResult(isError: isError),
                                       title: isError ? "Tool error" : "Tool result",
                                       text: text.isEmpty ? data["error"]?["reason"]?.stringValue ?? "" : text))
            default:
                continue
            }
        }
        return result
    }

    private static func isTurnRunning(in records: [JSONValue]) -> Bool {
        var running = false
        for event in records {
            switch event["type"]?.stringValue {
            case "turn/start": running = true
            case "turn/end": running = false
            default: break
            }
        }
        return running
    }

    private static func contentText(_ content: JSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue
            case "image": return "[图片]"
            default: return nil
            }
        }.joined()
    }

    private func startPump(harness: any AgentHarness, sessionID: String, after initialSeq: UInt64? = nil) {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            var after = initialSeq
            while !Task.isCancelled {
                do {
                    for try await event in harness.events(sessionID: sessionID, after: after) {
                        guard !Task.isCancelled, let self, self.sessionID == sessionID else { break }
                        if let seq = event.seq, let current = after, seq <= current { continue }
                        if let seq = event.seq { after = seq }
                        self.handle(event)
                        if event.seq != nil { self.scheduleTrajectoryRefresh(sessionID: sessionID) }
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.sessionID == sessionID else { break }
                    self.reportError("Event stream interrupted: \(error)")
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func handle(_ event: HarnessEvent) {
        eventsHandled += 1
        // A queued message only needs its dispatch label until the turn shows
        // any activity. Assistant text is not the only first output: a turn
        // that starts with a tool call used to keep 发送中… forever.
        if case .turnStarted = event.kind {
            // Promoted to 发送中… by the turnStarted branch below.
        } else {
            clearSendingLabels()
        }
        switch event.kind {
        case .reasoningDelta(let text):
            clearSendingLabels()
            if let index = items.indices.last, items[index].kind == .reasoning,
               items[index].streaming {
                items[index].text += text
            } else {
                finishStreamingReasoning()
                items.append(ChatItem(id: eventItemID(event), kind: .reasoning,
                                      title: "思考", text: text, streaming: true))
            }
        case .assistantDelta(let text):
            clearSendingLabels()
            finishStreamingReasoning()
            if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
                items[index].text += text
            } else {
                items.append(ChatItem(id: eventItemID(event), kind: .assistant, title: "Assistant", text: text, streaming: true))
            }
        case .assistantMessage(let text):
            clearSendingLabels()
            finishStreamingReasoning()
            if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
                if !text.isEmpty { items[index].text = text }
                items[index].streaming = false
            } else if !text.isEmpty {
                items.append(ChatItem(id: eventItemID(event), kind: .assistant, title: "Assistant", text: text))
            }
        case .userMessage, .inboxSpliced:
            // The composer already appends the local prompt row; these durable
            // projections exist for transcript/audit consumers.
            break
        case .toolCall(_, let name, let arguments):
            finishStreamingAssistant()
            finishStreamingReasoning()
            recentToolArguments[name] = Self.flattenedArguments(arguments)
            items.append(ChatItem(id: eventItemID(event), kind: .toolCall, title: "Tool call: \(name)", text: Self.render(arguments)))
        case .toolResult(_, let isError, let summary):
            let detail = event.toolResultDetail?.text ?? summary
            items.append(ChatItem(id: eventItemID(event), kind: .toolResult(isError: isError),
                                  title: isError ? "Tool error" : "Tool result", text: detail))
            refreshFiles()
        case .permissionRequested(let request):
            pendingPermission = ChatPermission(id: request.requestID, tool: request.tool,
                                               summary: request.summary,
                                               arguments: recentToolArguments[request.tool] ?? [:])
        case .questionRequested(let question):
            pendingQuestion = question
            appendStatus("The agent asks: \(question.prompt)")
        case .turnStarted:
            promoteQueuedToSending()
            turnRunning = true
            syncIdleTimer()
            statusLine = "Turn running…"
        case .turnEnded(_, let reason):
            finishStreamingAssistant()
            finishStreamingReasoning()
            clearSendingLabels()
            turnRunning = false
            syncIdleTimer()
            statusLine = "Turn ended: \(Self.describe(reason))"
            persistTranscriptSnapshot()
            if case .failed(let message) = reason {
                reportError(Self.userFacingFailure(message))
                failedPrompt = lastPrompt
                failedItemID = items.last(where: { if case .user = $0.kind { return true }; return false })?.id
                // 失败和「发送中…」互斥:同一条下面只留失败那行。
                if let id = failedItemID { queueLabel[id] = nil }
            } else {
                // A finished turn has no queued or dispatching message left;
                // "已并入当前任务" used to stay under the message forever.
                queueLabel.removeAll()
                appendStatus("Turn ended: \(Self.describe(reason))")
            }
            refreshFiles()
            if keepingAlive { Task { await self.finishBackgroundKeepAlive() } }
        case .progress(let phase, let step, let total):
            statusLine = "\(phase) step \(step)\(total.map { " of \($0)" } ?? "")"
            if phase == "step" { modelRequests += 1 }
        case .sessionStatus(let status):
            if status.lowercased().hasPrefix("error:") {
                reportError("Session: \(status)")
            } else {
                statusLine = "Session: \(status)"
            }
        case .usage(let input, let output):
            inputTokens += input
            outputTokens += output
        case .exited(let reason):
            appendStatus("Agent exited: \(reason)")
            turnRunning = false
            syncIdleTimer()
        }
    }

    private func finishStreamingAssistant() {
        if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
            items[index].streaming = false
        }
    }

    private func finishStreamingReasoning() {
        for index in items.indices where items[index].kind == .reasoning && items[index].streaming {
            items[index].streaming = false
        }
    }

    private func eventItemID(_ event: HarnessEvent) -> String {
        guard let sessionID, let seq = event.seq else { return UUID().uuidString }
        let position = DSHEventMapper.position(of: seq)
        return "\(sessionID):\(position.dshSeq):part-\(position.part)"
    }

    private func appendStatus(_ text: String) {
        items.append(ChatItem(kind: .status, title: "Host", text: text))
        Self.persistStatus(text)
    }

    // MARK: - Planned-restart policy

    /// One sample per minute; the RestartPolicy decides whether the sample is
    /// a reason to restart, and the restart only runs when no turn is in
    /// flight (the tool-call boundary).
    private func startRestartPolicyMonitor() {
        restartPolicyTask?.cancel()
        restartPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.evaluateRestartPolicy()
            }
        }
    }

    private func evaluateRestartPolicy() async {
        guard let host, let budget = restartPolicyBudget,
              let startedAt, isStarted, !parked, !hostLifecycleTransition else { return }
        let heap = await host.currentEngineHeapBytes()
        let atToolBoundary = !turnRunning && !busy
        let evaluation = RestartPolicy.standard.evaluate(
            engineHeapBytes: heap,
            heapBudgetBytes: budget.engineHeapBytes,
            uptime: Date().timeIntervalSince(startedAt),
            highSamples: restartPolicyHighSamples,
            webContentTerminated: restartPolicySawTermination,
            atToolBoundary: atToolBoundary)
        restartPolicyHighSamples = evaluation.nextHighSamples
        guard let trigger = evaluation.trigger else { return }
        restartPolicyHighSamples = 0
        restartPolicySawTermination = false
        appendStatus("Planned restart (\(trigger.rawValue)) at the tool-call boundary")
        do {
            try await host.plannedRestart(reason: "restart policy: \(trigger.rawValue)")
        } catch {
            appendStatus("Planned restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Launch transcript snapshot

    private struct CachedTranscriptItem: Codable {
        var id: String
        var kind: String
        var title: String
        var text: String
    }

    private static func snapshotURL(for sessionID: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }

    private static func snapshotKindName(_ kind: ChatItem.Kind) -> String {
        switch kind {
        case .user: return "user"
        case .context: return "context"
        case .assistant: return "assistant"
        case .reasoning: return "reasoning"
        case .toolCall: return "toolCall"
        case .toolResult(let isError): return isError ? "toolError" : "toolResult"
        case .status: return "status"
        }
    }

    private static func chatKind(from name: String) -> ChatItem.Kind? {
        switch name {
        case "user": return .user
        case "context": return .context
        case "assistant": return .assistant
        case "reasoning": return .reasoning
        case "toolCall": return .toolCall
        case "toolResult": return .toolResult(isError: false)
        case "toolError": return .toolResult(isError: true)
        case "status": return .status
        default: return nil
        }
    }

    /// Renders the last session's settled items before the host is ready.
    private func restoreCachedTranscriptIfAvailable() {
        guard items.isEmpty,
              let sessionID = UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey),
              let data = try? Data(contentsOf: Self.snapshotURL(for: sessionID)),
              let cached = try? JSONDecoder().decode([CachedTranscriptItem].self, from: data),
              !cached.isEmpty else { return }
        items = cached.compactMap { item in
            guard let kind = Self.chatKind(from: item.kind) else { return nil }
            return ChatItem(id: item.id, kind: kind, title: item.title, text: item.text)
        }
        guard !items.isEmpty else { return }
        isShowingCachedTranscript = true
        statusLine = "显示上次对话，引擎在后台启动…"
    }

    /// Saves the settled items so the next launch can paint immediately.
    private func persistTranscriptSnapshot() {
        guard !isShowingCachedTranscript, let sessionID else { return }
        let settled = items.filter { !$0.streaming }.suffix(400)
        guard !settled.isEmpty else { return }
        let cached = settled.map { item in
            CachedTranscriptItem(id: item.id,
                                 kind: Self.snapshotKindName(item.kind),
                                 title: item.title,
                                 text: item.text)
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = Self.snapshotURL(for: sessionID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// One short line of a raw host message (the full text stays in
    /// `chat-status.log`). Keeps the friendly UI readable without hiding the
    /// engineering cause.
    static func condensed(_ message: String) -> String {
        let line = message.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? message
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// 宿主回来的失败原话常常是英文并带接口域名,一律翻成一句中文;
    /// 原话只写进 chat-status.log 供诊断导出。
    static func userFacingFailure(_ raw: String) -> String {
        let lower = raw.lowercased()
        Self.appendDiagnostic("turn failed: \(raw)")
        // 六种说法,认不出来只写「没发出去」:宿主原句永远不上屏。
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("host_not_allowed")
            || lower.contains("not on the configured allow-list") {
            return "模型服务拒绝访问（403，检查服务地址与允许列表）"
        }
        if lower.contains("404") || lower.contains("not found") || lower.contains("no such model") {
            return "模型或地址不对（404，检查模型名与接口地址）"
        }
        if lower.contains("429") || lower.contains("too many") || lower.contains("rate limit") {
            return "请求太频繁（429）"
        }
        if lower.contains("key") || lower.contains("auth") || lower.contains("401") || lower.contains("unauthor") {
            return "密钥不被接受（401）"
        }
        if lower.contains("quota") || lower.contains("insufficient") || lower.contains("balance") || lower.contains("402") {
            return "额度用完"
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("deadline") {
            return "等太久"
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("connect") {
            return "连不上模型服务"
        }
        if lower.contains("not running") || lower.contains("not started") || lower.contains("no host") || lower.contains("missing") {
            return "引擎停了"
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("500") {
            return "模型服务出错了"
        }
        return "没发出去"
    }

    static func appendDiagnostic(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: statusLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusLogURL)
        }
    }

    /// 上一轮失败后可以原样重发的那一条;清掉草稿就不还字(Ato 定的)。
    var failedPrompt: (String, [HarnessAttachment])?
    /// 失败行挂在产生它的那一条下面,不是永远挂在最后一条。
    var failedItemID: String?

    /// 排队那三种结局只出一条:已排队 → 发送中…,或被并入当前任务。
    var queueLabel: [String: String] = [:]

    func markQueued(itemID: String) { queueLabel[itemID] = "已排队" }
    func markSteered(itemID: String) { queueLabel[itemID] = "已并入当前任务" }

    /// 回复一旦开始流式输出,这条消息就已经送达:「发送中…」必须收掉,
    /// 否则它会一直挂在用户消息下面(线上反馈)。
    private func clearSendingLabels() {
        for id in queueLabel.keys where queueLabel[id] == "发送中…" {
            queueLabel[id] = nil
        }
    }

    /// 宿主真正开始处理这一条时,把「已排队」换成「发送中…」。
    private func promoteQueuedToSending() {
        for id in queueLabel.keys where queueLabel[id] == "已排队" {
            queueLabel[id] = "发送中…"
        }
    }

    #if DEBUG
    /// 确定性状态:一条失败消息加下面那行「没发出去 · 重试」。
    func debugInjectFailure(text: String = "整理一下这周的日志") {
        let id = "debug-failure-\(UUID().uuidString.prefix(4))"
        items.append(ChatItem(id: id, kind: .user, title: "You", text: text))
        failedItemID = id
        failedPrompt = (text, [])
        userFacingError = "没发出去"
    }

    /// 确定性状态:一条带工具行、代码块和两段正文的助手回复。
    func debugInjectAssistant() {
        items.append(ChatItem(id: "debug-assistant-tool", kind: .toolCall, title: "工具",
                              text: "Read · Package.swift"))
        let body = """
        先看了工程的入口,`.build` 目录已经在忽略列表里。

        ```swift
        let scheme = "PhoneDSHProbe"
        let destination = "platform=iOS Simulator"
        ```

        接下来我会把这一段改动落到 `ChatPage.swift`,然后重新编译验证。
        """
        items.append(ChatItem(id: "debug-assistant-body", kind: .assistant, title: "DSH", text: body))
    }

    /// 确定性状态:一段多轮工具调用(含一条失败),用来验收收纳后的行高。
    func debugInjectToolRun() {
        let calls: [(String, String, Bool?)] = [
            ("bash", "ls -la /dsh/workspace", nil),
            ("", "total 12 drwxr-xr-x 3 user staff 96 demo", false),
            ("bash", "rg --json TODO Sources/", nil),
            ("", "{\"path\":\"Sources/PhoneDSH/PhoneDSH.swift\",\"line\":12}", false),
            ("open_page", "https://example.com/news", nil),
            ("", "403 forbidden: upstream refused the request", true),
            ("bash", "cat /dsh/workspace/demo/native-ui.md", nil),
            ("", "# 标题\n正文第一段", false),
        ]
        for (index, entry) in calls.enumerated() {
            let id = "debug-tools-\(index)"
            if entry.2 == nil {
                items.append(ChatItem(id: id, kind: .toolCall, title: "Tool call: \(entry.0)", text: entry.1))
            } else {
                items.append(ChatItem(id: id, kind: .toolResult(isError: entry.2 == true),
                                      title: entry.2 == true ? "Tool error" : "Tool result", text: entry.1))
            }
        }
    }

    /// 确定性状态:一条排队中的消息。
    func debugInjectQueued(text: String = "把这周的日志按天归档") {
        let id = "debug-queued-\(UUID().uuidString.prefix(4))"
        items.append(ChatItem(id: id, kind: .user, title: "You", text: text))
        queueLabel[id] = "已排队"
    }
    #endif

    /// 重试失败的这一轮:同一条内容重新入队。
    func retryFailedPrompt() async -> Bool {
        refreshModelProviderReadiness()
        guard canSend, let (text, attachments) = failedPrompt else { return false }
        let pendingID = failedItemID
        // 重试期间那条下面只留一个状态:先把失败行摘掉、挂上「发送中…」,
        // 失败回来再把它挂回去——两行同时出现,人会以为消息发出去又没发。
        if let pendingID {
            failedItemID = nil
            queueLabel[pendingID] = "发送中…"
        }
        clearError()
        let ok = await send(text, attachments: attachments, reusing: pendingID)
        if let pendingID { queueLabel[pendingID] = nil }
        failedItemID = ok ? nil : pendingID
        if ok { failedPrompt = nil } else { failedPrompt = (text, attachments) }
        return ok
    }

    private func reportError(_ text: String) {
        userFacingError = text
        statusLine = text
        appendStatus(text)
    }

    /// Status rows also go to `Documents/chat-status.log` so a host error can
    /// be read back from the device container after the fact (the transcript
    /// itself lives only in memory).
    static let statusLogURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("chat-status.log")

    private static func persistStatus(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(text)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: statusLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusLogURL)
        }
    }

    private static func render(_ arguments: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(arguments)"
    }

    /// Keep DSH's idempotency key across an ambiguous transport failure so a
    /// user retry cannot append the same prompt a second time. Only the digest
    /// and opaque request ID are persisted; prompt and attachment contents are
    /// never written to defaults by this retry path.
    private static func retryableRequest(operation: String, text: String,
                                         attachments: [HarnessAttachment]) -> (String, String) {
        var material = Data()
        func append(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(bytes)
        }
        append(Data(operation.utf8))
        append(Data(text.utf8))
        for attachment in attachments {
            append(Data(attachment.name.utf8))
            append(Data(attachment.mimeType.utf8))
            append(attachment.data)
        }
        let fingerprint = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        var stored = UserDefaults.standard.dictionary(forKey: retryableRequestIDsDefaultsKey) as? [String: String] ?? [:]
        let requestID: String
        if let existing = stored[fingerprint] {
            requestID = existing
        } else {
            requestID = UUID().uuidString
            stored[fingerprint] = requestID
            if stored.count > 64 {
                let stale = stored.keys.sorted().prefix(stored.count - 64)
                for key in stale { stored[key] = nil }
            }
            UserDefaults.standard.set(stored, forKey: retryableRequestIDsDefaultsKey)
        }
        return (fingerprint, requestID)
    }

    private static func completeRetryableRequest(fingerprint: String, requestID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: retryableRequestIDsDefaultsKey) as? [String: String] ?? [:]
        guard stored[fingerprint] == requestID else { return }
        stored[fingerprint] = nil
        UserDefaults.standard.set(stored, forKey: retryableRequestIDsDefaultsKey)
    }

    private static func describe(_ reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed(let message): return "failed — \(message)"
        case .budgetExhausted(let message): return "budget exhausted — \(message)"
        }
    }

    // MARK: Workspace files

    func refreshFiles() {
        let root = materializedWorkspace.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path + "/"
        var found: [WorkspaceFile] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                // A path outside the materialized root is not a workspace file;
                // an absolute path here would break the list grouping and every
                // preview/share decision downstream.
                guard path.hasPrefix(rootPrefix) else { continue }
                found.append(WorkspaceFile(relativePath: String(path.dropFirst(rootPrefix.count)),
                                           size: values.fileSize ?? 0))
            }
        }
        files = found.sorted { $0.relativePath < $1.relativePath }
        if let previewPath, !files.contains(where: { $0.relativePath == previewPath }) {
            self.previewPath = nil; previewText = nil
        }
    }

    func preview(_ file: WorkspaceFile) {
        let url = materializedWorkspace.appendingPathComponent(file.relativePath)
        previewPath = file.relativePath
        guard let data = try? Data(contentsOf: url) else { previewText = "(unreadable)"; return }
        let limit = 24 * 1024
        let slice = data.prefix(limit)
        if let text = String(data: slice, encoding: .utf8) {
            previewText = text + (data.count > limit ? "\n… (\(data.count) bytes, truncated)" : "")
        } else {
            previewText = "(binary, \(data.count) bytes)"
        }
    }

    func clearTranscript() {
        items.removeAll()
        inputTokens = 0; outputTokens = 0; modelRequests = 0
    }
}

#if DEBUG
extension ChatModel {
    /// Preview-only: park a message state that normally comes from a live turn
    /// so the failure and queued screens can be reviewed without a model.
    func debugInstallPreviewState(failedItemID itemID: String?, error: String?, queue: [String: String],
                                  question: HarnessQuestion? = nil) {
        failedItemID = itemID
        userFacingError = error
        queueLabel = queue
        pendingQuestion = question
    }

    /// Debug-only sample conversation, opened with `-uiPreview sample`. It never
    /// touches the network or the host: the items are fabricated here so a
    /// reviewer can see a full thread (markdown, a tool result, a failed message
    /// and a pending card) on a machine with no model configured. Release builds
    /// do not contain this code, and the launch argument is ignored there.
    static var sampleRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiPreview"),
              arguments.count > index + 1 else { return false }
        return arguments[index + 1] == "sample"
    }

    static func installSampleConversationIfRequested() {
        guard sampleRequested else { return }
        let model = ChatModel.shared
        // Never cover a conversation that is actually running: the sample only
        // fills an idle, empty debug surface.
        guard !model.turnRunning, !model.busy, !model.keepingAlive else { return }
        model.items = [
            ChatItem(kind: .user, title: "", text: "把示例项目的测试跑一遍，失败的顺手修掉"),
            ChatItem(kind: .assistant, title: "", text: """
            先看一下它现在有什么测试。

            | 目标 | 用例 | 上次结果 |
            | --- | --- | --- |
            | ProbeKit | 42 | 通过 |
            | PhoneDSHProbe | 18 | 2 个失败 |

            失败的两个都在格式化这一层：
            ```swift
            func relative(_ date: Date) -> String {
                if seconds < 60 { return "刚刚" }
                return minuteText(seconds)
            }
            ```
            """),
            ChatItem(kind: .toolCall, title: "运行测试", text: "swift test --filter SessionTime"),
            ChatItem(kind: .toolResult(isError: false), title: "运行测试", text: "18 tests, 2 failures"),
            ChatItem(kind: .toolResult(isError: true), title: "运行测试", text: "第二个断言失败：期望「刚刚」，实际「0 分钟前」"),
            ChatItem(kind: .assistant, title: "", text: """
            第二个用例的边界写错了：不到一分钟的分支没有命中，落到了按分钟计算那一支。改法是把这个判断提前，并且给 59 秒和 60 秒各加一条用例。

            改完我会再跑一遍全量，把两个失败一起验证，然后把 diff 贴上来。
            """),
            ChatItem(kind: .toolCall, title: "读取文件", text: "Tests/SessionTimeTests.swift"),
            ChatItem(kind: .toolResult(isError: false), title: "读取文件", text: "42 行"),
            ChatItem(kind: .assistant, title: "", text: "已经改好了，正在跑最后一遍。", streaming: true)
        ]
        model.pendingPermission = ChatPermission(
            id: "sample-permission",
            tool: "run_command",
            summary: "运行 swift test --filter SessionTime")
        model.pendingQuestion = HarnessQuestion(
            requestID: "sample-question",
            prompt: "两个失败的用例怎么处理？",
            options: ["都修掉", "先跳过"])
    }
}
#endif
