// SPDX-License-Identifier: MIT
// App side of device-app-v1 (spec/device/v1/device-app.md §7): binds the P26 host tools of
// PhoneDSHBot to the Link device the Bot is bound to. The device is never taken from model
// arguments: it is `DeviceBotRegistry`'s binding of the calling Bot.
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHBot

#if canImport(UIKit)
@MainActor
enum DeviceAppLiveWiring {
    /// Registers the tool host on the runtime and the Bot-to-device resolver used by the persona guide.
    static func attach(runtime: BotMCPRuntime, domain: SQLiteDomainStore) async {
        DeviceAppWiring.setBoundDeviceResolver { botID in await boundKey(botID) }
        let installer = DeviceAppWiring.installer(
            linkState: { key in await linkState(key) },
            info: { key in await info(key) },
            stopRunning: { key in await stop(key) },
            transfer: { request in await transfer(request) },
            installedState: { key, name in await installedState(key, name) })
        let audit = DeviceAppWiring.auditor(
            botForDevice: { key in await MainActor.run { DeviceBotRegistry.shared.botID(forDevice: key) } },
            append: { event in _ = try await domain.append(event) })
        await runtime.setDeviceAppTools(DeviceAppWiring.toolHost(
            deviceKey: { botID in await boundKey(botID) }, installer: installer, audit: audit,
            deviceName: { key in await displayName(key) },
            existingApp: { key, name in KnownApps.title(device: key, name: name) },
            runApp: { key, name in await run(key, name) }))
    }

    /// The binding's Link device key. A TonoLink board's voice-link Bot has no Link device.
    private static func boundKey(_ botID: String) async -> String? {
        await MainActor.run {
            let registry = DeviceBotRegistry.shared
            guard registry.boardName(forBot: botID) == nil else { return nil }
            return registry.deviceID(forBot: botID)
        }
    }

    private static func device(_ key: String) -> BLEDeviceStore.Device? {
        BLEDeviceStore.shared.devices.first { $0.linkDeviceID.lowercased() == key }
            ?? BLEDeviceStore.shared.devices.first { $0.linkIdentity == key }
    }

    private static func linkState(_ key: String) async -> DeviceAppLinkState? {
        await MainActor.run {
            guard let device = device(key) else { return nil }
            return DeviceAppLinkState(connected: device.state == "已连接", tools: device.linkTools,
                                      granted: device.grantedTools)
        }
    }

    private static func deviceID(_ key: String) async -> UUID? { await MainActor.run { device(key)?.id } }

    private static func call(_ deviceID: UUID, _ name: String, _ arguments: JSONValue) async throws -> JSONValue? {
        let outcome = try await callLinkTool(
            deviceID: deviceID, name: name, arguments: arguments,
            idempotencyKey: "devapp.\(name).\(UUID().uuidString.lowercased())", origin: .user)
        guard case .completed(_, let reply) = outcome, reply["status"]?.stringValue == "completed",
              let result = reply["result"], result["ok"]?.boolValue == true else { return nil }
        return result
    }

    private static func info(_ key: String) async -> DeviceAppInfoResult {
        guard let id = await deviceID(key) else { return .unavailable("设备不可用") }
        do {
            guard let result = try await call(id, "app.info", .object([:])) else {
                return .unavailable("设备没有给出成功的回复")
            }
            KnownApps.replace(device: key, with: result["apps"]?.arrayValue ?? [])
            let running = (result["apps"]?.arrayValue ?? []).compactMap { app -> String? in
                app["running"]?.boolValue == true ? app["name"]?.stringValue : nil
            }
            return .reply(protocolName: result["protocol"]?.stringValue, running: running)
        } catch {
            return .unavailable(String(describing: error))
        }
    }

    /// Display name the user sees in the device list; nil when the device is unknown.
    private static func displayName(_ key: String) async -> String? {
        await MainActor.run {
            let name = device(key)?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    /// `app.run` of the app just installed (user origin, same waiver as the install).
    /// nil: it started; otherwise the machine code of the failure.
    private static func run(_ key: String, _ name: String) async -> String? {
        guard let id = await deviceID(key) else { return "device_not_found" }
        do {
            return try await call(id, "app.run", .object(["name": .string(name)])) == nil ? "run_failed" : nil
        } catch {
            return "run_failed"
        }
    }

    /// Reads `app.info` after an install whose commit reply was lost (never sends a write).
    private static func installedState(_ key: String, _ name: String) async -> DeviceAppInstalledState {
        guard let id = await deviceID(key) else { return .unreadable }
        guard let result = try? await call(id, "app.info", .object([:])) else { return .unreadable }
        let apps = result["apps"]?.arrayValue ?? []
        KnownApps.replace(device: key, with: apps)
        guard let app = apps.first(where: { $0["name"]?.stringValue == name }),
              let digest = app["digest"]?.stringValue, !digest.isEmpty else { return .absent }
        return .installed(digest: digest)
    }

    private static func stop(_ key: String) async -> String? {
        guard let id = await deviceID(key) else { return "设备不可用" }
        do {
            return try await call(id, "app.stop", .object([:])) == nil ? "app.stop 没有成功" : nil
        } catch {
            return String(describing: error)
        }
    }

    private static func transfer(_ request: DeviceAppInstallRequest) async -> DeviceAppInstallOutcome {
        guard let id = await deviceID(request.deviceKey) else {
            return .failed(code: "device_not_found", message: "设备不可用")
        }
        let bundle = PhoneDSHBLE.DeviceAppBundle(
            name: request.manifest.name,
            files: request.files.map { PhoneDSHBLE.DeviceAppFile(path: $0.path, bytes: $0.data) },
            digest: request.digest)
        do {
            let result = try await installer(deviceID: id, installID: UUID(uuidString: request.installID))
                .install(bundle)
            KnownApps.add(device: request.deviceKey, name: request.manifest.name, title: request.manifest.title)
            return .installed(digest: result.digest)
        } catch let error as DeviceAppInstallError {
            switch error {
            case .invalidBundle(let text): return .failed(code: "invalid_bundle", message: text)
            case .deviceRefused(let tool, let code): return .failed(code: code, message: "\(tool) 被设备拒绝")
            case .notExecuted(let tool, let stage, let status):
                return .failed(code: "not_executed", message: "\(tool) 没有执行（\(stage) \(status)）")
            case .callFailed(let tool, let message):
                // A commit that may have been sent is settled by app.info, never retried; any other
                // call cut off before the commit is an interrupted transfer (one automatic retry).
                if tool == "app.commit" { return .outcomeUnknown(message: "app.commit：\(message)") }
                return .failed(code: DeviceAppWiring.interruptedCode, message: "\(tool)：\(message)")
            case .linkBusy: return .failed(code: "link_busy", message: "设备的 Link 正忙")
            case .protocolViolation(let text): return .failed(code: "protocol", message: text)
            case .digestMismatch: return .failed(code: "digest_mismatch", message: "设备报告的摘要与批准的不一致")
            case .commitNotInstalled: return .failed(code: "commit_not_installed", message: "设备没有安装这个应用")
            case .commitOutcomeUnknown:
                return .outcomeUnknown(message: "提交的回复丢失，设备上的 app.info 也没能确认")
            case .tooManyResumes: return .failed(code: "too_many_resumes", message: "传输中断次数过多")
            }
        } catch is LinkBusy {
            return .failed(code: "link_busy", message: "设备的 Link 正忙")
        } catch is CancellationError {
            return .failed(code: "cancelled", message: "安装被取消")
        } catch {
            return .failed(code: DeviceAppWiring.interruptedCode, message: String(describing: error))
        }
    }

    /// The installer bound to the real Link entry as the user origin; it prunes the install's
    /// staging intents from the Link journal when the install ends (device-app.md §7).
    private static func installer(deviceID: UUID, installID: UUID?) -> DeviceAppInstaller {
        DeviceAppInstaller.live(deviceID: deviceID, installID: installID ?? UUID())
    }
}

/// Apps this phone has seen on each device (the install path's own app.info and installs),
/// kept so the confirmation card can say "replaces 「X」" without a radio call before approval.
private enum KnownApps {
    private static func key(_ device: String) -> String { "pdsh.deviceApp.known.\(device)" }

    static func title(device: String, name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key(device)) as? [String: String])?[name]
    }

    static func add(device: String, name: String, title: String) {
        var table = (UserDefaults.standard.dictionary(forKey: key(device)) as? [String: String]) ?? [:]
        table[name] = title
        UserDefaults.standard.set(table, forKey: key(device))
    }

    static func replace(device: String, with apps: [JSONValue]) {
        var table: [String: String] = [:]
        for app in apps {
            guard let name = app["name"]?.stringValue else { continue }
            let title = app["title"]?.stringValue ?? ""
            table[name] = title.isEmpty ? name : title
        }
        UserDefaults.standard.set(table, forKey: key(device))
    }
}
#endif
