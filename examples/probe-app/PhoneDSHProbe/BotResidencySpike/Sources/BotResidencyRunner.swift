// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import Foundation
import SwiftUI
import UIKit
import ProbeKit
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHAgentCore
import PhoneDSHHarness

@MainActor
final class BotResidencyRunner: ObservableObject {
    let anchor = VisibleEngineAnchor()
    @Published private(set) var statusText = "Not started"
    @Published private(set) var phase = "launching"
    @Published private(set) var deliveredCount = 0
    @Published private(set) var injectedCount = 0
    @Published private(set) var terminationCount = 0

    private let spikeConfiguration: BotResidencyConfiguration?
    private let keepAlive = SilentAudioKeepAlive()
    private let mock = MockModelUpstream()
    private var store: BotResidencyEvidenceStore?
    private var host: PhoneDSHHost?
    private var harness: (any AgentHarness)?
    private var sessionID: String?
    private var plan: BotResidencyPlan?
    private var events: [BotResidencyEventRecord] = []
    private var recoveries: [BotResidencyRecoveryRecord] = []
    private var activeEventID: String?
    private var currentScene: ScenePhase = .active
    private var runStartedAt: Date?
    private var durationReachedAt: Date?
    private var lockEndedAt: Date?
    private var lastRecoveryCompletedAt = Date.distantPast
    private var lastDurableSeq: UInt64?
    private var helloCount: UInt64 = 0
    private var restartCount = 0
    private var p6DeferredCount = 0
    private var p6ViolationCount = 0
    private var helloFailureCount = 0
    private var p15FailureCount = 0
    private var protectedDataLockObserved = false
    private var protectedDataUnlockObserved = false
    private var ready = false
    private var started = false
    private var finished = false
    private var sendInFlight = false
    private var retryPending: Set<String> = []
    private var hostEventTask: Task<Void, Never>?
    private var harnessEventTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var lockUnavailableObserver: NSObjectProtocol?
    private var lockAvailableObserver: NSObjectProtocol?
    private var lastStateWrite = Date.distantPast
    private var lastDiagnosticsRead = Date.distantPast

    init() {
        do {
            spikeConfiguration = try BotResidencyConfiguration.parse()
        } catch {
            spikeConfiguration = nil
            statusText = String(describing: error)
            phase = "aborted"
        }
        if let spikeConfiguration {
            do {
                store = try BotResidencyEvidenceStore(runID: spikeConfiguration.runID)
            } catch {
                statusText = "evidence directory failed: \(error)"
                phase = "aborted"
            }
        }
    }

    func startIfNeeded() async {
        guard !started, !finished else { return }
        started = true
        installLockObservers()
        keepAlive.onEvent = { [weak self] text in
            self?.log("audio", detail: text)
        }
        guard let spikeConfiguration, let store else {
            finished = true
            return
        }
        log("app-launch", detail: "run=\(spikeConfiguration.runID) seed=\(spikeConfiguration.seed)")
        do {
            try await waitForAnchor()
            try FileManager.default.createDirectory(at: store.workspace,
                                                    withIntermediateDirectories: true)
            mock.script = .generic(
                command: "printf bot-residency > bot-residency.txt && cat bot-residency.txt",
                toolText: "BOT_RESIDENCY_TOOL",
                finalText: "BOT_RESIDENCY_DELIVERED")
            let mockURL = try mock.start()
            guard let bundle = WorkerBundleLocator.bundle() else {
                throw BotResidencyRunError.failed(WorkerBundleLocator.missingReason())
            }
            let hostConfiguration = PhoneDSHConfiguration(
                workspaceRoot: store.workspace,
                token: "",
                origin: URL(string: "http://127.0.0.1:1")!,
                bundle: bundle,
                allowedModelHosts: ["http://127.0.0.1:\(mock.port)"],
                credentialProvider: StaticCredentialProvider([
                    CredentialScope(service: "127.0.0.1"):
                        Credential(kind: .apiKey(header: "x-api-key"),
                                   value: "bot-residency-host-fixture"),
                ]),
                drainDeadline: 2,
                helloTimeout: 60)
            var engineConfiguration = hostConfiguration.engine
            engineConfiguration.bootTimeout = 60
            engineConfiguration.environment = [
                "DEEPSEEK_BASE_URL": mockURL.absoluteString,
                "DEEPSEEK_API_KEY": "bot-residency-worker-placeholder",
                "DSH_TELEMETRY_DISABLED": "1",
            ]
            var resolvedConfiguration = hostConfiguration
            resolvedConfiguration.engine = engineConfiguration
            let newHost = PhoneDSHHost(configuration: resolvedConfiguration,
                                       engineFactory: { [anchor] configuration in
                await anchor.makeEngine(configuration)
            })
            host = newHost
            observeHost(newHost)
            phase = "booting"
            statusText = "Booting the real Worker and scripted model loop"
            updateState(force: true)
            try await newHost.start()
            let openedHarness = try await newHost.harness()
            harness = openedHarness
            let session = try await openedHarness.openSession(
                HarnessSessionRequest(workspace: "/dsh/workspace"))
            sessionID = session.id
            let diagnostics = await newHost.diagnostics()
            helloCount = diagnostics.workerHelloCount
            lastRecoveryCompletedAt = Date()
            startHarnessPump(openedHarness, sessionID: session.id)
            try keepAlive.start()
            keepAlive.hideNowPlaying()
            ready = true
            phase = "waitingForLock"
            statusText = "Ready. Lock the device now; do not press Home."
            log("ready", detail: "session=\(session.id) mockRequests=\(mock.requestCount)")
            updateState(force: true)
            if currentScene == .background {
                beginRun()
            }
            tickerTask = Task { @MainActor [weak self] in
                while let self, !self.finished, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    await self.tick()
                }
            }
        } catch {
            await finish(status: "ABORTED", reason: "boot failed: \(error)")
        }
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) async {
        currentScene = newPhase
        log("scene-phase", detail: String(describing: newPhase))
        switch newPhase {
        case .background:
            if ready, runStartedAt == nil {
                beginRun()
            }
        case .active:
            if let started = runStartedAt, lockEndedAt == nil {
                lockEndedAt = Date()
                log("lock-ended", seconds: Date().timeIntervalSince(started))
                if durationReachedAt == nil {
                    await finish(status: "ABORTED",
                                 reason: "the device became active before the requested locked duration")
                    return
                }
                phase = "recovering"
                statusText = "Foreground again; waiting for P6 recovery and queued delivery"
            }
        default:
            break
        }
        updateState(force: true)
    }

    private func waitForAnchor() async throws {
        for _ in 0..<100 {
            if anchor.isInWindow { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BotResidencyRunError.failed("the one-point WebView anchor is not attached")
    }

    private func beginRun() {
        guard let spikeConfiguration, runStartedAt == nil else { return }
        let now = Date()
        runStartedAt = now
        let newPlan = BotResidencySchedule.make(configuration: spikeConfiguration, startedAt: now)
        plan = newPlan
        events = newPlan.events.enumerated().map { index, action in
            BotResidencyEventRecord(id: action.id, index: index,
                                    requestID: "\(spikeConfiguration.runID)-\(action.id)",
                                    scheduledOffsetSeconds: action.offsetSeconds)
        }
        phase = "locked"
        statusText = "Locked run in progress; keep the device locked"
        store?.writePlan(newPlan)
        log("run-started", detail: "duration=\(spikeConfiguration.durationSeconds) events=\(spikeConfiguration.eventCount) kills=\(spikeConfiguration.killCount)")
        updateState(force: true)
    }

    private func tick() async {
        guard ready, !finished, let spikeConfiguration, let started = runStartedAt else {
            updateState()
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(started)
        for index in events.indices where events[index].injectedAt == nil {
            if elapsed >= events[index].scheduledOffsetSeconds {
                events[index].injectedAt = BotResidencyTime.string(now)
                events[index].acceptedAt = nil
                log("event-injected", id: events[index].id,
                    seconds: elapsed, detail: events[index].requestID)
            }
        }
        if durationReachedAt == nil, elapsed >= Double(spikeConfiguration.durationSeconds) {
            durationReachedAt = now
            phase = currentScene == .active ? "recovering" : "awaitingUnlock"
            statusText = currentScene == .active
                ? "Locked window complete; settling deliveries"
                : "Locked window complete. Unlock once; recovery is now allowed."
            log("duration-reached", seconds: elapsed)
            updateState(force: true)
        }

        var hostRunning = false
        if now.timeIntervalSince(lastDiagnosticsRead) >= 1, let host {
            lastDiagnosticsRead = now
            let diagnostics = await host.diagnostics()
            hostRunning = diagnostics.state == .running
            helloCount = max(helloCount, diagnostics.workerHelloCount)
            terminationCount = Int(max(UInt64(terminationCount), diagnostics.webContentTerminations))
            for index in recoveries.indices {
                guard recoveries[index].recoveredAt == nil,
                      diagnostics.workerHelloCount > recoveries[index].helloBefore,
                      diagnostics.state == .running else { continue }
                recoveries[index].recoveredAt = BotResidencyTime.string(now)
                recoveries[index].helloAfter = diagnostics.workerHelloCount
                let terminatedAt = BotResidencyRunner.date(recoveries[index].terminatedAt) ?? now
                recoveries[index].recoverySeconds = now.timeIntervalSince(terminatedAt)
                recoveries[index].recoveryWorkSeconds = now.timeIntervalSince(
                    max(terminatedAt, lockEndedAt ?? terminatedAt))
                lastRecoveryCompletedAt = now
                if !recoveries[index].wasForeground {
                    if currentScene == .active {
                        log("recovery-complete", id: "recovery-\(recoveries[index].index)",
                            count: Int(diagnostics.workerHelloCount),
                            seconds: recoveries[index].recoverySeconds)
                    } else {
                        recoveries[index].p6Violation = true
                        p6ViolationCount += 1
                        log("p6-background-violation", id: "recovery-\(recoveries[index].index)",
                            detail: "Worker HELLO advanced while the app was not active")
                    }
                } else {
                    log("recovery-complete", id: "recovery-\(recoveries[index].index)",
                        count: Int(diagnostics.workerHelloCount),
                        seconds: recoveries[index].recoverySeconds)
                }
                if let activeEventID, let eventIndex = events.firstIndex(where: { $0.id == activeEventID }),
                   events[eventIndex].deliveredAt == nil {
                    events[eventIndex].acceptedAt = nil
                    retryPending.insert(activeEventID)
                }
            }
        } else if let host {
            hostRunning = await host.state == .running
        }

        await pumpNextEvent(hostRunning: hostRunning)
        injectedCount = events.filter { $0.injectedAt != nil }.count
        deliveredCount = events.filter { $0.deliveredAt != nil }.count
        let pendingRecovery = recoveries.contains { $0.recoveredAt == nil }
        if durationReachedAt != nil, deliveredCount == events.count,
           activeEventID == nil, !pendingRecovery, hostRunning {
            await finish(status: "COMPLETE", reason: nil)
            return
        }
        updateState()
    }

    private func pumpNextEvent(hostRunning: Bool) async {
        guard hostRunning, !sendInFlight, let harness, let sessionID else { return }
        if activeEventID == nil {
            activeEventID = events.first {
                $0.injectedAt != nil && $0.deliveredAt == nil
            }?.id
        }
        guard let activeEventID,
              let index = events.firstIndex(where: { $0.id == activeEventID }),
              events[index].acceptedAt == nil else { return }
        sendInFlight = true
        defer { sendInFlight = false }
        let event = events[index]
        let prompt = "BOT_RESIDENCY_EVENT:\(event.id)"
        retryPending.remove(activeEventID)
        do {
            try await harness.send(.prompt(text: prompt, attachments: [],
                                           requestID: event.requestID), to: sessionID)
            guard let current = events.firstIndex(where: { $0.id == activeEventID }),
                  events[current].deliveredAt == nil else { return }
            events[current].promptAttempts += 1
            guard !retryPending.contains(activeEventID) else {
                log("prompt-response-superseded", id: activeEventID)
                return
            }
            events[current].acceptedAt = BotResidencyTime.string()
            log("prompt-accepted", id: activeEventID, count: events[current].promptAttempts)
        } catch {
            guard let current = events.firstIndex(where: { $0.id == activeEventID }) else { return }
            retryPending.insert(activeEventID)
            events[current].promptAttempts += 1
            events[current].acceptedAt = nil
            events[current].lastError = String(describing: error)
            log("prompt-send-failed", id: activeEventID,
                count: events[current].promptAttempts, detail: events[current].lastError)
        }
    }

    private func startHarnessPump(_ harness: any AgentHarness, sessionID: String) {
        harnessEventTask?.cancel()
        harnessEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.finished && !Task.isCancelled {
                do {
                    for try await event in harness.events(sessionID: sessionID,
                                                          after: self.lastDurableSeq) {
                        self.handleHarnessEvent(event)
                    }
                    return
                } catch {
                    self.log("harness-stream-reconnect", detail: String(describing: error))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func handleHarnessEvent(_ event: HarnessEvent) {
        if let seq = event.seq {
            if let lastDurableSeq, seq <= lastDurableSeq { return }
            lastDurableSeq = seq
        }
        switch event.kind {
        case .userMessage(let text, _):
            guard text.hasPrefix("BOT_RESIDENCY_EVENT:") else { return }
            let id = String(text.dropFirst("BOT_RESIDENCY_EVENT:".count))
            guard let index = events.firstIndex(where: { $0.id == id }),
                  let seq = event.seq else { return }
            if !events[index].userSequenceNumbers.contains(seq) {
                events[index].userSequenceNumbers.append(seq)
            }
            log("event-user-observed", id: id, seq: seq,
                count: events[index].userSequenceNumbers.count)
        case .turnStarted(let turnID):
            guard let activeEventID,
                  let index = events.firstIndex(where: { $0.id == activeEventID }) else { return }
            if !events[index].turnIDs.contains(turnID) {
                events[index].turnIDs.append(turnID)
            }
            log("turn-started", id: activeEventID, turnID: turnID, seq: event.seq)
        case .toolResult(_, let isError, _):
            guard let activeEventID,
                  let index = events.firstIndex(where: { $0.id == activeEventID }) else { return }
            if isError {
                events[index].failedToolResults += 1
            } else {
                events[index].successfulToolResults += 1
            }
            log("event-tool-result", id: activeEventID, seq: event.seq,
                count: isError ? events[index].failedToolResults : events[index].successfulToolResults,
                detail: isError ? "error" : "success")
        case .assistantMessage(let text):
            guard text.contains("BOT_RESIDENCY_DELIVERED"), let activeEventID,
                  let index = events.firstIndex(where: { $0.id == activeEventID }) else { return }
            events[index].finalAssistantMessages += 1
            log("event-final-assistant", id: activeEventID, seq: event.seq,
                count: events[index].finalAssistantMessages)
        case .turnEnded(let turnID, let reason):
            guard let activeEventID,
                  let index = events.firstIndex(where: { $0.id == activeEventID }) else { return }
            events[index].turnEndCount += 1
            log("turn-ended", id: activeEventID, turnID: turnID, seq: event.seq,
                detail: String(describing: reason))
            switch reason {
            case .completed:
                let proof = events[index]
                guard proof.userSequenceNumbers.count == 1,
                      proof.successfulToolResults == 1,
                      proof.finalAssistantMessages == 1 else {
                    Task { @MainActor [weak self] in
                        await self?.finish(status: "ABORTED",
                            reason: "incomplete or duplicate delivery proof for \(activeEventID): \(proof)")
                    }
                    return
                }
                let delivered = Date()
                let injected = BotResidencyRunner.date(proof.injectedAt ?? "") ?? delivered
                let basis = max(injected, lastRecoveryCompletedAt)
                events[index].deliveredAt = BotResidencyTime.string(delivered)
                events[index].deliveryLatencySeconds = delivered.timeIntervalSince(basis)
                events[index].acceptedAt = nil
                log("event-delivered", id: activeEventID, turnID: turnID, seq: event.seq,
                    seconds: events[index].deliveryLatencySeconds)
                self.activeEventID = nil
            case .cancelled, .failed, .budgetExhausted:
                events[index].acceptedAt = nil
                events[index].lastError = String(describing: reason)
                retryPending.insert(activeEventID)
            }
        default:
            break
        }
    }

    private func observeHost(_ host: PhoneDSHHost) {
        hostEventTask?.cancel()
        hostEventTask = Task { @MainActor [weak self] in
            for await event in host.eventStream() {
                guard let self else { return }
                self.handleHostEvent(event)
            }
        }
    }

    private func handleHostEvent(_ event: PhoneDSHEvent) {
        switch event {
        case .stateChanged(let from, let to):
            log("host-state", detail: "\(from.rawValue)->\(to.rawValue)")
        case .hostTransition(let record):
            log("controller", detail: "\(record.from.rawValue)->\(record.to.rawValue) \(record.signal)")
        case .webContentTerminated(let count):
            terminationCount = max(terminationCount, Int(count))
            guard runStartedAt != nil else {
                log("webcontent-terminated-before-run", count: Int(count))
                return
            }
            let now = Date()
            let foreground = currentScene == .active
            let recovery = BotResidencyRecoveryRecord(
                index: recoveries.count + 1, terminatedAt: BotResidencyTime.string(now),
                wasForeground: foreground, helloBefore: helloCount, p6Deferred: !foreground)
            recoveries.append(recovery)
            if !foreground {
                p6DeferredCount += 1
                log("p6-background-deferred", id: "recovery-\(recovery.index)", count: Int(count),
                    detail: "PhoneDSHHost.recoverAfterTermination: isForeground=false; pendingRecovery=true")
            } else {
                log("webcontent-terminated", id: "recovery-\(recovery.index)", count: Int(count))
            }
            updateState(force: true)
        case .restarted(let report):
            restartCount += 1
            if let index = recoveries.lastIndex(where: { $0.recoveredAt == nil }) {
                recoveries[index].restartReason = report.reason.rawValue
            }
            if currentScene != .active, report.reason == .webContentTerminated {
                p6ViolationCount += 1
                if let index = recoveries.lastIndex(where: { $0.recoveredAt == nil }) {
                    recoveries[index].p6Violation = true
                }
                log("p6-background-violation", detail: "WebContent restarted while not active")
            }
            log("engine-restarted", detail: "\(report.reason.rawValue) boot=\(report.bootID)")
        case .workerHello(let hello):
            let previous = helloCount
            helloCount = max(helloCount, hello.count)
            if currentScene != .active, helloCount > previous,
               recoveries.contains(where: { $0.recoveredAt == nil }) {
                p6ViolationCount += 1
                log("p6-background-violation", detail: "Worker HELLO while not active")
            }
            log("worker-hello", count: Int(hello.count))
        case .channelConnected(let count):
            log("channel-connected", count: Int(count))
        case .error(let message):
            let folded = message.lowercased()
            if folded.contains("hello") || folded.contains("proto_mismatch")
                || folded.contains("lease") || folded.contains("starttimedout") {
                helloFailureCount += 1
                log("hello-failure", detail: message)
            }
            if folded.contains("pdsh-recovery") || folded.contains("reconcile")
                || folded.contains("recovery/resume") {
                p15FailureCount += 1
                log("p15-recovery-failure", detail: message)
            }
            log("host-error", detail: message)
        case .orphanStepsSettled(let settlement):
            log("orphan-steps", count: settlement.count, detail: settlement.reason)
        case .budget(let decision):
            log("budget", detail: "action=\(String(describing: decision.action)) hardFail=\(decision.hardFail)")
        case .gatewayResponse, .console:
            break
        }
    }

    private func finish(status: String, reason: String?) async {
        guard !finished else { return }
        finished = true
        phase = status == "COMPLETE" ? "complete" : "aborted"
        statusText = reason ?? "App-side run complete; host evidence decides PASS or FAIL"
        log("app-finished", detail: "status=\(status) reason=\(reason ?? "none")")
        updateState(force: true)
        if let spikeConfiguration {
            let ended = Date()
            let observed = runStartedAt.map { (lockEndedAt ?? ended).timeIntervalSince($0) } ?? 0
            let report = BotResidencyAppReport(
                configuration: spikeConfiguration, status: status, reason: reason,
                runStartedAt: runStartedAt.map(BotResidencyTime.string),
                runEndedAt: BotResidencyTime.string(ended),
                durationReachedAt: durationReachedAt.map(BotResidencyTime.string),
                lockEndedAt: lockEndedAt.map(BotResidencyTime.string),
                observedLockSeconds: observed,
                protectedDataLockObserved: protectedDataLockObserved,
                protectedDataUnlockObserved: protectedDataUnlockObserved,
                p6DeferredCount: p6DeferredCount, p6ViolationCount: p6ViolationCount,
                helloFailureCount: helloFailureCount, p15FailureCount: p15FailureCount,
                modelRequestCount: mock.requestCount, events: events, recoveries: recoveries)
            store?.writeReport(report)
        }
        keepAlive.stop()
        mock.stop()
        hostEventTask?.cancel()
        harnessEventTask?.cancel()
        tickerTask?.cancel()
    }

    private func updateState(force: Bool = false) {
        guard let spikeConfiguration, let store else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStateWrite) >= 2 else { return }
        lastStateWrite = now
        var state = BotResidencyState(runID: spikeConfiguration.runID,
                                      updatedAt: BotResidencyTime.string(now), phase: phase)
        state.runStartedAt = runStartedAt.map(BotResidencyTime.string)
        state.durationReachedAt = durationReachedAt.map(BotResidencyTime.string)
        state.workerHelloCount = helloCount
        state.webContentTerminations = UInt64(terminationCount)
        state.injectedEvents = events.filter { $0.injectedAt != nil }.count
        state.deliveredEvents = events.filter { $0.deliveredAt != nil }.count
        state.pendingEvents = state.injectedEvents - state.deliveredEvents
        state.modelRequestCount = mock.requestCount
        state.detail = statusText
        if recoveries.contains(where: { $0.recoveredAt == nil }) {
            state.webContentPIDStatus = "terminated-awaiting-recovery"
        } else if let engine = anchor.engine {
            if let pid = BotResidencyWebContentPID.read(from: engine.view) {
                state.webContentPID = pid
                state.webContentPIDStatus = "available"
            } else {
                state.webContentPIDStatus = "unavailable"
            }
        } else {
            state.webContentPIDStatus = "no-engine"
        }
        store.writeState(state)
    }

    private func installLockObservers() {
        let center = NotificationCenter.default
        lockUnavailableObserver = center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.protectedDataLockObserved = true
                self?.log("protected-data-locked")
            }
        }
        lockAvailableObserver = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.protectedDataUnlockObserved = true
                self?.log("protected-data-unlocked")
            }
        }
    }

    private func log(_ kind: String, id: String? = nil, turnID: String? = nil,
                     seq: UInt64? = nil, count: Int? = nil, seconds: Double? = nil,
                     detail: String? = nil) {
        let bounded = detail.map { String($0.prefix(4000)) }
        store?.append(BotResidencyLogEntry(
            at: BotResidencyTime.string(), monotonicSeconds: ProcessInfo.processInfo.systemUptime,
            kind: kind, id: id, turnID: turnID, seq: seq, count: count,
            seconds: seconds, detail: bounded))
        NSLog("bot-residency %@ %@", kind, id ?? "")
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

private enum BotResidencyRunError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}
#endif
