// SPDX-License-Identifier: MIT

import Foundation

/// What the App can say about the Link device a Bot is bound to, read from
/// phone-side state only (no radio).
public struct DeviceAppLinkState: Sendable, Equatable {
    public let connected: Bool
    /// Names from the device's `tools/list`.
    public let tools: [String]
    /// Tools the user has authorized for the Link (`authorizeLink` refuses the rest).
    public let granted: Set<String>
    public init(connected: Bool, tools: [String], granted: Set<String>) {
        self.connected = connected
        self.tools = tools
        self.granted = granted
    }
}

/// Result of the `app.info` read made after approval and before `app.begin`.
public enum DeviceAppInfoResult: Sendable, Equatable {
    /// `protocol` of the reply and the names of apps it lists as running.
    case reply(protocolName: String?, running: [String])
    case unavailable(String)
}

/// What `app.info` says about one app name after an install whose commit reply was lost.
public enum DeviceAppInstalledState: Sendable, Equatable {
    case installed(digest: String)
    case absent
    /// The device could not be read (not connected, no reply).
    case unreadable
}

/// Wiring of the P26 device-app host tools to the validator, the digest, the
/// installer and the durable audit (device-app.md §7, `device-app-v1.1`).
/// PhoneDSHBot still knows no BLE or Link code: those are closures from the App.
public enum DeviceAppWiring {
    public static let protocolName = "device-app-v1"
    /// §5: a device without all of these is not an install target.
    public static let requiredTools = ["app.info", "app.begin", "app.put", "app.abort",
                                       "app.commit", "app.run", "app.stop", "app.remove"]

    // MARK: - Validator and digest

    public static let validator: DeviceAppToolHost.Validator = { files, perms in
        var table: [String: String] = [:]
        for file in files { table[file.path] = file.content }
        guard let failure = DeviceAppValidator.check(files: table, perms: perms) else { return nil }
        return DeviceAppValidationFailure(code: failure.code.rawValue, path: failure.path, line: failure.line)
    }

    /// §4, from this module's `DeviceAppRules` (the BLE module has its own; the
    /// shared golden runs through both and the install request is cross-checked).
    public static let digester: DeviceAppToolHost.Digester = { entries in
        DeviceAppRules.manifestDigest(entries.map {
            DeviceAppRules.FileEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
        })
    }

    // MARK: - Preflight (phone-side state)

    public static func preflight(_ state: DeviceAppLinkState?) -> (code: String, message: String)? {
        guard let state else {
            return ("device_not_found", DeviceAppCustomerText.sentence(forCode: "device_not_found"))
        }
        guard state.connected else {
            return ("device_not_connected", DeviceAppCustomerText.sentence(forCode: "device_not_connected"))
        }
        let missing = requiredTools.filter { !state.tools.contains($0) }
        guard missing.isEmpty else {
            return ("device_tools_missing",
                    "设备的工具列表缺少 \(missing.joined(separator: "、"))，它不是设备应用的安装目标")
        }
        // device-app-v1.3: no Settings-grant check. The user's once-only approval of this exact
        // install is the authorization; the Link entry waives the grant for user-origin app.* only.
        return nil
    }

    public static func checkInfo(_ info: DeviceAppInfoResult) -> (code: String, message: String)? {
        switch info {
        case .unavailable(let reason):
            return ("device_info_failed", "读取设备的 app.info 失败：\(reason)")
        case .reply(let name, _):
            guard name == protocolName else {
                return ("device_protocol_mismatch", "设备的 app.info 没有报告 \(protocolName)，不是安装目标")
            }
            return nil
        }
    }

    /// The installer given to `DeviceAppToolHost`. It runs after the user's
    /// approval and before any transfer: link state, then `app.info`, then
    /// `stopRunning` (only when the same app runs) and `transfer`. The device comes from `request.deviceKey` (the Bot's binding),
    /// never from model arguments.
    public static func installer(
        linkState: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppLinkState?,
        info: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppInfoResult,
        stopRunning: @escaping @Sendable (_ deviceKey: String) async -> String?,
        transfer: @escaping @Sendable (DeviceAppInstallRequest) async -> DeviceAppInstallOutcome,
        installedState: (@Sendable (_ deviceKey: String, _ appName: String) async -> DeviceAppInstalledState)? = nil,
        reconnectAttempts: Int = 10, settleAttempts: Int = 4,
        pauseNanoseconds: UInt64 = 1_500_000_000
    ) -> DeviceAppToolHost.Installer {
        { request in
            if let problem = preflight(await linkState(request.deviceKey)) {
                return .failed(code: problem.code, message: problem.message)
            }
            let reply = await info(request.deviceKey)
            if let problem = checkInfo(reply) {
                return .failed(code: problem.code, message: problem.message)
            }
            // §6 rule 5: a commit over a running app fails `running`; the host stops it first.
            if case .reply(_, let running) = reply, running.contains(request.manifest.name),
               let message = await stopRunning(request.deviceKey) {
                return .failed(code: "stop_failed", message: message)
            }
            // Same digest in both modules' rules, or nothing is sent.
            let local = DeviceAppRules.manifestDigest(request.entries.map {
                DeviceAppRules.FileEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
            })
            guard local == request.digest else {
                return .failed(code: "digest_mismatch", message: "摘要与已批准的不一致，未发送")
            }
            var outcome = await transfer(request)
            // A transfer cut before `app.commit` was sent (disconnect, device reboot): one automatic
            // retry after the link is back. Same name and digest, so the device-side resume rules
            // (§6 rule 1) apply, with a new install id and so new staging journal keys. The commit is
            // never repeated: the transfer maps a commit that may have been sent to `outcomeUnknown`.
            if case .failed(let code, _) = outcome, code == interruptedCode {
                var back = false
                for attempt in 0..<max(reconnectAttempts, 0) {
                    if let state = await linkState(request.deviceKey), state.connected { back = true; break }
                    if attempt + 1 < reconnectAttempts, pauseNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: pauseNanoseconds)
                    }
                }
                if back {
                    let again = DeviceAppInstallRequest(
                        installID: UUID().uuidString.lowercased(), deviceKey: request.deviceKey,
                        manifest: request.manifest, files: request.files, entries: request.entries,
                        digest: request.digest)
                    outcome = await transfer(again)
                }
            }
            // The commit may have happened: the installer itself reads `app.info` and decides.
            if case .outcomeUnknown(let message) = outcome, let installedState {
                var settled: DeviceAppInstallOutcome?
                for attempt in 0..<max(settleAttempts, 1) {
                    switch await installedState(request.deviceKey, request.manifest.name) {
                    case .installed(let digest) where digest == request.digest:
                        settled = .installed(digest: digest)
                    case .installed, .absent:
                        settled = .failed(code: "not_installed",
                                          message: "app.info 里没有这个摘要的应用：设备上原来的应用没有改变")
                    case .unreadable:
                        if attempt + 1 < max(settleAttempts, 1), pauseNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: pauseNanoseconds)
                        }
                    }
                    if settled != nil { break }
                }
                outcome = settled ?? .outcomeUnknown(message: message)
            }
            return outcome
        }
    }

    /// Code the transfer reports when the link broke before `app.commit` was sent.
    public static let interruptedCode = "transfer_interrupted"

    // MARK: - List and remove (device-app-v1.5)

    /// The `DeviceAppList` reader: link state, then one `app.info`; no write. The device comes
    /// from the Bot's binding.
    public static func lister(
        linkState: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppLinkState?,
        snapshot: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppSnapshot
    ) -> DeviceAppToolHost.Lister {
        { deviceKey in
            if let problem = preflight(await linkState(deviceKey)) {
                return .failed(code: problem.code, message: problem.message)
            }
            switch await snapshot(deviceKey) {
            case .unavailable(let reason):
                return .failed(code: "device_info_failed", message: "读取设备的 app.info 失败：\(reason)")
            case .reply(let name, let apps):
                guard name == protocolName else {
                    return .failed(code: "device_protocol_mismatch",
                                   message: "设备的 app.info 没有报告 \(protocolName)，不是安装目标")
                }
                return .apps(apps)
            }
        }
    }

    /// How one `app.remove` call ended.
    public enum RemoveCall: Sendable, Equatable {
        case removed
        /// The device answered `ok:false` with its §8 code.
        case refused(code: String)
        /// No reply, or the link broke after the request may have been sent: the device decides.
        case lost(String)
    }

    /// The `DeviceAppRemove` remover, given to `DeviceAppToolHost` and run after the user's
    /// approval: link state, `app.info` (the app must be listed), `app.stop` only when that app
    /// runs, one `app.remove`. A lost remove reply is settled by reading `app.info` (never
    /// repeated): name absent means removed, present means not removed.
    public static func remover(
        linkState: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppLinkState?,
        snapshot: @escaping @Sendable (_ deviceKey: String) async -> DeviceAppSnapshot,
        stopRunning: @escaping @Sendable (_ deviceKey: String) async -> String?,
        removeCall: @escaping @Sendable (_ deviceKey: String, _ name: String) async -> RemoveCall,
        settleAttempts: Int = 4, pauseNanoseconds: UInt64 = 1_500_000_000
    ) -> DeviceAppToolHost.Remover {
        { request in
            guard DeviceAppRules.isValidName(request.name) else {
                return .failed(code: "bad_request", message: "名字不符合应用名规则，没有发送")
            }
            if let problem = preflight(await linkState(request.deviceKey)) {
                return .failed(code: problem.code, message: problem.message)
            }
            var wasRunning = false
            switch await snapshot(request.deviceKey) {
            case .unavailable(let reason):
                return .failed(code: "device_info_failed", message: "读取设备的 app.info 失败：\(reason)")
            case .reply(let name, let apps):
                guard name == protocolName else {
                    return .failed(code: "device_protocol_mismatch",
                                   message: "设备的 app.info 没有报告 \(protocolName)，不是安装目标")
                }
                guard let app = apps.first(where: { $0.name == request.name }) else {
                    return .failed(code: "not_found", message: "app.info 里没有这个应用")
                }
                wasRunning = app.running
            }
            if wasRunning, let message = await stopRunning(request.deviceKey) {
                return .failed(code: "stop_failed", message: message)
            }
            switch await removeCall(request.deviceKey, request.name) {
            case .removed:
                return .removed(wasRunning: wasRunning)
            case .refused(let code):
                return .failed(code: code, message: "app.remove 被设备拒绝")
            case .lost(let message):
                for attempt in 0..<max(settleAttempts, 1) {
                    if case .reply(_, let apps) = await snapshot(request.deviceKey) {
                        return apps.contains(where: { $0.name == request.name })
                            ? .failed(code: "not_removed", message: "app.info 里这个应用还在：\(message)")
                            : .removed(wasRunning: wasRunning)
                    }
                    if attempt + 1 < max(settleAttempts, 1), pauseNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: pauseNanoseconds)
                    }
                }
                return .outcomeUnknown(message: "app.remove：\(message)")
            }
        }
    }

    // MARK: - Audit

    public enum AuditError: Error, Equatable, Sendable { case noBot }

    /// Builds the durable `ui.system_event{event:"device.app.install"}`.
    public static func auditEvent(_ audit: DeviceAppInstallAudit, botID: String,
                                  eventID: String? = nil,
                                  time: Int64) -> BotEvent {
        let eventID = eventID ?? "device-app-\(audit.action.rawValue)-\(UUID().uuidString.lowercased())"
        return BotEvent(
            type: "ui.system_event", eventId: eventID, time: time,
            origin: .local(source: "runtime"), traceId: eventID,
            principal: BotPrincipal(botId: botID, sessionId: audit.author.sessionId, kind: "team"),
            causationId: nil, correlationId: audit.author.rpcId, data: audit.eventData)
    }

    /// A failed append throws, so the host reports `audit_recorded:false`.
    public static func auditor(
        botForDevice: @escaping @Sendable (String) async -> String?,
        append: @escaping @Sendable (BotEvent) async throws -> Void,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) -> DeviceAppToolHost.Auditor {
        { audit in
            guard let botID = await botForDevice(audit.deviceKey) else { throw AuditError.noBot }
            try await append(auditEvent(audit, botID: botID, time: now()))
        }
    }

    // MARK: - Host and persona

    public static func toolHost(deviceKey: @escaping DeviceAppToolHost.DeviceKeyResolver,
                                installer: @escaping DeviceAppToolHost.Installer,
                                audit: @escaping DeviceAppToolHost.Auditor,
                                deviceName: @escaping DeviceAppToolHost.DeviceNamer = { _ in nil },
                                existingApp: @escaping DeviceAppToolHost.ExistingApp = { _, _ in nil },
                                runApp: DeviceAppToolHost.AppRunner? = nil,
                                lister: DeviceAppToolHost.Lister? = nil,
                                remover: DeviceAppToolHost.Remover? = nil) -> DeviceAppToolHost {
        let noLister: DeviceAppToolHost.Lister = { _ in
            .failed(code: "device_tools_missing", message: "no lister wired")
        }
        let noRemover: DeviceAppToolHost.Remover = { _ in
            .failed(code: "device_tools_missing", message: "no remover wired")
        }
        return DeviceAppToolHost(
            deviceKey: deviceKey, validate: validator, digester: digester,
            installer: installer, audit: audit, deviceName: deviceName,
            existingApp: existingApp, runApp: runApp,
            lister: lister ?? noLister, remover: remover ?? noRemover)
    }

    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable (String) async -> String?)?
        func set(_ new: (@Sendable (String) async -> String?)?) { lock.lock(); value = new; lock.unlock() }
        func get() -> (@Sendable (String) async -> String?)? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static let resolver = Resolver()

    /// Set by the App once the Bot-to-device binding exists. Until then no Bot is bound.
    public static func setBoundDeviceResolver(_ resolver: (@Sendable (String) async -> String?)?) {
        self.resolver.set(resolver)
    }

    /// Wraps the App's persona provider with the authoring guide (bound Bots only).
    public static func decoratePersona(
        _ persona: @escaping @Sendable (String, String, BotSessionKind) async throws -> String
    ) -> @Sendable (String, String, BotSessionKind) async throws -> String {
        DeviceAppAuthoringGuide.decorate(
            persona: persona,
            deviceKey: { botID in await resolver.get()?(botID) })
    }
}
