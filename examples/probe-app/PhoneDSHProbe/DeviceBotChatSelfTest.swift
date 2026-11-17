// SPDX-License-Identifier: MIT
// DEBUG-only driver for the REAL device-Bot conversation on a physical device.
//
// !!! WARNING: THIS FILE AUTO-APPROVES THE DEVICE-APP INSTALL APPROVAL CARD (device-app.md §7). !!!
// !!! It plays the user's Allow-once tap and installs a model-written program on the device     !!!
// !!! with no human confirmation. It is compiled only under `#if DEBUG`, runs only with the      !!!
// !!! launch argument `-pdsh-selftest-device-bot-chat 1`, and MUST NEVER SHIP in a release.      !!!
//
// Everything except the human tap is real: the model, the Bot bound to the Link device, the
// DeviceAppStage / DeviceAppInstall tools, the validator, the digest, the approval row, the
// installer and the Link. The approval is resolved through `BotChatModel.decide(row:decision:)`,
// the call the card's Allow-once button makes (-> BotApprovalCoordinator.resolve with the digest
// the card binds). No key or token is read into the evidence; file contents are written only to
// the app directory, never into the JSON.
//
// Arguments: -pdsh-selftest-device-bot-chat 1
//            [-pdsh-selftest-prompt <text>] [-pdsh-selftest-name <device name>]
//            [-pdsh-selftest-approve 1|0]   (0: record the approval, do not resolve it, stop)
// Evidence: Documents/selftest-device-bot-chat.json (flushed after every step) and
//           Documents/selftest-device-bot-chat-app/ (the model-authored files).
#if DEBUG
import CryptoKit
import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHBot
import UIKit
#if canImport(ProbeKit)
import ProbeKit
#endif

@MainActor
enum DeviceBotChatSelfTest {
    static let argument = "-pdsh-selftest-device-bot-chat"
    static let promptArgument = "-pdsh-selftest-prompt"
    static let nameArgument = "-pdsh-selftest-name"
    static let approveArgument = "-pdsh-selftest-approve"
    static let totalCap: TimeInterval = 780
    static let turnCap: TimeInterval = 600
    static let defaultPrompt = "请为你这台设备的屏幕做一个简单的专注计时小应用（比如 25 分钟倒计时，按键开始、暂停、返回），写好检查后装到设备上。"

    static var requested: Bool { DeviceAppSelfTest.argumentValue(argument) == "1" }
    private static var started = false

    static func runIfRequested() async {
        guard requested, !started else { return }
        started = true
        await Run().execute()
    }

    @MainActor private final class Run {
        let started = Date()
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var facts: [String: Any] = [:]
        var finished = false
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var file: URL { documents.appendingPathComponent("selftest-device-bot-chat.json") }
        var appDir: URL { documents.appendingPathComponent("selftest-device-bot-chat-app") }
        let approve = DeviceAppSelfTest.argumentValue(DeviceBotChatSelfTest.approveArgument) != "0"

        func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
        func elapsed() -> Double { (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        var remaining: TimeInterval { DeviceBotChatSelfTest.totalCap - Date().timeIntervalSince(started) }

        func log(_ step: String, _ detail: [String: Any] = [:]) {
            var entry: [String: Any] = ["t": stamp(), "elapsed_s": elapsed(), "step": step]
            for (key, value) in detail { entry[key] = value }
            steps.append(entry)
            flush(done: false)
        }

        func fail(_ reason: String) {
            failures.append(reason)
            log("failure", ["reason": reason].merging(engineFacts()) { a, _ in a })
        }

        /// The engine/host state the delivery path depends on (no conversation text).
        func engineFacts() -> [String: Any] {
            let chat = ChatModel.shared
            return ["engine_started": chat.isStarted, "engine_host_state": chat.hostState,
                    "engine_status": chat.statusLine, "engine_error": chat.userFacingError ?? "",
                    "engine_needs_reset": chat.engineNeedsReset, "engine_busy": chat.busy,
                    "app_state": UIApplication.shared.applicationState.rawValue]
        }

        func flush(done: Bool, ok: Bool? = nil) {
            var root: [String: Any] = [
                "started": ISO8601DateFormatter().string(from: started), "updated": stamp(),
                "done": done, "cap_s": DeviceBotChatSelfTest.totalCap, "approve_mode": approve,
                "steps": steps, "failures": failures, "facts": facts,
            ]
            if let ok { root["ok"] = ok }
            guard JSONSerialization.isValidJSONObject(root),
                  let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: file, options: .atomic)
        }

        func finish(ok: Bool) {
            guard !finished else { return }
            finished = true
            facts["total_s"] = elapsed()
            flush(done: true, ok: ok && failures.isEmpty)
        }

        func plain(_ value: JSONValue?) -> Any {
            guard let value, let data = try? JSONEncoder().encode(value),
                  let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return NSNull() }
            return any
        }

        static func sha256(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        func execute() async {
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DeviceBotChatSelfTest.totalCap))
                guard let self, !self.finished else { return }
                self.fail("total cap \(Int(DeviceBotChatSelfTest.totalCap)) s reached")
                self.finish(ok: false)
            }
            Task { @MainActor [weak self] in
                for delay in [6, 14, 30] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !self.finished else { return }
                    self.log("engine.state", self.engineFacts())
                }
            }
            log("start", ["arguments": Array(CommandLine.arguments.dropFirst())
                .map { $0.count > 300 ? String($0.prefix(300)) + "..." : $0 }])
            let ok = await body()
            watchdog.cancel()
            finish(ok: ok)
        }

        // MARK: Body

        func body() async -> Bool {
            let store = BLEDeviceStore.shared
            store.trustConnectedDevices = true
            let wanted = DeviceAppSelfTest.argumentValue(DeviceBotChatSelfTest.nameArgument) ?? "PDSH Passport"
            let prompt = DeviceAppSelfTest.argumentValue(DeviceBotChatSelfTest.promptArgument)
                ?? DeviceBotChatSelfTest.defaultPrompt

            // 1a. Passport connected with all eight app.* tools (same logic as DeviceAppSelfTest).
            guard let device = await connectDevice(store: store, wanted: wanted) else { return false }
            let deviceID = device.id

            // 1b. Bot runtime up and a Bot bound to the device.
            guard let botID = await waitForBot(device: device) else { return false }
            let botName = BotProductionHub.shared.roster?.bots.first { $0.id == botID }?.name ?? ""
            facts["bot_id"] = botID
            facts["bot_name"] = botName
            log("bot.bound", ["bot_id": botID, "bot_name": botName])

            // 2. Model configured? Booleans and names only; no key or token is read into evidence.
            guard modelUsable() else { return false }

            // 3. Offered tools and persona guide.
            await checkToolsAndPersona(botID: botID, device: device)

            // 4. The real user turn.
            guard let model = await chatModel(botID) else { return false }
            var turn = await runTurn(model: model, botID: botID, prompt: prompt, device: device)
            if let reason = turn.failure { fail(reason) }

            // 5. app.info.
            turn.digestMatches = await checkInstalled(deviceID: deviceID, turn: turn)
            writeAppFiles(turn)

            // 6. Verdict.
            var ok = true
            if !turn.stageOK { ok = false; fail("model never made a successful DeviceAppStage") }
            if turn.approvalID == nil { ok = false; fail("no approval row was raised") }
            if !turn.installOK { ok = false; fail("DeviceAppInstall did not report installed") }
            if !turn.digestMatches { ok = false; fail("installed digest does not equal the approved digest") }
            facts["verdict"] = ["stage_ok": turn.stageOK, "approval_raised": turn.approvalID != nil,
                                "install_ok": turn.installOK, "digest_equal": turn.digestMatches]
            log("final", facts["verdict"] as? [String: Any] ?? [:])
            return ok
        }

        // MARK: Step 1

        func connectDevice(store: BLEDeviceStore, wanted: String) async -> BLEDeviceStore.Device? {
            let scanStart = Date()
            log("scan.begin", ["wanted": wanted, "store_status": store.status])
            var target: BLEDeviceStore.Device?
            var lastScan = Date.distantPast
            let scanDeadline = min(60, remaining)
            while !finished, Date().timeIntervalSince(scanStart) < scanDeadline {
                if Date().timeIntervalSince(lastScan) > 8 { store.scan(); lastScan = Date() }
                // The saved device keeps the Bot's name after the first run renamed it ("AI Passport"),
                // and it shows rssi 0 until it advertises again; connecting by id still works.
                if let found = store.devices.first(where: { $0.name == wanted })
                    ?? store.devices.first(where: { $0.name.contains("Passport") }) { target = found; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let found = target else {
                log("scan.diagnostic", ["store_status": store.status, "device_count": store.devices.count,
                                        "devices": store.devices.map { "\($0.name)|\($0.state)|rssi=\($0.rssi)" }])
                fail("scan timeout: no peripheral named \(wanted) within \(Int(scanDeadline)) s")
                return nil
            }
            log("scan.found", snapshot(found))
            let connectStart = Date()
            if found.state == "未连接" { store.connect(found.id) }
            var device = found
            var lastState = ""
            let expected = ["app.info", "app.begin", "app.put", "app.abort", "app.commit", "app.run", "app.stop", "app.remove"]
            while !finished, Date().timeIntervalSince(connectStart) < min(60, remaining) {
                if let now = store.devices.first(where: { $0.id == found.id }) {
                    device = now
                    let key = "\(now.state)|\(now.linkState)|\(now.linkTools.count)|\(now.linkDeviceID.isEmpty)"
                    if key != lastState { lastState = key; log("connect.state", snapshot(now)) }
                    if now.state == "未连接", Date().timeIntervalSince(connectStart) > 3,
                       Int(Date().timeIntervalSince(connectStart)) % 10 == 0 { store.connect(found.id) }
                    if !now.linkDeviceID.isEmpty, expected.allSatisfy(now.linkTools.contains) {
                        log("connect.ready", snapshot(now))
                        facts["device_id"] = now.linkDeviceID
                        facts["device_name"] = now.name
                        return now
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            fail("link not ready within 60 s: state=\(device.state) linkState=\(device.linkState) tools=\(device.linkTools.count) missing=\(expected.filter { !device.linkTools.contains($0) })")
            return nil
        }

        func snapshot(_ device: BLEDeviceStore.Device) -> [String: Any] {
            ["id": device.id.uuidString, "name": device.name, "state": device.state, "linkState": device.linkState,
             "linkDeviceID": device.linkDeviceID, "tools": device.linkTools.count, "rssi": device.rssi]
        }

        func waitForBot(device: BLEDeviceStore.Device) async -> String? {
            let begin = Date()
            var lastNote = ""
            let resetBot = ProcessInfo.processInfo.arguments.contains("-pdsh-selftest-reset-device-bot")
            var didReset = false
            var staleBotID: String?
            while !finished, Date().timeIntervalSince(begin) < min(60, remaining) {
                let runtimeUp = ChatModel.shared.botRuntime != nil
                let key = device.linkDeviceID.lowercased()
                let bound = DeviceBotRegistry.shared.botID(forDevice: key)
                let note = "runtime=\(runtimeUp) state=\(String(describing: ChatModel.shared.botRuntimeState)) bound=\(bound ?? "nil")"
                if note != lastNote { lastNote = note; log("bot.wait", ["detail": note]) }
                if runtimeUp, let bound {
                    // `-pdsh-selftest-reset-device-bot 1`: delete the (test-created) device Bot through the
                    // product's delete flow and let the registry make a fresh one with a fresh session.
                    // Needed after the engine state was moved aside (its old session is gone).
                    if resetBot, !didReset, let composition = ChatModel.shared.botRuntime {
                        didReset = true
                        do {
                            try await composition.deleteBot(bound)
                            log("bot.reset", ["deleted": bound])
                            staleBotID = bound
                        } catch { log("bot.reset", ["error": String(describing: error)]) }
                    } else if bound != staleBotID {
                        return bound
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            fail("no Bot bound to the device within 60 s (\(lastNote)); issue=\(ChatModel.shared.botRuntimeIssue ?? "none")")
            return nil
        }

        // MARK: Step 2 and 3

        func modelUsable() -> Bool {
            let settings = PhoneModelProviderSettings.shared
            do {
                guard let profile = try settings.load().selected else {
                    facts["modelConfigured"] = false
                    log("model", ["modelConfigured": false])
                    fail("no model configured")
                    return false
                }
                let status = try settings.apiKeyStatus(for: profile.id)
                let present: Bool
                if case .present = status { present = true } else { present = false }
                let host = URL(string: profile.baseURL)?.host ?? ""
                facts["modelConfigured"] = present
                facts["provider"] = ["kind": "saved_provider_profile", "name": profile.displayName,
                                     "host": host, "model": profile.model]
                log("model", ["modelConfigured": present, "provider_name": profile.displayName,
                              "provider_host": host, "model": profile.model, "provider_kind": "saved_provider_profile"])
                if !present { fail("no model configured"); return false }
                return true
            } catch {
                facts["modelConfigured"] = false
                fail("no model configured")
                return false
            }
        }

        func checkToolsAndPersona(botID: String, device: BLEDeviceStore.Device) async {
            if let runtime = ChatModel.shared.botRuntime?.runtime {
                let names = await runtime.toolDefinitions(callerBotID: botID).map(\.name)
                let hasStage = names.contains(DeviceAppToolNames.stage)
                let hasInstall = names.contains(DeviceAppToolNames.install)
                facts["offered_tools"] = names
                log("tools.offered", ["names": names, "has_stage": hasStage, "has_install": hasInstall])
                if !hasStage || !hasInstall { fail("offered tools lack DeviceAppStage/DeviceAppInstall") }
            } else {
                fail("Bot runtime unavailable for the tool list")
            }
            // The same decorator the persona provider uses, applied to an empty base.
            let decorated = (try? await DeviceAppWiring.decoratePersona { _, _, _ in "" }(botID, "selftest", .chat)) ?? ""
            let carries = decorated.contains("设备应用作者指南 v\(DeviceAppAuthoringGuide.version)")
            facts["persona_guide_version"] = DeviceAppAuthoringGuide.version
            facts["persona_carries_guide"] = carries
            log("persona", ["guide_version": DeviceAppAuthoringGuide.version, "carries_guide": carries])
            if !carries { fail("persona does not carry the authoring guide") }
        }

        /// Identity facts for the Bot's live MCP session(s): does the gateway resolve the session to this Bot,
        /// and which tool names does `tools/list` return for that session versus the global (header-less)
        /// list the Worker's MCP client reads. Session ids are public handles; no token is read or recorded.
        func probeIdentity(botID: String, label: String) async {
            guard let composition = ChatModel.shared.botRuntime else { return }
            let runtime = composition.runtime
            let ids = await runtime.activeSessionIDs().sorted()
            var sessions: [[String: Any]] = []
            for id in ids {
                let caller = await runtime.callerBotID(forSession: id)
                guard caller == botID else { continue }
                let listed = await composition.handler.rpc(
                    method: "tools/list", params: .object([:]), id: .string("selftest-list"),
                    headers: [BotMCPHandler.callerSessionHeader: id])
                let names = (listed["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
                sessions.append(["session_id": id, "resolves_to_bot": true, "tools_list_count": names.count,
                                 "tools_list_has_stage": names.contains(DeviceAppToolNames.stage),
                                 "tools_list_has_install": names.contains(DeviceAppToolNames.install)])
            }
            let global = await composition.handler.rpc(
                method: "tools/list", params: .object([:]), id: .string("selftest-global"), headers: [:])
            let gnames = (global["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            let facts: [String: Any] = [
                "label": label, "active_sessions": ids.count, "bot_sessions": sessions,
                "global_list_count": gnames.count,
                "global_list_has_stage": gnames.contains(DeviceAppToolNames.stage),
                "global_list_has_install": gnames.contains(DeviceAppToolNames.install),
                "global_list_has_ble_devices": gnames.contains("ble_devices")]
            self.facts["identity_\(label)"] = facts
            log("identity.probe", facts)
        }

        func chatModel(_ botID: String) async -> BotChatModel? {
            // The hub reports `unavailable` while the Bot runtime is still binding right after launch.
            var lastError: Error?
            for attempt in 0..<30 {
                do { return try await BotProductionHub.shared.chatModel(ensuring: botID) } catch {
                    lastError = error
                    if attempt == 0 { log("chatModel.retry", ["error": "\(error)"]) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            fail("chatModel(ensuring:) failed: \(lastError.map { "\($0)" } ?? "unknown")")
            return nil
        }

        // MARK: Step 4

        struct Call {
            var id: String
            var name = ""
            var argsRaw = ""
            var output = ""
            var isError = false
            var order = 0
        }

        struct Turn {
            var calls: [String: Call] = [:]
            var approvalID: String?
            var approvalRowID: String?
            var approvedDigest = ""      // the app digest named in DeviceAppInstall
            var stageOK = false
            var stageDigest = ""
            var appName = ""
            var installOK = false
            var digestMatches = false
            var stageFiles: [(path: String, content: String)] = []
            var finalText = ""
            var failure: String?
        }

        func bare(_ name: String) -> String { name.components(separatedBy: "__").last ?? name }

        func jsonObject(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        func collectCalls(_ model: BotChatModel, into turn: inout Turn) {
            var items: [ChatItem] = []
            for process in model.turnProcesses.values { items += process.items }
            if let live = model.live { items += live.tools }
            for item in items {
                guard let callID = item.callID, !callID.isEmpty else { continue }
                var call = turn.calls[callID] ?? Call(id: callID, order: turn.calls.count)
                if let name = item.toolName, !name.isEmpty { call.name = name }
                if let raw = item.argumentsRaw, !raw.isEmpty { call.argsRaw = raw }
                if let output = item.toolOutput, !output.isEmpty { call.output = output }
                else if case .toolResult = item.kind, !item.text.isEmpty { call.output = item.text }
                if case .toolResult(let isError) = item.kind, isError { call.isError = true }
                turn.calls[callID] = call
            }
        }

        /// The UI process list is empty when no chat page renders it, so the durable event log is the second
        /// source: every `conversation.tool_call` / `tool_result` after `afterSeq`, keyed by callId.
        func collectDurableCalls(afterSeq: Int, into turn: inout Turn) async -> [String] {
            guard let domain = ChatModel.shared.botRuntime?.domain else { return [] }
            var order: [String] = []
            var cursor = afterSeq
            while let batch = try? await domain.events(after: cursor, limit: 200), !batch.isEmpty {
                for event in batch {
                    cursor = event.commitSeq ?? cursor
                    let data = event.data
                    if event.type == "conversation.tool_call", let callID = data["callId"]?.stringValue {
                        var call = turn.calls[callID] ?? Call(id: callID, order: turn.calls.count)
                        call.name = data["name"]?.stringValue ?? call.name
                        if let raw = data["arguments"]?.stringValue, !raw.isEmpty { call.argsRaw = raw }
                        turn.calls[callID] = call
                        order.append(bare(call.name))
                    } else if event.type == "conversation.tool_result",
                              let callID = data["message"]?["source"]?["callId"]?.stringValue,
                              var call = turn.calls[callID] {
                        let text = (data["message"]?["content"]?.arrayValue ?? [])
                            .compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                        if !text.isEmpty { call.output = text }
                        if data["message"]?["isError"]?.boolValue == true { call.isError = true }
                        turn.calls[callID] = call
                    }
                }
                if batch.count < 200 { break }
            }
            return order
        }

        func runTurn(model: BotChatModel, botID: String, prompt: String, device: BLEDeviceStore.Device) async -> Turn {
            var turn = Turn()
            var headBefore = 0
            if let domain = ChatModel.shared.botRuntime?.domain { headBefore = (try? await domain.headCommitSeq()) ?? 0 }
            let wasActive = model.isPageActive
            if !wasActive { model.setPageActive(true) }
            defer { if !wasActive { model.setPageActive(false) } }
            try? await Task.sleep(for: .milliseconds(500))
            await BotProductionHub.shared.pullRows(for: botID)
            // A fresh Bot (reset run) starts with its own onboarding turn. Sending while it runs
            // leaves the prompt queued behind a turn that waits for a card choice, so wait until
            // the Bot is idle (a quiet streak of polls, at most 30 s) before the real prompt.
            do {
                let idleBegin = Date()
                var quiet = 0
                while !finished, quiet < 5, Date().timeIntervalSince(idleBegin) < 30 {
                    await BotProductionHub.shared.pullRows(for: botID)
                    if model.runningTurnID == nil && model.live == nil { quiet += 1 } else { quiet = 0 }
                    try? await Task.sleep(for: .seconds(1))
                }
                log("turn.idle_wait", ["waited_s": Int(Date().timeIntervalSince(idleBegin)), "quiet": quiet])
            }
            if let domain = ChatModel.shared.botRuntime?.domain { headBefore = (try? await domain.headCommitSeq()) ?? 0 }
            if let archived = await ChatModel.shared.botRuntime?.debugArchivedSessionIDs() {
                log("archive.diag", ["archived_count": archived.count,
                                     "bot_session_archived": archived.contains("gb-\(botID)"),
                                     "archived_gb": archived.filter { $0.hasPrefix("gb-") }])
                if archived.contains("gb-\(botID)"),
                   let after = await ChatModel.shared.botRuntime?.debugArchivedSessionIDs(unarchive: "gb-\(botID)") {
                    log("archive.unarchived", ["archived_count_after": after.count])
                }
            } else { log("archive.diag", ["unavailable": true]) }
            let before = Set(model.rows.map(\.id))
            facts["prompt_sha256"] = Self.sha256(prompt)
            log("turn.send", ["prompt_chars": prompt.count, "rows_before": before.count])
            // The send path the TonoLink voice turn proved on this phone: admit durably (it starts the
            // engine and the Bot's runtime unit), not the page's `send`, which does nothing without UI.
            let requestID = UUID().uuidString.lowercased()
            // `admitVoice` returns only once the Bot has accepted the turn, which can be after the
            // turn already ran into its approval. Keep it off the polling path, otherwise the
            // approval card would sit unanswered past the Worker's tool-call timeout.
            let admitTask = Task { @MainActor in
                await ChatModel.shared.admitVoice(
                    prompt, requestID: requestID, target: .bot(botId: botID), boardName: "selftest")
            }
            final class AdmitBox { var done = false; var receiptMissing = false; var result = "nil" }
            let admitBox = AdmitBox()
            let monitor = Task { @MainActor [weak self] in
                let outcome = await admitTask.value
                admitBox.done = true
                admitBox.receiptMissing = outcome?.receipt == nil
                admitBox.result = outcome?.result.rawValue ?? "nil"
                self?.log("turn.admitted", ["admitted": outcome?.receipt != nil,
                                            "result": outcome?.result.rawValue ?? "nil"])
                let admissionID = outcome?.receipt?.admissionId ?? ""
                var last = ""
                while !Task.isCancelled {
                    guard let self, !self.finished else { return }
                    let snap = await self.admissionSnapshot(admissionID: admissionID, botID: botID, model: model)
                    let key = snap.filter { $0.key != "t_rel" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "|")
                    if key != last { last = key; self.log("admission.state", snap) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { monitor.cancel() }
            await probeIdentity(botID: botID, label: "after_admit")

            let begin = Date()
            var reported: [String: String] = [:]      // callID -> last recorded signature
            var resolvedRows: Set<String> = []
            var sawActivity = false
            var quietPolls = 0
            var stopForApproveZero = false
            while !finished, Date().timeIntervalSince(begin) < min(DeviceBotChatSelfTest.turnCap, remaining - 5) {
                await BotProductionHub.shared.pullRows(for: botID)
                collectCalls(model, into: &turn)
                let running = model.runningTurnID != nil || model.live != nil

                for call in turn.calls.values.sorted(by: { $0.order < $1.order }) {
                    let signature = "\(call.name)|\(call.argsRaw.count)|\(call.output.count)|\(call.isError)"
                    guard reported[call.id] != signature else { continue }
                    reported[call.id] = signature
                    record(call: call, turn: &turn)
                }

                // Approval rows.
                for row in model.rows where row.body.type == "approval" && !before.contains(row.id) {
                    let status = row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending"
                    let approvalID = row.body.string("approvalID", "requestId", "id") ?? ""
                    let digest = row.body["digest"]?.string ?? ""
                    let detail = row.body.string("detail", "command", "text") ?? ""
                    guard status == "pending", !digest.isEmpty, detail.contains("设备") else {
                        if status != "pending", resolvedRows.contains(row.id) {
                            log("approval.status", ["row": row.id, "status": status])
                        }
                        continue
                    }
                    guard !resolvedRows.contains(row.id) else { continue }
                    resolvedRows.insert(row.id)
                    turn.approvalID = approvalID
                    turn.approvalRowID = row.id
                    let digest8 = String(turn.approvedDigest.prefix(8))
                    log("approval.raised", [
                        "row": row.id, "approval_id": approvalID, "status": status,
                        "body_keys": row.body.values.keys.sorted(),
                        "detail": String(detail.prefix(1200)),
                        "names_device": detail.contains(device.linkDeviceID) || detail.contains(device.name),
                        "names_app": !turn.appName.isEmpty && detail.contains(turn.appName),
                        "names_files": !turn.stageFiles.isEmpty && turn.stageFiles.allSatisfy { detail.contains($0.path) },
                        "names_permissions": detail.contains("权限"),
                        "names_digest8": !digest8.isEmpty && detail.contains(digest8),
                    ])
                    if approve {
                        log("approval.resolve", ["decision": "allowOnce", "via": "BotChatModel.decide (the Allow-once button's call)"])
                        model.decide(row: row, decision: .allowOnce)
                    } else {
                        log("approval.left_pending", ["reason": "-pdsh-selftest-approve 0"])
                        stopForApproveZero = true
                    }
                }
                if stopForApproveZero { break }

                // Turn end: activity seen, nothing running, quiet for several polls, an answer exists.
                if running { sawActivity = true; quietPolls = 0 } else if sawActivity || !turn.calls.isEmpty { quietPolls += 1 }
                if !running, quietPolls >= 4, let answer = latestAnswer(model, before: before), !answer.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if admitBox.done, admitBox.receiptMissing {
                turn.failure = "the prompt was not admitted (\(admitBox.result))"
            }
            collectCalls(model, into: &turn)
            await probeIdentity(botID: botID, label: "after_turn")
            let durableOrder = await collectDurableCalls(afterSeq: headBefore, into: &turn)
            facts["tool_sequence"] = durableOrder
            log("tools.durable_sequence", ["names": durableOrder])
            for call in turn.calls.values.sorted(by: { $0.order < $1.order }) {
                let signature = "\(call.name)|\(call.argsRaw.count)|\(call.output.count)|\(call.isError)"
                if reported[call.id] != signature { reported[call.id] = signature; record(call: call, turn: &turn) }
            }
            turn.finalText = latestAnswer(model, before: before) ?? ""
            log("turn.end", ["running": model.runningTurnID != nil, "approve_zero_stop": stopForApproveZero,
                             "final_text": String(turn.finalText.prefix(500)),
                             "tool_calls": turn.calls.count,
                             "timed_out": Date().timeIntervalSince(begin) >= DeviceBotChatSelfTest.turnCap])
            if turn.calls.isEmpty { fail("the model made no tool call") }
            return turn
        }

        /// One line of what the admission journal and the delivery gates say right now.
        func admissionSnapshot(admissionID: String, botID: String, model: BotChatModel) async -> [String: Any] {
            let chat = ChatModel.shared
            var snap: [String: Any] = [
                "app_state": UIApplication.shared.applicationState.rawValue,
                "protected_data": UIApplication.shared.isProtectedDataAvailable,
                "execution_eligible": chat.executionEligible,
                "queued_delivery_eligible": chat.queuedDeliveryEligible,
                "chat_started": chat.isStarted, "chat_parked": chat.parked, "chat_busy": chat.busy,
                "engine_needs_reset": chat.engineNeedsReset, "chat_status": chat.statusLine,
                "bot_running_turn": model.runningTurnID != nil, "bot_rows": model.rows.count,
            ]
            switch BotProductionHub.shared.admissionTarget(for: botID) {
            case .ready: snap["admission_target"] = "ready"
            case .waiting: snap["admission_target"] = "waiting"
            case .missing: snap["admission_target"] = "missing"
            }
            if let record = await chat.externalAdmissionJournal.record(admissionId: admissionID) {
                snap["phase"] = record.stage.rawValue
                snap["attempts"] = record.attempts
                snap["last_error"] = record.lastError ?? ""
                if let next = record.nextAttemptAtMs { snap["next_attempt_in_ms"] = next - ExternalAdmissionJournal.nowMs() }
            } else {
                snap["phase"] = "no-record"
            }
            if let state = model.actionStates.first(where: { $0.key.hasPrefix("chat:local-") })?.value {
                snap["action_state"] = String(describing: state)
            }
            return snap
        }

        func latestAnswer(_ model: BotChatModel, before: Set<String>) -> String? {
            guard let mine = model.rows.lastIndex(where: { $0.role == "user" && !before.contains($0.id) }) else { return nil }
            return model.rows[(mine + 1)...].last { BotChatModel.isAnswer($0) && !before.contains($0.id) }?.body["text"]?.string
        }

        /// Records one tool call and extracts what the verdict needs. File contents never reach the JSON.
        func record(call: Call, turn: inout Turn) {
            let tool = bare(call.name)
            var entry: [String: Any] = [
                "name": call.name, "call_id": call.id,
                "args_sha256": Self.sha256(call.argsRaw), "args_bytes": call.argsRaw.utf8.count,
                "has_result": !call.output.isEmpty, "is_error": call.isError,
            ]
            let result = jsonObject(call.output)
            switch tool {
            case DeviceAppToolNames.stage:
                if let args = jsonObject(call.argsRaw), let files = args["files"] as? [[String: Any]] {
                    let parsed = files.compactMap { f -> (String, String)? in
                        guard let path = f["path"] as? String, let content = f["content"] as? String else { return nil }
                        return (path, content)
                    }
                    if !parsed.isEmpty && result?["ok"] as? Bool != false { turn.stageFiles = parsed }
                    else if turn.stageFiles.isEmpty { turn.stageFiles = parsed }
                }
                if let result {
                    let ok = result["ok"] as? Bool == true
                    entry["ok"] = ok
                    if ok {
                        let digest = result["digest"] as? String ?? ""
                        let app = result["app"] as? [String: Any]
                        entry["digest"] = digest
                        entry["app"] = app?["name"] as Any
                        entry["perms"] = app?["perms"] as Any
                        entry["files"] = (result["files"] as? [[String: Any]])?.map {
                            "\($0["path"] as? String ?? "?") \($0["size"] as? Int ?? 0)" } ?? []
                        turn.stageOK = true
                        turn.stageDigest = digest
                        turn.appName = app?["name"] as? String ?? turn.appName
                    } else {
                        entry["code"] = result["code"] as Any
                        entry["path"] = result["path"] as Any
                        entry["line"] = result["line"] as Any
                    }
                } else if !call.output.isEmpty {
                    entry["output"] = String(call.output.prefix(300))
                }
            case DeviceAppToolNames.install:
                if let args = jsonObject(call.argsRaw), let digest = args["digest"] as? String {
                    turn.approvedDigest = digest
                    entry["digest"] = digest
                }
                if let result {
                    let installed = result["installed"] as? Bool == true
                    entry["installed"] = installed
                    entry["audit_recorded"] = result["audit_recorded"] as Any
                    if installed {
                        turn.installOK = true
                        if let name = result["name"] as? String { turn.appName = name }
                    } else {
                        entry["output"] = String(call.output.prefix(400))
                    }
                } else if !call.output.isEmpty {
                    entry["output"] = String(call.output.prefix(400))
                    // The Worker's result row can carry only the text line of a success; the
                    // board's own `app.info` check below still decides the digest equality.
                    if !call.isError, call.output.hasPrefix("已在设备上安装") { turn.installOK = true }
                }
            default:
                break
            }
            log("tool.call", entry)
        }

        // MARK: Step 5

        func checkInstalled(deviceID: UUID, turn: Turn) async -> Bool {
            guard turn.installOK || !turn.appName.isEmpty else {
                log("info.skipped", ["reason": "no app name known"])
                return false
            }
            do {
                let outcome = try await callLinkTool(
                    deviceID: deviceID, name: "app.info", arguments: .object([:]),
                    idempotencyKey: "selftest.botchat.info.\(UUID().uuidString.lowercased())", origin: .user)
                guard case .completed(_, let reply) = outcome, reply["status"]?.stringValue == "completed",
                      let result = reply["result"], result["ok"]?.boolValue == true else {
                    fail("app.info did not complete")
                    return false
                }
                let apps = result["apps"]?.arrayValue ?? []
                let match = apps.first { $0["name"]?.stringValue == turn.appName }
                let installedDigest = match?["digest"]?.stringValue ?? ""
                let equal = !installedDigest.isEmpty && installedDigest == turn.approvedDigest
                facts["installed_digest"] = installedDigest
                facts["approved_digest"] = turn.approvedDigest
                log("info.after", ["apps": plain(result["apps"]), "app_name": turn.appName,
                                   "installed": match != nil, "installed_digest": installedDigest,
                                   "approved_digest": turn.approvedDigest, "equal": equal])
                if match == nil { fail("app \(turn.appName) is not listed by app.info") }
                return equal
            } catch {
                fail("app.info: \(error)")
                return false
            }
        }

        func writeAppFiles(_ turn: Turn) {
            guard !turn.stageFiles.isEmpty else { return }
            try? FileManager.default.removeItem(at: appDir)
            var written: [String] = []
            for item in turn.stageFiles {
                guard !item.path.contains(".."), !item.path.hasPrefix("/") else { continue }
                let url = appDir.appendingPathComponent(item.path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? item.content.write(to: url, atomically: true, encoding: .utf8)) != nil { written.append(item.path) }
            }
            log("app.files_written", ["dir": "Documents/selftest-device-bot-chat-app", "files": written])
        }
    }
}
#endif
