// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Behaviour of the two P26 device-app host tools (device-app.md §7).
/// Everything outside this module is injected.
public actor DeviceAppToolHost {
    public typealias DeviceKeyResolver = @Sendable (_ botID: String) async -> String?
    public typealias Validator = @Sendable (_ files: [DeviceAppFile], _ perms: [String])
        -> DeviceAppValidationFailure?
    /// §4 digest over the entries (sorting and formatting are the digester's).
    public typealias Digester = @Sendable (_ entries: [DeviceAppFileEntry]) -> String
    public typealias Installer = @Sendable (DeviceAppInstallRequest) async -> DeviceAppInstallOutcome
    public typealias Auditor = @Sendable (DeviceAppInstallAudit) async throws -> Void
    public typealias ApprovalRequest = @Sendable (BotToolEffect) async -> BotApprovalOutcome

    /// Host-side code for a failure that is not a §9 static-check code.
    public static let manifestFailureCode = "manifest"
    static let maxStagedPerSession = 4

    private struct Staged {
        let deviceKey: String
        let manifest: DeviceAppManifestSummary
        let files: [DeviceAppFile]
        let entries: [DeviceAppFileEntry]
        let digest: String
    }

    private let deviceKey: DeviceKeyResolver
    private let validate: Validator
    private let digester: Digester
    private let installer: Installer
    private let audit: Auditor
    private var staged: [String: [Staged]] = [:]
    private var busyDevices: Set<String> = []

    public init(deviceKey: @escaping DeviceKeyResolver, validate: @escaping Validator,
                digester: @escaping Digester, installer: @escaping Installer,
                audit: @escaping Auditor) {
        self.deviceKey = deviceKey
        self.validate = validate
        self.digester = digester
        self.installer = installer
        self.audit = audit
    }

    /// Visibility rule: only a Bot with a device binding lists the tools.
    public func isBound(botID: String) async -> Bool {
        guard let key = await deviceKey(botID) else { return false }
        return !key.isEmpty
    }

    private func sessionKey(_ principal: BotGatewayPrincipal) -> String {
        "\(principal.botId)\u{1F}\(principal.sessionId)"
    }

    private func boundDevice(_ principal: BotGatewayPrincipal) async -> String? {
        guard let key = await deviceKey(principal.botId), !key.isEmpty else { return nil }
        return key
    }

    private static let notBound = BotMCPCallResult.failure(
        "permission_denied", "这个 Bot 没有绑定设备，不能使用设备应用工具")

    // MARK: - Shared checking

    private enum Checked {
        case ok(manifest: DeviceAppManifestSummary, entries: [DeviceAppFileEntry], digest: String)
        case failure(DeviceAppValidationFailure)
    }

    private func check(_ files: [DeviceAppFile]) -> Checked {
        let manifest = Self.manifest(in: files)
        if let failure = validate(files, manifest?.perms ?? []) { return .failure(failure) }
        guard let manifest else {
            return .failure(DeviceAppValidationFailure(
                code: Self.manifestFailureCode, path: "app.json", line: 0,
                message: "app.json is missing or has no valid name, title, version and perms"))
        }
        let entries = files.map {
            DeviceAppFileEntry(path: $0.path, size: $0.data.count, sha256: Self.sha256Hex($0.data))
        }
        return .ok(manifest: manifest, entries: entries, digest: digester(entries))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lenient extraction for display only; closed-shape rules belong to the validator.
    static func manifest(in files: [DeviceAppFile]) -> DeviceAppManifestSummary? {
        guard let file = files.first(where: { $0.path == "app.json" }),
              let object = (try? JSONSerialization.jsonObject(with: file.data)) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty,
              let title = object["title"] as? String, !title.isEmpty,
              let version = (object["version"] as? NSNumber).map({ $0.intValue }),
              let perms = object["perms"] as? [String] else { return nil }
        return DeviceAppManifestSummary(name: name, title: title, version: version, perms: perms)
    }

    static func failureJSON(_ failure: DeviceAppValidationFailure) -> BotJSONValue {
        var fields: [String: BotJSONValue] = [
            "ok": .bool(false), "stage": .string("validation"),
            "code": .string(failure.code), "path": .string(failure.path),
            "line": .number(Double(failure.line)),
        ]
        if let message = failure.message { fields["message"] = .string(message) }
        return .object(fields)
    }

    // MARK: - DeviceAppStage

    public func stage(arguments: BotJSONValue, principal: BotGatewayPrincipal) async -> BotMCPCallResult {
        guard let device = await boundDevice(principal) else { return Self.notBound }
        guard case .object(let args) = arguments, let list = args["files"]?.arrayValue, !list.isEmpty else {
            return .failure("invalid_arguments", "DeviceAppStage 需要 files 数组")
        }
        var files: [DeviceAppFile] = []
        var seen: Set<String> = []
        for item in list {
            guard let path = item["path"]?.stringValue, let content = item["content"]?.stringValue,
                  seen.insert(path).inserted else {
                return .failure("invalid_arguments",
                                "files 的每一项需要唯一的 path 和字符串 content")
            }
            files.append(DeviceAppFile(path: path, content: content))
        }
        switch check(files) {
        case .failure(let failure):
            return .success(Self.failureJSON(failure),
                            text: "检查未通过：\(failure.code) \(failure.path):\(failure.line)")
        case .ok(let manifest, let entries, let digest):
            let record = Staged(deviceKey: device, manifest: manifest, files: files,
                                entries: entries, digest: digest)
            var list = (staged[sessionKey(principal)] ?? []).filter { $0.digest != digest }
            list.append(record)
            if list.count > Self.maxStagedPerSession { list.removeFirst(list.count - Self.maxStagedPerSession) }
            staged[sessionKey(principal)] = list
            let result: BotJSONValue = .object([
                "ok": .bool(true),
                "app": .object(["name": .string(manifest.name), "title": .string(manifest.title),
                                "version": .number(Double(manifest.version)),
                                "perms": .array(manifest.perms.map { .string($0) })]),
                "files": .array(entries.map {
                    .object(["path": .string($0.path), "size": .number(Double($0.size)),
                             "sha256": .string($0.sha256)])
                }),
                "digest": .string(digest),
                "digest_short": .string(String(digest.prefix(8))),
            ])
            return .success(result)
        }
    }

    // MARK: - DeviceAppInstall

    public func install(arguments: BotJSONValue, principal: BotGatewayPrincipal,
                        authority: BotTurnAuthority,
                        requestApproval: ApprovalRequest) async -> BotMCPCallResult {
        guard principal.kind != .verifier, principal.kind != .maintainer else {
            return .failure("permission_denied", "这个会话不能安装设备应用")
        }
        guard let device = await boundDevice(principal) else { return Self.notBound }
        guard case .object(let args) = arguments, let digest = args["digest"]?.stringValue,
              digest.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            return .failure("invalid_arguments", "DeviceAppInstall 需要 64 位小写十六进制 digest")
        }
        guard let record = staged[sessionKey(principal)]?.first(where: { $0.digest == digest }) else {
            return .failure("not_staged",
                            "这个 digest 没有在本会话中检查过（或已过期）；请重新调用 DeviceAppStage")
        }
        guard record.deviceKey == device else {
            return .failure("stale_binding", "Bot 绑定的设备已变化；请重新调用 DeviceAppStage")
        }
        // Re-run the checks: nothing reaches the approval or the radio unless
        // the bundle still passes and still hashes to the digest the model named.
        switch check(record.files) {
        case .failure(let failure):
            return .success(Self.failureJSON(failure),
                            text: "检查未通过：\(failure.code) \(failure.path):\(failure.line)")
        case .ok(_, _, let recomputed):
            guard recomputed == digest else {
                return .failure("digest_mismatch", "摘要与已检查的内容不一致，未安装")
            }
        }
        guard busyDevices.insert(device).inserted else {
            return .failure("busy", "这台设备正在安装另一个应用")
        }
        defer { busyDevices.remove(device) }

        // Approval first, before any radio use. It is spent by this install.
        let effect = DeviceAppToolEffects.installEffect(
            deviceKey: device, manifest: record.manifest, entries: record.entries, digest: digest)
        let outcome = await requestApproval(effect)
        guard outcome.allowed, let approvalID = outcome.approvalId, !approvalID.isEmpty else {
            return .failure("permission_denied", outcome.pending
                ? "审批还在等待用户确认；没有安装任何内容，用户决定后需要重新发起安装"
                : outcome.message ?? "用户没有确认安装，没有向设备发送任何内容")
        }

        let request = DeviceAppInstallRequest(
            installID: UUID().uuidString.lowercased(), deviceKey: device,
            manifest: record.manifest, files: record.files, entries: record.entries, digest: digest)
        switch await installer(request) {
        case .failed(let code, let message):
            return .failure("install_failed", "安装失败（\(code)）：\(message)")
        case .outcomeUnknown(let message):
            return .failure("outcome_unknown",
                            "安装结果未知，不要当作成功；可以让设备列出应用后确认：\(message)")
        case .installed(let installedDigest):
            guard installedDigest == digest else {
                return .failure("digest_mismatch", "设备报告的摘要与批准的不一致，不能确认安装成功")
            }
            staged[sessionKey(principal)]?.removeAll { $0.digest == digest }
            let author = BotTeammateAuthor(
                rpcId: authority.rpcId, turnId: authority.turnId, sessionId: authority.sessionId,
                origin: authority.origin, authorization: .userConfirmed, approvalID: approvalID)
            let record = DeviceAppInstallAudit(
                deviceKey: device, manifest: request.manifest, digest: digest,
                files: request.entries, author: author)
            var fields: [String: BotJSONValue] = [
                "ok": .bool(true), "installed": .bool(true), "digest": .string(digest),
                "name": .string(request.manifest.name),
            ]
            var text = "已在设备上安装「\(request.manifest.title)」（摘要 \(digest.prefix(8))）。"
            do {
                try await audit(record)
                fields["audit_recorded"] = .bool(true)
            } catch {
                fields["audit_recorded"] = .bool(false)
                text += "但安装记录没有写入成功，不要声称已留痕。"
            }
            return .success(.object(fields), text: text)
        }
    }
}
