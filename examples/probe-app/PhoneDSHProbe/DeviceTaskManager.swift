// SPDX-License-Identifier: MIT
import Foundation
import Observation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHDeviceTasks

@MainActor @Observable final class DeviceTaskManager {
    static let shared = DeviceTaskManager()
    private(set) var active: Set<String> = []
    private(set) var error: String?
    private(set) var starting = Set<String>()
    @ObservationIgnored private var generation: [String: UUID] = [:]
    @ObservationIgnored private let grants = DeviceTaskGrantCoordinator()
    @ObservationIgnored private var deviceIDs: [String: String] = [:]
    @ObservationIgnored private var bleIDs: [String: UUID] = [:]
    @ObservationIgnored private var monitors: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var intake: DeviceTaskIntake?
    @ObservationIgnored private var runner: DeviceDSHRunner?
    /// The one journal owner shared by LAN and secure BLE intake.
    @ObservationIgnored private var executor: DeviceTaskExecutor?
    @ObservationIgnored private var creating: Task<(DeviceTaskIntake, DeviceDSHRunner), Error>?
    #if PDSH_TEST_HOOKS
    @ObservationIgnored var testEngine: (DeviceTaskIntake, DeviceDSHRunner)?
    @ObservationIgnored var testMonitorFinished: ((UUID) -> Void)?
    func testGeneration(_ key: String) -> UUID? { generation[key] }
    #endif
    private var foreground = true
    @ObservationIgnored private let settings: PhoneMCPAccessSettings
    @ObservationIgnored private let makeLANInbox: (URL, String) throws -> LANDeviceTaskInbox
    @ObservationIgnored private let isLANConnected: (MCPServerSummary) async throws -> Bool

    init(settings: PhoneMCPAccessSettings = .shared,
         makeLANInbox: @escaping (URL, String) throws -> LANDeviceTaskInbox = {
             try LANDeviceTaskInbox(mcpURL: $0, authorization: $1)
         },
         isLANConnected: @escaping (MCPServerSummary) async throws -> Bool = { row in
             let transport = try await ChatModel.shared.transportForManagement()
             let snapshot = try await transport.call("phone/mcpList", args: .object([:]))
             let current = (snapshot["servers"]?.arrayValue ?? []).first { $0["serverName"]?.stringValue == row.serverName }
             return snapshot["error"] == nil && current?["url"]?.stringValue == row.url &&
                 current?["enabled"]?.boolValue != false && current?["status"]?.stringValue == "connected"
         }) {
        self.settings = settings
        self.makeLANInbox = makeLANInbox
        self.isLANConnected = isLANConnected
    }

    func isActive(_ key: String) -> Bool { active.contains(key) || starting.contains(key) }
    static func lanKey(_ name: String) -> String { "lan-ui:" + name }
    static func bleKey(_ id: UUID) -> String { "ble-ui:" + id.uuidString.lowercased() }

    private func engine() async throws -> (DeviceTaskIntake, DeviceDSHRunner) {
        #if PDSH_TEST_HOOKS
        if let testEngine { intake = testEngine.0; runner = testEngine.1; return testEngine }
        #endif
        if let intake, let runner { try await runner.verifyIsolation(); return (intake, runner) }
        if let creating { return try await creating.value }
        let task = Task { @MainActor in
            let transport = try await ChatModel.shared.transportForManagement()
            let runner = DeviceDSHRunner(transport: transport)
            try await runner.verifyIsolation()
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let executor = try DeviceTaskExecutor(directory: support.appendingPathComponent("device-task-journal", isDirectory: true), runner: runner)
            self.executor = executor
            return (DeviceTaskIntake(executor: executor), runner)
        }
        creating = task
        do { let pair = try await task.value; creating = nil; intake = pair.0; runner = pair.1; return pair }
        catch { creating = nil; throw error }
    }

    private func validLAN(name: String, grant: PhoneMCPAccessGrant, secrets: [String: String]) -> Bool {
        guard let snapshot = try? settings.load(), !snapshot.unreadableSecrets.contains(name),
              snapshot.grants.first(where: { $0.serverName == name }) == grant else { return false }
        return settings.secretValues(for: name) == secrets
    }

    func startLAN(_ row: MCPServerSummary) async {
        let key = Self.lanKey(row.serverName)
        guard foreground, !active.contains(key), starting.insert(key).inserted else { return }
        let token = UUID(); generation[key] = token
        defer { if generation[key] == token { starting.remove(key) } }
        error = nil
        do {
            guard row.enabled, row.status == "connected", let grant = row.grant, grant.url == row.url,
                  let url = URL(string: grant.url), let secrets = settings.secretValues(for: row.serverName),
                  let auth = secrets.first(where: { $0.key.lowercased() == "authorization" })?.value else { throw DeviceTaskError.unauthorized }
            let inbox = try makeLANInbox(url, auth)
            let pair = try await engine()
            guard foreground, generation[key] == token, validLAN(name: row.serverName, grant: grant, secrets: secrets) else { throw DeviceTaskError.unauthorized }
            // The row may have gone stale while the engine was starting. Check
            // the live registry before intake, then recheck authorization after
            // the suspension point so revocation cannot race the lookup.
            guard try await isLANConnected(row) else { throw DeviceTaskError.unauthorized }
            guard foreground, generation[key] == token, validLAN(name: row.serverName, grant: grant, secrets: secrets) else { throw DeviceTaskError.unauthorized }
            guard !deviceIDs.values.contains(inbox.deviceID) else { throw DeviceTaskError.deviceBusy }
            deviceIDs[key] = inbox.deviceID; active.insert(key)
            let start = try grants.start(key: key, token: token, deviceID: inbox.deviceID, intake: pair.0, inbox: inbox,
                onStopped: { [weak self] in await self?.finished(key: key, token: token) }) { [weak self] in
                    for try await task in inbox.tasks() {
                        guard await MainActor.run(body: { self?.validLAN(name: row.serverName, grant: grant, secrets: secrets) == true }) else { throw DeviceTaskError.unauthorized }
                        return task
                    }
                    throw DeviceTaskError.unauthorized
                }
            let ok = try await start.value
            guard ok else { throw DeviceTaskError.deviceBusy }
            guard generation[key] == token, active.contains(key) else { return }
            monitors[key] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    guard self.generation[key] == token else { return }
                    guard self.validLAN(name: row.serverName, grant: grant, secrets: secrets), self.foreground else { await self.stop(key); return }
                    await self.grants.checkConnection(key: key, token: token, check: {
                        try await self.isLANConnected(row)
                    }, onDisconnected: {
                        _ = self.invalidate(key)
                    })
                    #if PDSH_TEST_HOOKS
                    self.testMonitorFinished?(token)
                    #endif
                    guard self.generation[key] == token else { return }
                }
            }
        } catch {
            if generation[key] == token {
                self.error = "无法启用设备派任务：请确认设备已连接、已授权且引擎隔离可用。"
                await stop(key)
            }
        }
    }

    func startBLE(_ id: UUID) async {
        let key = Self.bleKey(id)
        guard foreground, !active.contains(key), starting.insert(key).inserted else { return }
        let token = UUID(); generation[key] = token; bleIDs[key] = id
        defer { if generation[key] == token { starting.remove(key) } }
        error = nil
        do {
            try BLEDeviceStore.shared.grantDeviceTasks(id, enabled: true)
            let inbox = try BLEDeviceTaskInbox(peripheralID: id)
            let pair = try await engine()
            guard foreground, generation[key] == token, BLEDeviceStore.shared.devices.first(where: { $0.id == id })?.allowDeviceTasks == true else { throw DeviceTaskError.unauthorized }
            guard !deviceIDs.values.contains(inbox.deviceID) else { throw DeviceTaskError.deviceBusy }
            deviceIDs[key] = inbox.deviceID; active.insert(key)
            let start = try grants.start(key: key, token: token, deviceID: inbox.deviceID, intake: pair.0, inbox: inbox,
                onStopped: { [weak self] in await self?.finished(key: key, token: token) }) { try await inbox.next() }
            let ok = try await start.value
            guard ok else { throw DeviceTaskError.deviceBusy }
            guard generation[key] == token, active.contains(key) else { return }
            monitors[key] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    guard self.foreground, BLEDeviceStore.shared.devices.first(where: { $0.id == id })?.allowDeviceTasks == true else { await self.stop(key); return }
                }
            }
        } catch {
            if generation[key] == token {
                self.error = "无法启用设备派任务：请确认设备已连接、支持任务协议且引擎隔离可用。"
                await stop(key)
            }
        }
    }
    #if PDSH_ENABLE_DEVICE_TASKS
    /// secure-session-v2 grant for the coordinator's ready generation. The
    /// store gate refuses in every package build (GAP-16); the error is shown.
    func startSecureBLE() async {
        guard foreground else { return }
        error = nil
        do {
            _ = try await engine()
            guard foreground, let executor else { throw DeviceTaskError.unauthorized }
            try await BLESecureSessionCoordinator.shared.grant(executor: executor)
        } catch {
            self.error = "无法授权安全设备派任务：\(error.localizedDescription)"
        }
    }

    func stopSecureBLE() { BLESecureSessionCoordinator.shared.revoke() }
    #endif

    private func invalidate(_ key: String) -> Task<Void, Never>? {
        generation[key] = nil; active.remove(key); starting.remove(key); monitors.removeValue(forKey: key)?.cancel()
        if let id = bleIDs.removeValue(forKey: key) { try? BLEDeviceStore.shared.grantDeviceTasks(id, enabled: false) }
        deviceIDs[key] = nil
        return grants.invalidate(key: key)
    }
    func stop(_ key: String) async {
        let pending = invalidate(key)
        await pending?.value
    }
    private func finished(key: String, token: UUID) async {
        guard generation[key] == token else { return }
        generation[key] = nil; active.remove(key); starting.remove(key); deviceIDs[key] = nil; monitors.removeValue(forKey: key)?.cancel()
        if let id = bleIDs.removeValue(forKey: key) { try? BLEDeviceStore.shared.grantDeviceTasks(id, enabled: false) }
        error = "设备任务连接已停止；请检查设备连接和任务协议后重新授权。"
    }
    func sceneActive(_ active: Bool) async {
        foreground = active
        #if PDSH_ENABLE_DEVICE_TASKS
        BLESecureSessionCoordinator.shared.sceneActive(active)
        #endif
        guard !active else { return }
        creating?.cancel()
        let pending = Array(generation.keys).compactMap { invalidate($0) }
        for task in pending { await task.value }
    }
}
