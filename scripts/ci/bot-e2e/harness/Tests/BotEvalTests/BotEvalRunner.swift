// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — the catalog-driven macOS test.
//
// eval.sh writes a validated plan and sets PDSH_BOT_EVAL_* in the environment.
// This test builds the production Bot composition (BotRuntimeComposition, the
// multi-Bot roster, one BotRuntimeUnit per Bot) on top of a real PhoneDSHHost
// and packed Worker, drives the plan's actions, evaluates the assertions and
// writes the four evidence files per scenario.

import AppKit
import Foundation
import XCTest
@testable import BotEvalApp
import PhoneDSH
import PhoneDSHBot
import PhoneDSHEngine
import PhoneDSHHarness
import PhoneDSHScenario
import PhoneDSHAgentCore
import PhoneDSHLog
import PhoneDSHWire

@MainActor
final class BotEvalRunnerTests: XCTestCase {
    func testCatalogPlan() async throws {
        guard let planPath = ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_PLAN"] else {
            throw XCTSkip("PDSH_BOT_EVAL_PLAN is not set; run scripts/ci/bot-e2e/eval.sh")
        }
        guard let resultsPath = ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_RESULTS"] else {
            throw EvalRunnerError.invalid("PDSH_BOT_EVAL_RESULTS is not set")
        }
        let plan = try EvalPlan.load(from: URL(fileURLWithPath: planPath))
        let results = URL(fileURLWithPath: resultsPath, isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let keepBodies = Self.keepBodiesEnabled()
        let realKey: String?
        if plan.upstream == "real" {
            guard let key = ProcessInfo.processInfo.environment["PDSH_MODEL_API_KEY"], !key.isEmpty else {
                throw EvalRunnerError.invalid("PDSH_MODEL_API_KEY is required for --upstream real")
            }
            realKey = key
        } else {
            realKey = nil
        }
        let secrets = realKey.map { [$0] } ?? []
        let redactor: (String) -> String = { text in
            EvalRedaction.redact(text, secrets: secrets)
        }
        let fixturesRoot = URL(fileURLWithPath: plan.fixturesRoot, isDirectory: true)
        var batchErrors: [String] = []
        for scenario in plan.scenarios {
            let directory = results.appendingPathComponent(scenario.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let workspaces = directory.appendingPathComponent("workspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
            let transcript = try EvalJSONLWriter(
                url: directory.appendingPathComponent("transcript.jsonl"), redactor: redactor)
            let botEvents = try EvalJSONLWriter(
                url: directory.appendingPathComponent("bot-events.jsonl"), redactor: redactor)
            defer {
                transcript.close()
                botEvents.close()
            }
            let started = Date()
            var repeats: [EvalRepeatRecord] = []
            var skipReason: String?
            transcript.append([
                "type": "scenario_start",
                "scenario": scenario.id,
                "upstream": plan.upstream,
                "repeat": plan.repeatCount,
                "at": EvalJSON.date(started),
            ])
            if let reason = scenario.skip {
                skipReason = reason
                transcript.append(["type": "scenario_skip", "scenario": scenario.id, "reason": reason])
            } else {
                for index in 1...plan.repeatCount {
                    do {
                        let record = try await runRepeat(
                            scenario: scenario, plan: plan, index: index,
                            results: results, fixturesRoot: fixturesRoot,
                            workspaces: workspaces, transcript: transcript,
                            botEvents: botEvents, redactor: redactor,
                            realKey: realKey)
                        repeats.append(record)
                    } catch {
                        let message = redactor(error.localizedDescription)
                        repeats.append(EvalRepeatRecord(
                            index: index, status: "ERROR", error: message,
                            actions: [], assertions: [], usage: Self.zeroUsage(),
                            events: [], replies: [], toolCalls: [], memories: [:],
                            workspaces: [:], autoDecisions: [], approvalRequests: [:],
                            wallSeconds: 0, pageVisibility: nil))
                        transcript.append([
                            "type": "repeat_error", "scenario": scenario.id,
                            "repeat": index, "error": message,
                        ])
                    }
                }
            }
            let finished = Date()
            let archiveError: String?
            do {
                try ScenarioTar.archive(
                    directory: workspaces,
                    to: directory.appendingPathComponent("workspace.tar"))
                archiveError = nil
            } catch {
                archiveError = redactor(error.localizedDescription)
                batchErrors.append("\(scenario.id): workspace.tar: \(error.localizedDescription)")
            }
            let report = buildReport(
                scenario: scenario, plan: plan, started: started, finished: finished,
                repeats: repeats, skipReason: skipReason, archiveError: archiveError,
                keepBodies: keepBodies, redactor: redactor)
            try EvalJSON.write(report, to: directory.appendingPathComponent("report.json"))
            // The event file is one line per durable event per repeat. It is
            // written after the report snapshot so both describe the same run.
            for record in repeats {
                for event in record.events {
                    guard let object = EvalJSON.eventObject(event) else { continue }
                    botEvents.append(["repeat": record.index, "event": object])
                }
            }
            transcript.append([
                "type": "scenario_end",
                "scenario": scenario.id,
                "status": report["status"] ?? "UNKNOWN",
                "gate": report["status"] ?? "UNKNOWN",
                "at": EvalJSON.date(finished),
            ])
        }
        if !batchErrors.isEmpty {
            throw EvalRunnerError.invalid(batchErrors.joined(separator: "; "))
        }
    }

    // MARK: - One repeat

    private func runRepeat(scenario: EvalScenario, plan: EvalPlan, index: Int,
                           results: URL, fixturesRoot: URL, workspaces: URL,
                           transcript: EvalJSONLWriter, botEvents: EvalJSONLWriter,
                           redactor: @escaping (String) -> String,
                           realKey: String?) async throws -> EvalRepeatRecord {
        let runRoot = results
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("\(scenario.id)-\(index)", isDirectory: true)
        if FileManager.default.fileExists(atPath: runRoot.path) {
            try? FileManager.default.removeItem(at: runRoot)
        }
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let echo = EvalEchoServer()
        try echo.start()
        defer { echo.stop() }
        let scenario = scenario.resolvingEchoFixture(echo)
        let schedulerClock = EvalSchedulerClock()
        let workspaceRoot = runRoot.appendingPathComponent("host", isDirectory: true)
        let store = try SQLiteDomainStore(fileURL: runRoot.appendingPathComponent("domain.sqlite"))
        let profileStore = BotProfileStore(directory: runRoot.appendingPathComponent("profiles"))
        let seeds = try EvalWorkspaceSeed.collect(scenario: scenario, fixturesRoot: fixturesRoot)
        let deferredSeeds = scenario.workspace.bot == "main" ? [] : seeds
        if scenario.workspace.bot == "main" {
            try await EvalWorkspaceSeed.seed(
                workspaceRoot: workspaceRoot, seeds: seeds, scenario: scenario, botID: "main")
        }
        var mock: MockModelUpstream?
        var modelBaseURL: URL
        var modelName: String
        var modelKey: String
        if plan.upstream == "mock" {
            let upstream = MockModelUpstream()
            try upstream.start()
            mock = upstream
            modelBaseURL = upstream.baseURL
            modelName = "mock"
            modelKey = "bot-eval-mock-key"
        } else {
            guard let base = ProcessInfo.processInfo.environment["PDSH_MODEL_BASE_URL"],
                  let url = URL(string: base),
                  let name = ProcessInfo.processInfo.environment["PDSH_MODEL_NAME"],
                  let key = realKey, !key.isEmpty else {
                throw EvalRunnerError.invalid(
                    "--upstream real requires PDSH_MODEL_BASE_URL, PDSH_MODEL_NAME and PDSH_MODEL_API_KEY")
            }
            modelBaseURL = url
            modelName = name
            modelKey = key
        }
        let credentialProvider = EvalModelCredentialProvider(
            modelBaseURL: modelBaseURL, modelKey: modelKey,
            anonymousHosts: Set(scenario.network.allow))
        let rules = EvalMockScripts.promptRules(scenario.mock)
        if let mock, !rules.isEmpty {
            mock.scriptForRequest = { body in
                EvalMockScripts.ruleScript(for: rules, body: body)
            }
        }
        mock?.script = EvalMockScripts.script(for: scenario.mock)
        let bundle = try Self.bundle()
        let launch = try await BotRuntimeComposition.prepare(
            store: store, profileStore: profileStore, selectedBotID: "main",
            now: { schedulerClock.now },
            sleep: { await schedulerClock.sleep(milliseconds: $0) })
        let mcpPolicy = MCPEgressPolicy()
        guard let serverURL = launch.composition.server.url else {
            throw EvalRunnerError.invalid("Bot MCP server did not publish a URL")
        }
        try mcpPolicy.grantBotRuntimeEndpoint(
            serverURL, token: launch.composition.server.token)
        var environment = launch.workerEnvironment
        environment["DEEPSEEK_BASE_URL"] = modelBaseURL.absoluteString
        environment["DEEPSEEK_API_KEY"] = ChatHostConfiguration.workerPlaceholderKey
        environment["PDSH_MODEL_NAME"] = modelName
        environment["DSH_TELEMETRY_DISABLED"] = "1"
        environment["PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS"] = "10000"
        let modelRule = ChatHostConfiguration.modelHostRule(for: modelBaseURL)
            ?? modelBaseURL.absoluteString
        var configuration = ChatHostConfiguration.makeProduction(
            workspaceRoot: workspaceRoot,
            bundle: bundle,
            allowedModelHosts: [modelRule],
            egressAllowHosts: Set(scenario.network.allow),
            credentialProvider: PhoneMCPCredentialProvider(
                policy: mcpPolicy, base: credentialProvider),
            egressAuthorizer: mcpPolicy,
            workerEnvironment: environment,
            nativeMCP: nil,
            drainDeadline: 5,
            helloTimeout: 180)
        configuration.engine.bootTimeout = 180
        configuration.turnInactivityTimeout = 600
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "phone-dsh bot-eval \(scenario.id) #\(index)"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        window.contentView = container
        WebEngineAppKitEventPump.show(window)
        let engineHolder = EvalEngineHolder()
        let host = PhoneDSHHost(configuration: configuration) { engineConfiguration in
            try await MainActor.run {
                let engine = WebEngine(configuration: engineConfiguration)
                engine.attach(to: container)
                engineHolder.engine = engine
                return engine as any WebEngineControlling
            }
        }
        defer {
            mock?.stop()
            window.close()
        }
        var composition: BotRuntimeComposition? = launch.composition
        var pageVisibility: [String: Any]?
        let started = Date()
        do {
            try await pumped(timeout: 240) {
                try await launch.composition.start(host: host)
            }
            if let engine = engineHolder.engine {
                do {
                    let visibility = try await harnessAssertPageVisible(
                        engine, label: "bot-eval \(scenario.id) #\(index)")
                    pageVisibility = harnessDescribePageVisibility(visibility)
                } catch {
                    throw EvalRunnerError.invalid(
                        "page visibility precondition failed: \(error.localizedDescription)")
                }
            }
            let context = EvalRunContext(
                scenario: scenario, plan: plan, composition: launch.composition,
                host: host, store: store, mock: mock, credentialProvider: credentialProvider,
                workspaceRoot: workspaceRoot, resultsDirectory: results,
                fixturesRoot: fixturesRoot, transcript: transcript,
                botEvents: botEvents, redactor: redactor,
                deferredSeeds: deferredSeeds, schedulerClock: schedulerClock)
            var actionRecords: [[String: Any]] = []
            var fatal: Error?
            for action in scenario.actions {
                let actionStart = Date()
                do {
                    let outcome = try await execute(
                        action: action, context: context, repeat: index)
                    context.replies.append(contentsOf: outcome.replies)
                    let record = actionRecord(
                        action: action, outcome: outcome, start: actionStart)
                    actionRecords.append(record)
                    transcript.append(record.merging(["type": "action", "repeat": index]) { _, new in new })
                    for reply in outcome.replies {
                        transcript.append(replyTranscript(
                            reply, action: action, repeat: index,
                            keepBodies: Self.keepBodiesEnabled()))
                    }
                } catch {
                    let message = redactor("\(error.localizedDescription) [\(String(describing: error))]")
                    print("BOT_EVAL_ACTION_ERROR \(scenario.id): \(String(describing: error))")
                    let record: [String: Any] = [
                        "index": action.index ?? actionRecords.count,
                        "type": action.type,
                        "bot": action.bot ?? "main",
                        "status": (error as? EvalRunnerError)?.isUnimplemented == true
                            ? "unimplemented" : "error",
                        "detail": message,
                    ]
                    actionRecords.append(record)
                    transcript.append(record.merging(["type": "action", "repeat": index]) { _, new in new })
                    fatal = error
                    break
                }
            }
            let allEvents = try await BotProductionEventReader.all(domain: store)
            let calls = try await collectToolCalls(
                events: allEvents, context: context)
            let memories = await collectMemories(context: context)
            let botWorkspaces = workspacePaths(context: context)
            let approvalCounts = Dictionary(grouping: allEvents.filter { $0.type == "approval.requested" },
                                            by: { $0.principal.botId ?? "main" })
                .mapValues(\.count)
            let snapshot = EvalSnapshot(
                mainBotID: context.mainBotID,
                botIDs: context.aliases,
                events: allEvents,
                replies: context.replies,
                toolCalls: calls,
                memories: memories,
                workspaces: botWorkspaces,
                scratchRoot: runRoot.appendingPathComponent("check-workspaces", isDirectory: true),
                echoRequests: echo.requests)
            try FileManager.default.createDirectory(
                at: snapshot.scratchRoot, withIntermediateDirectories: true)
            var assertionResults: [EvalAssertionResult] = []
            for assertion in scenario.assertions {
                let result = EvalAssertions.evaluate(assertion, snapshot: snapshot)
                assertionResults.append(result)
                transcript.append([
                    "type": "assertion", "repeat": index,
                    "assertion": result.type, "ok": result.ok,
                    "expected_ok": result.expectedOK,
                    "bot": result.bot ?? "main",
                    "turn": result.turn.map { $0 as Any } ?? NSNull(),
                    "detail": redactor(result.detail),
                ])
            }
            let wall = Date().timeIntervalSince(started)
            let status: String
            if fatal != nil {
                status = "ERROR"
            } else if assertionResults.allSatisfy(\.ok) {
                status = "PASS"
            } else {
                status = "FAIL"
            }
            let usage = usageObject(
                provider: credentialProvider, mock: mock,
                wall: wall,
                budget: scenario.budget)
            let record = EvalRepeatRecord(
                index: index, status: status,
                error: fatal.map { redactor($0.localizedDescription) },
                actions: actionRecords, assertions: assertionResults,
                usage: usage, events: allEvents, replies: context.replies,
                toolCalls: calls, memories: memories, workspaces: botWorkspaces,
                autoDecisions: context.autoDecisions,
                approvalRequests: approvalCounts,
                wallSeconds: wall, pageVisibility: pageVisibility)
            if Self.keepBodiesEnabled(), let mock {
                writeBodies(mock, scenario: scenario, repeat: index,
                            results: results, redactor: redactor)
            }
            copyWorkspace(workspaceRoot: workspaceRoot, to: workspaces, index: index)
            transcript.append([
                "type": "repeat_end", "repeat": index, "status": status,
                "wall_s": wall, "model_requests": credentialProvider.modelRequests,
            ])
            await launch.composition.stop()
            schedulerClock.wakeAll()
            composition = nil
            try? await host.stop()
            try? await store.close()
            return record
        } catch {
            let message = redactor(error.localizedDescription)
            transcript.append(["type": "repeat_error", "repeat": index, "error": message])
            await launch.composition.stop()
            schedulerClock.wakeAll()
            composition = nil
            try? await host.stop()
            try? await store.close()
            throw error
        }
    }

    // MARK: - Actions

    private func execute(action: EvalAction, context: EvalRunContext,
                         repeat index: Int) async throws -> EvalActionOutcome {
        switch action.type {
        case "create_bot":
            let name = action.name ?? "Eval Bot"
            let profile = try await context.composition.createBot(
                name: name, description: action.description ?? "",
                color: nil, hairstyle: nil)
            if let alias = action.alias {
                context.aliases[alias] = profile.id
            }
            _ = try await context.composition.ensureUnit(for: profile.id, reason: "eval-create")
            if let alias = action.alias, context.scenario.workspace.bot == alias {
                try EvalWorkspaceSeed.seedMaterialized(
                    workspaceRoot: context.workspaceRoot,
                    seeds: context.deferredSeeds,
                    scenario: context.scenario, botID: profile.id)
            }
            return EvalActionOutcome(
                status: "ok",
                detail: "created \(profile.id)",
                replies: [])

        case "user_message":
            let botID = try context.botID(for: action.bot)
            let unit = try await context.unit(for: botID)
            let turn = context.nextTurn(botID)
            let cursor = try await context.lastCommitSeq()
            context.installMock(action.mock ?? context.scenario.mock)
            let watcher = context.startApprovalWatcher()
            let result: BotActionResult
            do {
                let nonce = context.nonce("chat", action: action, repeat: index)
                result = try await pumped(timeout: context.actionTimeout(action)) {
                    try await unit.rows.perform(BotUserAction(
                        nonce: nonce, botID: botID, kind: .chat,
                        text: action.text ?? ""))
                }
            } catch {
                watcher.cancel()
                throw error
            }
            watcher.cancel()
            let replies = try await context.replies(
                after: cursor, botID: botID, turn: turn,
                action: action, repeat: index)
            if case .rejected(let reason) = result {
                throw EvalRunnerError.action("turn rejected: \(reason)")
            }
            if case .stale(let reason) = result {
                throw EvalRunnerError.action("action stale: \(reason)")
            }
            return EvalActionOutcome(status: "ok", detail: nil, replies: replies)

        case "seed_held_item":
            let botID = try context.botID(for: action.bot)
            let unit = try await context.unit(for: botID)
            let itemID = "held-eval-\(UUID().uuidString.lowercased())"
            let item = try WakeInboxItem(
                id: itemID,
                kind: action.kind ?? "eval-fixture",
                fromAgentId: action.fromAgentID,
                fromAgentName: action.fromAgentName ?? "eval",
                title: action.title,
                text: action.text ?? "",
                requestId: action.requestID ?? "held-eval-\(UUID().uuidString.lowercased())",
                createdAt: Self.nowMilliseconds())
            let enqueued = try await unit.wakeInbox.enqueue(item)
            return EvalActionOutcome(
                status: enqueued.ok ? "ok" : "error",
                detail: "held item \(enqueued.item.id) duplicate=\(enqueued.duplicate)",
                replies: [])

        case "ui_action":
            return try await executeUI(action, context: context, repeat: index)

        case "approval_policy":
            context.policy = EvalApprovalPolicy(
                defaultDecision: action.policyDefault ?? "manual",
                rules: action.policyRules ?? [],
                bot: action.bot)
            return EvalActionOutcome(status: "ok", detail: context.policy.defaultDecision, replies: [])

        case "restart_worker":
            let mode = action.mode ?? "planned_restart"
            let before = await context.host.diagnostics().workerHelloCount
            try await pumped(timeout: 300) {
                try await context.host.plannedRestart(reason: "bot-eval restart \(mode)")
                // plannedRestart returns before the composition has necessarily
                // observed `.restarted` and rebound every unit. Wait for a new
                // Worker HELLO *and* a ready composition; otherwise a turn can
                // race the recovery's attachTransport and be cancelled.
                try await harnessWait(1.0)
                let deadline = Date().addingTimeInterval(180)
                var sawRecovering = false
                while true {
                    let diagnostics = await context.host.diagnostics()
                    let state = context.composition.state
                    if state == .recovering { sawRecovering = true }
                    if diagnostics.workerHelloCount > before,
                       state == .ready,
                       sawRecovering || Date().timeIntervalSince1970 > 0 {
                        if sawRecovering { break }
                    }
                    if Date() > deadline {
                        throw EvalRunnerError.timeout(
                            "composition did not rebind after restart "
                            + "(hello \(diagnostics.workerHelloCount) -> \(before), "
                            + "state \(state))")
                    }
                    try await harnessWait(0.1)
                }
                try await harnessWait(2.0)
            }
            return EvalActionOutcome(
                status: mode == "worker_kill" ? "degraded" : "ok",
                detail: mode == "worker_kill"
                    ? "worker_kill is approximated by the production plannedRestart path"
                    : "plannedRestart completed",
                replies: [])

        case "advance_clock":
            guard let seconds = action.seconds, seconds > 0 else {
                throw EvalRunnerError.invalid("advance_clock needs positive seconds")
            }
            let botID = try context.botID(for: action.bot)
            let unit = try await context.unit(for: botID)
            let before = try await BotProductionEventReader.all(domain: context.store)
            let priorEventIDs = Set(before.map(\.eventId))
            context.schedulerClock.advance(seconds: Int64(seconds))
            let due = try await unit.scheduler.queuedRoutines()
            let dueIDs = Set(due.map(\.id))
            guard !dueIDs.isEmpty else {
                return EvalActionOutcome(
                    status: "ok",
                    detail: "advanced \(seconds)s; no routine was due",
                    replies: [])
            }
            let deadline = Date().addingTimeInterval(context.actionTimeout(action))
            var finished: Set<String> = []
            while Date() < deadline {
                let events = try await BotProductionEventReader.all(domain: context.store)
                finished = Set(events.compactMap { event -> String? in
                    guard event.type == "routine.run_finished",
                          !priorEventIDs.contains(event.eventId),
                          let routineID = event.data["routineId"]?.stringValue,
                          dueIDs.contains(routineID) else { return nil }
                    return routineID
                })
                if finished.count >= dueIDs.count { break }
                try await harnessWait(0.2)
            }
            guard finished.count >= dueIDs.count else {
                throw EvalRunnerError.timeout(
                    "advance_clock: due routine(s) \(dueIDs.sorted()) did not finish; "
                    + "finished \(finished.sorted())")
            }
            return EvalActionOutcome(
                status: "ok",
                detail: "advanced \(seconds)s; finished \(finished.count) routine(s)",
                replies: [])

        default:
            throw EvalRunnerError.invalid("unknown action \(action.type)")
        }
    }

    private func executeUI(_ action: EvalAction, context: EvalRunContext,
                           repeat index: Int) async throws -> EvalActionOutcome {
        let botID = try context.botID(for: action.bot)
        let unit = try await context.unit(for: botID)
        switch action.kind ?? "" {
        case "card_answer":
            let events = try await BotProductionEventReader.all(domain: context.store)
            let card = try latestCard(events: events, botID: botID)
            let optionIndex = action.option ?? 0
            guard card.options.indices.contains(optionIndex) else {
                throw EvalRunnerError.invalid("card \(card.id) has no option \(optionIndex)")
            }
            let option = card.options[optionIndex]
            let turn = context.nextTurn(botID)
            let cursor = try await context.lastCommitSeq()
            context.installMock(action.mock ?? context.scenario.mock)
            let watcher = context.startApprovalWatcher()
            let result: BotActionResult
            do {
                result = try await pumped(timeout: context.actionTimeout(action)) {
                    try await unit.rows.perform(BotUserAction(
                        nonce: context.nonce("card", action: action, repeat: index),
                        botID: botID, kind: .cardAnswer,
                        cardID: card.id, optionID: option.id))
                }
            } catch {
                watcher.cancel()
                throw error
            }
            watcher.cancel()
            let replies = try await context.replies(
                after: cursor, botID: botID, turn: turn,
                action: action, repeat: index)
            if case .rejected(let reason) = result {
                throw EvalRunnerError.action("card answer rejected: \(reason)")
            }
            return EvalActionOutcome(status: "ok", detail: "answered \(card.id)", replies: replies)

        case "card_dismiss":
            let events = try await BotProductionEventReader.all(domain: context.store)
            let card = try latestCard(events: events, botID: botID)
            let result = try await pumped(timeout: context.actionTimeout(action)) {
                try await unit.rows.perform(BotUserAction(
                    nonce: context.nonce("dismiss", action: action, repeat: index),
                    botID: botID, kind: .cardDismiss, cardID: card.id))
            }
            return EvalActionOutcome(
                status: result.status == "accepted" ? "ok" : "error",
                detail: "dismissed \(card.id): \(result.status)", replies: [])

        case "approval":
            let pending = try pendingApproval(
                events: try await BotProductionEventReader.all(domain: context.store),
                botID: botID, requestedID: action.approvalID)
            let decision = Self.decision(from: action.decision ?? "deny")
            let result = try await pumped(timeout: context.actionTimeout(action)) {
                try await unit.rows.perform(BotUserAction(
                    nonce: context.nonce("approval", action: action, repeat: index),
                    botID: botID, kind: .approval,
                    approvalID: pending.id, decision: decision, digest: pending.digest))
            }
            return EvalActionOutcome(
                status: result.status == "accepted" ? "ok" : "error",
                detail: "approval \(pending.id): \(result.status)", replies: [])

        case "erase_memory":
            try await unit.info.eraseMemories()
            return EvalActionOutcome(status: "ok", detail: "erased agent scope", replies: [])

        case "erase_shared_memory":
            try await unit.info.eraseSharedMemories()
            return EvalActionOutcome(status: "ok", detail: "erased user scope", replies: [])

        case "forget_memory":
            let documents = try await unit.info.load().memories
            let match: BotProductionMemoryDocument?
            if let id = action.factID {
                match = documents.first { $0.document.path == id }
            } else {
                match = documents.first {
                    $0.document.content.contains(action.factContains ?? "")
                }
            }
            guard let document = match else {
                throw EvalRunnerError.invalid(
                    "no memory document matched \(action.factID ?? action.factContains ?? "")")
            }
            try await unit.info.forget(
                path: document.document.path,
                expectedVersion: document.document.version)
            return EvalActionOutcome(
                status: "ok", detail: "forgot \(document.document.path)", replies: [])

        case "stop_task":
            let events = try await BotProductionEventReader.all(domain: context.store)
            let taskID = action.taskID ?? events.last(where: {
                $0.type == "task.created" && $0.principal.botId == botID
            })?.data["task_id"]?.stringValue
            guard let taskID, !taskID.isEmpty else {
                throw EvalRunnerError.invalid("no task to stop")
            }
            let result = try await pumped(timeout: context.actionTimeout(action)) {
                try await unit.rows.perform(BotUserAction(
                    nonce: context.nonce("stop", action: action, repeat: index),
                    botID: botID, kind: .stopTask, threadID: taskID))
            }
            return EvalActionOutcome(
                status: result.status == "accepted" ? "ok" : "error",
                detail: "stop \(taskID): \(result.status)", replies: [])

        default:
            throw EvalRunnerError.invalid("unknown ui_action kind \(action.kind ?? "nil")")
        }
    }

    // MARK: - Snapshot helpers

    private func collectToolCalls(events: [BotEvent],
                                  context: EvalRunContext) async throws -> [EvalToolCallRecord] {
        var calls: [EvalToolCallRecord] = []
        for botID in context.knownBotIDs {
            guard let unit = context.composition.unit(for: botID),
                  let sessionID = await unit.remote.mainSessionIdentifier() else { continue }
            guard let url = latestSessionLog(
                workspaceRoot: context.workspaceRoot, sessionID: sessionID) else { continue }
            let data = try Data(contentsOf: url)
            // Use the production session-log decoder, the same one the App's
            // `rebuild()` runs, so this evidence cannot silently diverge from
            // the UI. Damaged records are skipped by its diagnostics rather
            // than poisoning the whole tool-call snapshot.
            let parsed = BotDSHSessionEvent.parseJSONL(data)
            for event in parsed.events where event.type == "tool/call" {
                calls.append(EvalToolCallRecord(
                    botID: botID,
                    name: event.data["name"]?.stringValue ?? "",
                    arguments: event.data["arguments"]?.stringValue ?? ""))
            }
        }
        return calls
    }

    private func collectMemories(context: EvalRunContext) async -> [String: [BotMemoryDocument]] {
        var result: [String: [BotMemoryDocument]] = [:]
        for botID in context.knownBotIDs {
            guard let unit = context.composition.unit(for: botID) else { continue }
            if let snapshot = try? await unit.info.load() {
                result[botID] = snapshot.memories.map(\.document)
            }
        }
        return result
    }

    private func workspacePaths(context: EvalRunContext) -> [String: URL] {
        let materialized = EvalWorkspaceSeed.materializedWorkspaces(
            workspaceRoot: context.workspaceRoot)
        var result: [String: URL] = [:]
        for botID in context.knownBotIDs {
            let relative = BotWorkspaceLayout.botRoot(botId: botID)
                .dropFirst("/dsh/workspace/".count)
            result[botID] = materialized.appendingPathComponent(String(relative), isDirectory: true)
        }
        return result
    }

    private func latestSessionLog(workspaceRoot: URL, sessionID: String) -> URL? {
        // DSH nests the session under a project directory (the Bot workspace
        // hash), e.g. sessions/--dsh-workspace-.dshbot-agents-main--/gb-main/
        // session.v4.jsonl. Search the tree and select the file whose parent
        // directory is this Bot's session id.
        let root = workspaceRoot
            .appendingPathComponent("materialized/home/sessions", isDirectory: true)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("session.v"),
                  url.pathExtension == "jsonl",
                  url.deletingLastPathComponent().lastPathComponent == sessionID,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.1 > $1.1 }.first?.0
    }

    private struct CardChoice {
        var id: String
        var value: String
    }

    private func latestCard(events: [BotEvent], botID: String) throws -> (id: String, options: [CardChoice]) {
        guard let event = events.last(where: {
            $0.type == "card.presented" && $0.principal.botId == botID
        }) else {
            throw EvalRunnerError.invalid("no card.presented event for \(botID)")
        }
        guard case .object(let data) = event.data else {
            throw EvalRunnerError.invalid("card event data is not an object")
        }
        let card = data["card"]?.objectValue ?? data
        let id = data["id"]?.stringValue
            ?? card["id"]?.stringValue
            ?? "e-ui-\(event.eventId)"
        let raw = data["options"]?.arrayValue
            ?? card["options"]?.arrayValue
            ?? data["steps"]?.arrayValue
            ?? card["steps"]?.arrayValue
            ?? []
        let options = raw.compactMap { value -> CardChoice? in
            guard let object = value.objectValue else { return nil }
            let label = object["label"]?.stringValue ?? object["id"]?.stringValue ?? ""
            let id = object["id"]?.stringValue ?? label
            let value = object["value"]?.stringValue ?? label
            guard !id.isEmpty, !value.isEmpty else { return nil }
            return CardChoice(id: id, value: value)
        }
        guard !options.isEmpty else {
            throw EvalRunnerError.invalid("card \(id) has no choices")
        }
        return (id, options)
    }

    private func pendingApproval(events: [BotEvent], botID: String,
                                 requestedID: String?) throws -> (id: String, digest: String) {
        let decided = Set(events.filter { $0.type == "approval.decided" }.compactMap {
            $0.data["approvalID"]?.stringValue
        })
        let requested = events.filter {
            $0.type == "approval.requested" && $0.principal.botId == botID
                && !decided.contains($0.data["approvalID"]?.stringValue ?? "")
        }
        let event: BotEvent?
        if let requestedID {
            event = requested.first { $0.data["approvalID"]?.stringValue == requestedID }
        } else {
            event = requested.last
        }
        guard let event, let id = event.data["approvalID"]?.stringValue,
              let digest = event.data["digest"]?.stringValue else {
            throw EvalRunnerError.invalid("no pending approval for \(requestedID ?? botID)")
        }
        return (id, digest)
    }

    private func writeBodies(_ mock: MockModelUpstream, scenario: EvalScenario,
                             repeat index: Int, results: URL,
                             redactor: (String) -> String) {
        let directory = results
            .appendingPathComponent(scenario.id, isDirectory: true)
            .appendingPathComponent("bodies", isDirectory: true)
            .appendingPathComponent("repeat-\(index)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (offset, request) in mock.requests.enumerated() {
            let body = redactor(String(decoding: request.body, as: UTF8.self))
            try? Data(body.utf8).write(
                to: directory.appendingPathComponent("\(offset + 1)-request.json"))
        }
        for (offset, body) in mock.responseBodies.enumerated() {
            let text = redactor(String(decoding: body, as: UTF8.self))
            try? Data(text.utf8).write(
                to: directory.appendingPathComponent("\(offset + 1)-response.sse"))
        }
    }

    private func copyWorkspace(workspaceRoot: URL, to workspaces: URL, index: Int) {
        let source = EvalWorkspaceSeed.materializedWorkspaces(workspaceRoot: workspaceRoot)
        let destination = workspaces.appendingPathComponent("repeat-\(index)", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - Report

    private func buildReport(scenario: EvalScenario, plan: EvalPlan,
                             started: Date, finished: Date,
                             repeats: [EvalRepeatRecord], skipReason: String?,
                             archiveError: String?, keepBodies: Bool,
                             redactor: (String) -> String) -> [String: Any] {
        var report: [String: Any] = [
            "schema_version": 1,
            "id": scenario.id,
            "title": scenario.title,
            "upstream": plan.upstream,
            "expect": scenario.expect,
            "selftest": plan.selftest,
            "started_at": EvalJSON.date(started),
            "finished_at": EvalJSON.date(finished),
            "repeat": plan.repeatCount,
            "budget": [
                "max_minutes": scenario.budget.maxMinutes,
                "max_model_requests": scenario.budget.maxModelRequests,
            ],
            "keep_bodies": keepBodies,
            "model": [
                "name": plan.upstream == "mock" ? "mock" : "real",
                "real": plan.upstream == "real",
            ],
        ]
        if let modelHost = ProcessInfo.processInfo.environment["PDSH_MODEL_BASE_URL"] {
            report["model"] = [
                "name": ProcessInfo.processInfo.environment["PDSH_MODEL_NAME"] ?? "real",
                "base_url_host": URL(string: modelHost)?.host ?? "<invalid-url>",
                "real": true,
            ]
        }
        if let skipReason {
            report["status"] = "SKIP"
            report["run_status"] = "NOT_RUN"
            report["expectation_met"] = false
            report["reason"] = redactor(skipReason)
            report["repeats"] = []
            report["usage"] = Self.zeroUsage()
            if let archiveError { report["evidence_error"] = archiveError }
            return report
        }
        let runStatus: String
        if repeats.contains(where: { $0.status == "ERROR" }) {
            runStatus = "ERROR"
        } else if repeats.contains(where: { $0.status == "NOT_RUN" }) {
            runStatus = "NOT_RUN"
        } else if repeats.allSatisfy({ $0.status == "PASS" }) {
            runStatus = "PASS"
        } else {
            runStatus = "FAIL"
        }
        let expectationMet: Bool
        if scenario.expect == "pass" {
            expectationMet = runStatus == "PASS"
        } else {
            expectationMet = runStatus == "FAIL" && repeats.allSatisfy { record in
                record.assertions.contains { !$0.ok }
            }
        }
        let status: String
        if expectationMet {
            status = "PASS"
        } else if runStatus == "PASS" || runStatus == "FAIL" {
            status = "FAIL"
        } else {
            status = runStatus
        }
        report["run_status"] = runStatus
        report["status"] = status
        report["expectation_met"] = expectationMet
        if let archiveError { report["evidence_error"] = archiveError }
        var repeatObjects: [[String: Any]] = []
        var totalRequests = 0
        var totalBytesIn = 0
        var totalBytesOut = 0
        var totalWall = 0.0
        for record in repeats {
            totalRequests += (record.usage["model_requests"] as? Int) ?? 0
            totalBytesIn += (record.usage["upstream_bytes_in"] as? Int) ?? 0
            totalBytesOut += (record.usage["upstream_bytes_out"] as? Int) ?? 0
            totalWall += record.wallSeconds
            var object: [String: Any] = [
                "index": record.index,
                "status": record.status,
                "actions": record.actions,
                "assertions": record.assertions.map { self.assertionObject($0, redact: redactor) },
                "usage": record.usage,
                "auto_decisions": record.autoDecisions,
                "approval_requests": record.approvalRequests,
                "wall_s": record.wallSeconds,
            ]
            if let error = record.error { object["error"] = error }
            if let visibility = record.pageVisibility {
                object["page_visibility"] = visibility
            }
            repeatObjects.append(object)
        }
        report["repeats"] = repeatObjects
        report["usage"] = [
            "model_requests": totalRequests,
            "upstream_bytes_in": totalBytesIn,
            "upstream_bytes_out": totalBytesOut,
            "wall_s": totalWall,
        ]
        report["auto_decisions"] = repeats.flatMap(\.autoDecisions)
        return report
    }

    private func assertionObject(_ result: EvalAssertionResult,
                                 redact: (String) -> String) -> [String: Any] {
        var object: [String: Any] = [
            "type": result.type,
            "ok": result.ok,
            "expect_ok": result.expectedOK,
            "bot": result.bot ?? "main",
            "detail": redact(result.detail),
        ]
        if let turn = result.turn { object["turn"] = turn }
        return object
    }

    private func actionRecord(action: EvalAction, outcome: EvalActionOutcome,
                              start: Date) -> [String: Any] {
        var record: [String: Any] = [
            "index": action.index ?? 0,
            "type": action.type,
            "bot": action.bot ?? "main",
            "status": outcome.status,
            "wall_ms": Int(Date().timeIntervalSince(start) * 1000),
        ]
        if let detail = outcome.detail { record["detail"] = EvalRedaction.redact(detail, secrets: []) }
        record["replies"] = outcome.replies.map { reply -> [String: Any] in
            ["bot": reply.botID, "turn": reply.turnNumber ?? 0, "chars": reply.text.count]
        }
        return record
    }

    private func replyTranscript(_ reply: EvalReply, action: EvalAction,
                                 repeat index: Int, keepBodies: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "type": "assistant_message",
            "repeat": index,
            "action": action.index ?? 0,
            "bot": reply.botID,
            "turn": reply.turnNumber ?? 0,
            "chars": reply.text.count,
            "sha256": EvalJSON.sha256(Data(reply.text.utf8)),
        ]
        if keepBodies { object["text"] = reply.text }
        return object
    }

    private func usageObject(provider: EvalModelCredentialProvider,
                             mock: MockModelUpstream?, wall: Double,
                             budget: EvalBudget) -> [String: Any] {
        [
            "model_requests": provider.modelRequests,
            "upstream_requests": mock?.requestCount ?? 0,
            "upstream_bytes_in": mock?.requestBytes ?? 0,
            "upstream_bytes_out": mock?.responseBytes ?? 0,
            "wall_s": wall,
            "max_minutes": budget.maxMinutes,
            "max_model_requests": budget.maxModelRequests,
        ]
    }

    static func zeroUsage() -> [String: Any] {
        [
            "model_requests": 0,
            "upstream_bytes_in": 0,
            "upstream_bytes_out": 0,
            "wall_s": 0.0,
        ]
    }

    // MARK: - Host plumbing

    private static func bundle() throws -> PhoneDSHBundleLocation {
        guard let www = ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_WWW"],
              let image = ProcessInfo.processInfo.environment["PDSH_BOT_EVAL_IMAGE"] else {
            throw EvalRunnerError.invalid("PDSH_BOT_EVAL_WWW/PDSH_BOT_EVAL_IMAGE are not set")
        }
        let directory = URL(fileURLWithPath: www, isDirectory: true)
        let imageURL = URL(fileURLWithPath: image)
        let lazy = directory.appendingPathComponent("lazy", isDirectory: true)
        try? FileManager.default.createDirectory(at: lazy, withIntermediateDirectories: true)
        let bundle = PhoneDSHBundleLocation(
            staticDirectory: directory, imageArchive: imageURL, lazyDirectory: lazy)
        guard bundle.exists() else {
            throw EvalRunnerError.invalid("Worker bundle is incomplete at \(www)")
        }
        return bundle
    }

    private static func keepBodiesEnabled() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PDSH_SCENARIO_KEEP_BODIES"] == "1"
            || environment["PDSH_BOT_EVAL_KEEP_BODIES"] == "1"
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    static func decision(from raw: String) -> BotApprovalDecision {
        switch raw {
        case "allow_once": return .allowOnce
        case "always": return .always
        default: return .deny
        }
    }
}

@MainActor
private final class EvalEngineHolder {
    var engine: WebEngine?
}

@MainActor
private final class PumpedOperationState<T> {
    var finished = false
    var result: Result<T, Error>?
}

@MainActor
func pumped<T>(timeout: TimeInterval,
               _ body: @escaping @MainActor () async throws -> T) async throws -> T {
    let state = PumpedOperationState<T>()
    let task = Task { @MainActor in
        do {
            state.result = .success(try await body())
        } catch {
            state.result = .failure(error)
        }
        state.finished = true
    }
    let deadline = Date().addingTimeInterval(max(1, timeout))
    while !state.finished {
        if Date() >= deadline {
            task.cancel()
            throw EvalRunnerError.timeout("operation exceeded \(Int(timeout))s")
        }
        do {
            try await harnessWait(0.05)
        } catch {
            task.cancel()
            throw error
        }
    }
    guard let result = state.result else {
        throw EvalRunnerError.invalid("operation finished without a result")
    }
    switch result {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}

struct EvalActionOutcome {
    var status: String
    var detail: String?
    var replies: [EvalReply]
}

struct EvalRepeatRecord {
    var index: Int
    var status: String
    var error: String?
    var actions: [[String: Any]]
    var assertions: [EvalAssertionResult]
    var usage: [String: Any]
    var events: [BotEvent]
    var replies: [EvalReply]
    var toolCalls: [EvalToolCallRecord]
    var memories: [String: [BotMemoryDocument]]
    var workspaces: [String: URL]
    var autoDecisions: [String]
    var approvalRequests: [String: Int]
    var wallSeconds: Double
    var pageVisibility: [String: Any]?
}
