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
            return ("device_not_found", "这个 Bot 绑定的设备不是已知的 Link 设备，不能安装设备应用")
        }
        guard state.connected else {
            return ("device_not_connected", "设备没有连接，请先连上设备再安装")
        }
        let missing = requiredTools.filter { !state.tools.contains($0) }
        guard missing.isEmpty else {
            return ("device_tools_missing",
                    "设备的工具列表缺少 \(missing.joined(separator: "、"))，它不是设备应用的安装目标")
        }
        let denied = requiredTools.filter { !state.granted.contains($0) }
        guard denied.isEmpty else {
            return ("device_not_authorized",
                    "设备的 \(denied.joined(separator: "、")) 还没有在蓝牙设备设置里授权")
        }
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
        transfer: @escaping @Sendable (DeviceAppInstallRequest) async -> DeviceAppInstallOutcome
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
            return await transfer(request)
        }
    }

    // MARK: - Audit

    public enum AuditError: Error, Equatable, Sendable { case noBot }

    /// Builds the durable `ui.system_event{event:"device.app.install"}`.
    public static func auditEvent(_ audit: DeviceAppInstallAudit, botID: String,
                                  eventID: String = "device-app-install-\(UUID().uuidString.lowercased())",
                                  time: Int64) -> BotEvent {
        BotEvent(
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
                                audit: @escaping DeviceAppToolHost.Auditor) -> DeviceAppToolHost {
        DeviceAppToolHost(deviceKey: deviceKey, validate: validator, digester: digester,
                          installer: installer, audit: audit)
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
