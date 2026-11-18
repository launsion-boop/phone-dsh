// SPDX-License-Identifier: MIT
// DEBUG-only developer control channel (spec/dev/debug-channel.md, DEV-01). NOT a product protocol and
// never compiled into a Release build: the whole file, its start call and the codec it uses are `#if DEBUG`.
// A Mac-side script (scripts/pdsh-debug.py) inspects and drives the running app over HTTP in seconds,
// without a rebuild. The listener exists only while the app is in the foreground, requires a random
// per-launch token and accepts private/LAN peers only.
#if DEBUG
import Foundation
import Network
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHBot
import PhoneDSHLoopback
import UIKit

@MainActor
final class DebugChannel {
    static let shared = DebugChannel()
    static let port: UInt16 = 47099

    private var listener: NWListener?
    private var token = ""
    private var observers: [NSObjectProtocol] = []
    private var lastChat: ChatRun?

    /// Call once from `App.init()`; binds when the app is (or becomes) active, closes on background.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DebugChannel.shared.start() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DebugChannel.shared.stop() }
        })
        if UIApplication.shared.applicationState == .active { start() }
    }

    private func start() {
        guard listener == nil else { return }
        token = (0..<4).map { _ in String(UInt64.random(in: 0...UInt64.max), radix: 16) }.joined()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in DebugChannel.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    Task { @MainActor in DebugChannel.shared.announce() }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            TonoLinkVoiceHost.shared.log("debug-channel start failed: \(error)")
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        TonoLinkVoiceHost.shared.log("debug-channel stopped (background)")
    }

    /// The token is printed in the DEBUG trace and written to `Documents/debug-channel.json`; the Mac
    /// script reads either over devicectl, so nothing is typed by hand.
    private func announce() {
        TonoLinkVoiceHost.shared.log("debug-channel listening port=\(Self.port) token=\(token)")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: ["port": Int(Self.port), "token": token,
                                                                  "started": ISO8601DateFormatter().string(from: Date())]) {
            try? data.write(to: docs.appendingPathComponent("debug-channel.json"), options: .atomic)
        }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        var host = ""
        if case .hostPort(let h, _) = connection.endpoint {
            switch h {
            case .ipv4(let a): host = "\(a)"
            case .ipv6(let a): host = "\(a)"
            case .name(let n, _): host = n
            @unknown default: break
            }
        }
        let token = self.token
        connection.start(queue: .global(qos: .userInitiated))
        Task.detached {
            var buffer = Data()
            while true {
                guard let chunk = await Self.receive(connection) else { connection.cancel(); return }
                buffer.append(chunk)
                switch DebugChannelCodec.parse(buffer) {
                case .needMore: continue
                case .invalid(let reason):
                    await Self.send(connection, DebugChannelCodec.response(status: 400, json: Self.json(["error": reason])))
                    return
                case .request(let request):
                    let status = DebugChannelCodec.authorize(headers: request.headers, token: token, remoteHost: host)
                    guard status == 200 else {
                        await Self.send(connection, DebugChannelCodec.response(status: status, json: Self.json(["error": status == 401 ? "token" : "address"])))
                        return
                    }
                    let (code, body) = await DebugChannel.shared.route(request)
                    await Self.send(connection, DebugChannelCodec.response(status: code, json: body))
                    return
                }
            }
        }
    }

    private nonisolated static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(returning: nil); _ = (isComplete, error) }
            }
        }
    }

    private nonisolated static func send(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel(); continuation.resume()
            })
        }
    }

    nonisolated static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: Routes

    private func route(_ request: DebugChannelRequest) async -> (Int, Data) {
        let args = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/info"): return (200, Self.json(info()))
        case ("GET", "/bots"): return (200, Self.json(await bots()))
        case ("GET", "/devices"): return (200, Self.json(["devices": devices()]))
        case ("GET", "/logs"): return (200, Self.json(logs(name: request.query["name"] ?? "voice", lines: Int(request.query["lines"] ?? "") ?? 100)))
        case ("GET", "/approvals"): return (200, Self.json(await approvals(bot: request.query["bot"])))
        case ("POST", "/approve"): return await approve(args)
        case ("GET", "/grants"): return (200, Self.json(grants(device: request.query["device"])))
        case ("POST", "/grants"): return setGrants(args)
        case ("POST", "/link"): return await link(args)
        case ("POST", "/devices/connect"): return connectDevice(args)
        case ("POST", "/bots/create"): return await createBot(args)
        case ("POST", "/bots/delete"): return await deleteBots(args)
        case ("POST", "/chat"): return await chat(args)
        case ("GET", "/turn"): return await turn(wait: Double(request.query["wait"] ?? "") ?? 0)
        default: return (404, Self.json(["error": "unknown route", "routes": [
            "GET /info", "GET /bots", "GET /devices", "GET /logs?name=voice|status&lines=", "GET /approvals?bot=",
            "POST /approve", "GET|POST /grants", "POST /link", "POST /devices/connect", "POST /bots/create", "POST /bots/delete", "POST /chat", "GET /turn?wait="]]))
        }
    }

    // MARK: Read endpoints

    private func info() -> [String: Any] {
        let bundle = Bundle.main
        var out: [String: Any] = [
            "bundle_id": bundle.bundleIdentifier ?? "",
            "version": bundle.infoDictionary?["CFBundleShortVersionString"] ?? "",
            "build": bundle.infoDictionary?["CFBundleVersion"] ?? "",
            "debug": true, "app_state": UIApplication.shared.applicationState.rawValue,
            "bot_runtime": ChatModel.shared.botRuntime != nil,
        ]
        if let url = bundle.url(forResource: "probe-bundle", withExtension: "json", subdirectory: "worker"),
           let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            out["worker_bundle"] = ["generated_at": json["generated_at"] ?? "", "image": json["image"] ?? [:]]
        }
        return out
    }

    private func bots() async -> [String: Any] {
        guard let composition = ChatModel.shared.botRuntime else { return ["error": "no Bot runtime"] }
        let store = DeviceBotMapStore()
        let roster = composition.rosterModel.bots.map { bot -> [String: Any] in
            ["id": bot.id, "name": bot.name, "description": bot.description, "created_ms": bot.createdAt,
             "device_key": DeviceBotRegistry.shared.deviceID(forBot: bot.id) ?? NSNull(),
             "main": bot.id == composition.rosterModel.mainBotID]
        }
        return ["count": roster.count, "bots": roster, "bindings": store.bindings, "intents": store.intents]
    }

    private func devices() -> [[String: Any]] {
        BLEDeviceStore.shared.devices.map {
            ["id": $0.id.uuidString, "name": $0.name, "state": $0.state, "link_state": $0.linkState,
             "link_device_id": $0.linkDeviceID, "tools": $0.linkTools, "granted_tools": $0.grantedTools.sorted(), "rssi": $0.rssi]
        }
    }

    /// Starts a scan and connects the named device (id or BLE name); poll `GET /devices` for the link state.
    private func connectDevice(_ args: [String: Any]) -> (Int, Data) {
        BLEDeviceStore.shared.scan()
        guard let key = args["device"] as? String,
              let device = BLEDeviceStore.shared.devices.first(where: { $0.id.uuidString == key || $0.name == key }) else {
            return (200, Self.json(["status": "scanning", "note": "device not in the list yet; call again"]))
        }
        if device.state == "未连接" { BLEDeviceStore.shared.connect(device.id) }
        return (200, Self.json(["status": "connecting", "device": device.name, "state": device.state]))
    }

    private func logs(name: String, lines: Int) -> [String: Any] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return ["error": "no documents"] }
        let file = ["voice": "tonolink-voice.log", "status": "chat-status.log"][name] ?? "tonolink-voice.log"
        guard let text = try? String(contentsOf: docs.appendingPathComponent(file), encoding: .utf8) else { return ["file": file, "lines": []] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        // The token line is not secret to a holder of the token, but keep it out of the tail.
        let tail = all.suffix(max(1, min(lines, 2000))).map(String.init).filter { !$0.contains("debug-channel listening") }
        return ["file": file, "lines": tail]
    }

    // MARK: Approvals and grants

    private func chatModel(_ botID: String) async -> BotChatModel? {
        try? await BotProductionHub.shared.chatModel(ensuring: botID)
    }

    private func approvals(bot: String?) async -> [String: Any] {
        guard let composition = ChatModel.shared.botRuntime else { return ["error": "no Bot runtime"] }
        var out: [[String: Any]] = []
        for entry in composition.rosterModel.bots where bot == nil || bot == entry.id {
            guard let model = await chatModel(entry.id) else { continue }
            await BotProductionHub.shared.pullRows(for: entry.id)
            for row in model.rows where row.body.type == "approval" {
                let status = row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending"
                out.append(["bot": entry.id, "row": row.id, "status": status,
                            "detail": row.body.string("detail", "command", "text") ?? ""])
            }
        }
        return ["approvals": out.filter { ($0["status"] as? String) == "pending" }, "all_count": out.count]
    }

    private func approve(_ args: [String: Any]) async -> (Int, Data) {
        guard let bot = args["bot"] as? String, let model = await chatModel(bot) else { return (400, Self.json(["error": "bot required"])) }
        let decision: BotUIApprovalDecision = (args["decision"] as? String) == "deny" ? .deny : .allowOnce
        await BotProductionHub.shared.pullRows(for: bot)
        let rowID = args["row"] as? String
        let pending = model.rows.filter { row in
            guard row.body.type == "approval" else { return false }
            let status = row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending"
            return status == "pending" && (rowID == nil || row.id == rowID)
        }
        guard let row = pending.last else { return (200, Self.json(["resolved": 0, "note": "no pending approval"])) }
        model.decide(row: row, decision: decision)
        return (200, Self.json(["resolved": 1, "row": row.id, "decision": decision.rawValue]))
    }

    private func grants(device: String?) -> [String: Any] {
        ["devices": BLEDeviceStore.shared.devices.filter { device == nil || $0.id.uuidString == device || $0.name == device }
            .map { ["id": $0.id.uuidString, "name": $0.name, "tools": $0.linkTools, "granted": $0.grantedTools.sorted()] as [String: Any] }]
    }

    private func setGrants(_ args: [String: Any]) -> (Int, Data) {
        guard let key = args["device"] as? String,
              let device = BLEDeviceStore.shared.devices.first(where: { $0.id.uuidString == key || $0.name == key }),
              let tools = args["tools"] as? [String] else { return (400, Self.json(["error": "device and tools required"])) }
        let enabled = args["enabled"] as? Bool ?? true
        for tool in tools { BLEDeviceStore.shared.grantLinkTool(device.id, name: tool, enabled: enabled) }
        return (200, Self.json(["device": device.name, "tools": tools, "enabled": enabled]))
    }

    private func link(_ args: [String: Any]) async -> (Int, Data) {
        guard let key = args["device"] as? String,
              let device = BLEDeviceStore.shared.devices.first(where: { $0.id.uuidString == key || $0.name == key }),
              let name = args["name"] as? String else { return (400, Self.json(["error": "device and name required"])) }
        let arguments: JSONValue
        if let raw = args["args"], let data = try? JSONSerialization.data(withJSONObject: raw), let value = try? JSONValue.parse(data) { arguments = value }
        else { arguments = .object([:]) }
        do {
            let outcome = try await callLinkTool(deviceID: device.id, name: name, arguments: arguments,
                                                 idempotencyKey: "debug.\(UUID().uuidString.lowercased())", origin: .user)
            switch outcome {
            case .completed(_, let reply): return (200, Self.json(["status": "completed", "reply": (try? JSONSerialization.jsonObject(with: reply.encoded())) ?? NSNull()]))
            case .notExecuted(_, let stage, let status): return (200, Self.json(["status": "not_executed", "stage": stage, "detail": status]))
            case .outcomeUnknown(_, let message): return (200, Self.json(["status": "outcome_unknown", "message": message]))
            case .running: return (200, Self.json(["status": "running"]))
            }
        } catch { return (200, Self.json(["status": "error", "error": "\(error)"])) }
    }

    // MARK: Bot create / delete

    /// A plain, unbound Bot, for exercising the other endpoints (delete, chat) without touching a real one.
    private func createBot(_ args: [String: Any]) async -> (Int, Data) {
        guard let composition = ChatModel.shared.botRuntime else { return (400, Self.json(["error": "no Bot runtime"])) }
        let name = (args["name"] as? String) ?? "debug-bot"
        do {
            let profile = try await composition.createBot(name: name, description: (args["description"] as? String) ?? "", color: nil, hairstyle: nil, author: nil)
            return (200, Self.json(["id": profile.id, "name": profile.name]))
        } catch { return (200, Self.json(["error": "\(error)"])) }
    }

    // MARK: Bot delete

    private func deleteBots(_ args: [String: Any]) async -> (Int, Data) {
        guard let composition = ChatModel.shared.botRuntime else { return (400, Self.json(["error": "no Bot runtime"])) }
        let ids = (args["ids"] as? [String]) ?? (args["id"] as? String).map { [$0] } ?? []
        guard !ids.isEmpty else { return (400, Self.json(["error": "ids required"])) }
        let started = Date()
        var report: [String: Any] = ["requested": ids.count]
        if args["full"] as? Bool == true {
            var deleted: [String] = [], errors: [String] = []
            for id in ids {
                do { try await composition.deleteBot(id); deleted.append(id) } catch { errors.append("\(id): \(error)") }
            }
            report["deleted"] = deleted; report["errors"] = errors
        } else {
            do {
                let result = try await composition.profileStore.deleteBots(ids: Set(ids))
                report["deleted"] = result.removed.map(\.id); report["unknown"] = result.unknown
            } catch { report["errors"] = ["\(error)"] }
            await composition.rosterModel.refresh()
        }
        report["seconds"] = Date().timeIntervalSince(started)
        report["roster_count"] = composition.rosterModel.bots.count
        return (200, Self.json(report))
    }

    // MARK: Chat

    private struct ChatRun {
        let botID: String
        let before: Set<String>
        let headBefore: Int
        let began: Date
    }

    private func chat(_ args: [String: Any]) async -> (Int, Data) {
        guard let bot = args["bot"] as? String ?? ChatModel.shared.botRuntime?.rosterModel.bots.first(where: { DeviceBotRegistry.shared.deviceID(forBot: $0.id) != nil })?.id,
              let prompt = args["prompt"] as? String, !prompt.isEmpty,
              let model = await chatModel(bot) else { return (400, Self.json(["error": "prompt required (and a Bot)"])) }
        await BotProductionHub.shared.pullRows(for: bot)
        var head = 0
        if let domain = ChatModel.shared.botRuntime?.domain { head = (try? await domain.headCommitSeq()) ?? 0 }
        lastChat = ChatRun(botID: bot, before: Set(model.rows.map(\.id)), headBefore: head, began: Date())
        let wasActive = model.isPageActive
        if !wasActive { model.setPageActive(true) }
        _ = await ChatModel.shared.admitVoice(prompt, requestID: UUID().uuidString.lowercased(),
                                              target: .bot(botId: bot), boardName: "debug-channel")
        let wait = args["wait"] as? Double ?? 120
        return await turn(wait: wait, autoApprove: args["approve"] as? String)
    }

    /// Waits until the turn is quiet, an approval is pending (unless auto-approving) or `wait` seconds pass.
    private func turn(wait: Double, autoApprove: String? = nil) async -> (Int, Data) {
        guard let run = lastChat, let model = await chatModel(run.botID) else { return (400, Self.json(["error": "no chat started"])) }
        let deadline = Date().addingTimeInterval(wait)
        var quiet = 0, sawActivity = false
        var state = "timeout"
        while Date() < deadline {
            await BotProductionHub.shared.pullRows(for: run.botID)
            let running = model.runningTurnID != nil || model.live != nil
            let pending = model.rows.filter { row in
                guard row.body.type == "approval", !run.before.contains(row.id) else { return false }
                return (row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending") == "pending"
            }
            if let row = pending.last {
                if let mode = autoApprove, mode == "allow" || mode == "deny" {
                    model.decide(row: row, decision: mode == "deny" ? .deny : .allowOnce)
                } else { state = "awaiting_approval"; break }
            }
            if running { sawActivity = true; quiet = 0 } else if sawActivity { quiet += 1 }
            if !running, quiet >= 4, Self.answer(model, before: run.before) != nil { state = "done"; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        var calls: [[String: Any]] = []
        if let domain = ChatModel.shared.botRuntime?.domain {
            var cursor = run.headBefore
            var byID: [String: Int] = [:]
            while let batch = try? await domain.events(after: cursor, limit: 200), !batch.isEmpty {
                for event in batch {
                    cursor = event.commitSeq ?? cursor
                    let data = event.data
                    if event.type == "conversation.tool_call", let id = data["callId"]?.stringValue {
                        byID[id] = calls.count
                        calls.append(["name": data["name"]?.stringValue ?? "", "args": String((data["arguments"]?.stringValue ?? "").prefix(1500))])
                    } else if event.type == "conversation.tool_result",
                              let id = data["message"]?["source"]?["callId"]?.stringValue, let at = byID[id] {
                        let text = (data["message"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                        calls[at]["output"] = String(text.prefix(2500))
                        calls[at]["is_error"] = data["message"]?["isError"]?.boolValue == true
                    }
                }
                if batch.count < 200 { break }
            }
        }
        var out: [String: Any] = ["state": state, "bot": run.botID, "calls": calls,
                                  "seconds": Date().timeIntervalSince(run.began)]
        if let text = Self.answer(model, before: run.before) { out["final_text"] = text }
        return (200, Self.json(out))
    }

    private static func answer(_ model: BotChatModel, before: Set<String>) -> String? {
        guard let mine = model.rows.lastIndex(where: { $0.role == "user" && !before.contains($0.id) }) else { return nil }
        return model.rows[(mine + 1)...].last { BotChatModel.isAnswer($0) && !before.contains($0.id) }?.body["text"]?.string
    }
}
#endif
