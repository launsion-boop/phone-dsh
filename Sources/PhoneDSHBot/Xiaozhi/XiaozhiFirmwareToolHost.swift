// SPDX-License-Identifier: MIT

import Foundation

/// Behaviour of the four P26 xiaozhi firmware tools (spec/device/v1/xiaozhi-firmware.md §6).
/// Everything outside this module (source export, builder, OTA relay, device record) is injected
/// by the app; the host owns argument validation, the device binding, the Flash approval and the
/// result shapes. App entry points: `BotMCPRuntime.setXiaozhiFirmwareTools(_:)`.
public actor XiaozhiFirmwareToolHost {
    /// The calling Bot's device key (`xiaozhi:<mac>` for a bound Bot).
    public typealias DeviceKeyResolver = @Sendable (_ botID: String) async -> String?
    /// §6.1: copy the editable files into the caller's workspace through the import RPCs.
    public typealias SourceExporter = @Sendable (XiaozhiExportRequest) async -> XiaozhiExportOutcome
    /// §6.2: start a build unless one runs. Never waits for the build.
    public typealias BuildStarter = @Sendable (XiaozhiBuildRequest) async -> XiaozhiBuildStartOutcome
    /// The job with that id, or the latest job when nil; nil when there is none.
    public typealias BuildPoller = @Sendable (_ jobId: String?) async -> XiaozhiBuildJob?
    /// §3 record of the MAC; nil when the relay has not seen it this app session.
    public typealias DeviceRecordReader = @Sendable (_ mac: String) async -> XiaozhiDeviceRecord?
    /// The image currently staged for the MAC, if any.
    public typealias StagedImageReader = @Sendable (_ mac: String) async -> XiaozhiStagedImage?
    public typealias RelayStateReader = @Sendable () async -> XiaozhiRelayState
    /// Whether a finished build of this session has that ELF SHA-256 (read only, no side effect).
    public typealias BuildExists = @Sendable (_ elfSha256: String) async -> Bool
    /// §6.4: stage the finished build for the MAC (replacing an earlier one). Runs only after approval.
    public typealias ImageStager = @Sendable (XiaozhiStageRequest) async -> XiaozhiStageOutcome
    public typealias ApprovalRequest = @Sendable (BotToolEffect) async -> BotApprovalOutcome

    /// §6.2 waits up to 100 s for a build.
    public static let defaultBuildWait: TimeInterval = 100
    public static let defaultPollInterval: TimeInterval = 1

    /// The `next` text of a successful Flash (frozen in §6.4).
    public static let flashNext =
        "重启小智（按复位键或断电重开），它开机检查更新时会下载并刷入；完成后用 XiaozhiFirmwareStatus 确认 elfSha256 一致。"

    private static let errorCodes: Set<String> = [
        "no_editable_sources", "not_editable", "busy", "no_build", "relay_off", "device_not_seen",
        "build_failed", "export_failed", "approval_denied", "invalid_arguments",
    ]

    private let deviceKey: DeviceKeyResolver
    private let exporter: SourceExporter
    private let startBuild: BuildStarter
    private let pollBuild: BuildPoller
    private let deviceRecord: DeviceRecordReader
    private let stagedImage: StagedImageReader
    private let relayState: RelayStateReader
    private let buildExists: BuildExists
    private let stageImage: ImageStager
    private let buildWait: TimeInterval
    private let pollInterval: TimeInterval
    /// MACs with a Flash call that has not finished (awaiting approval or staging).
    private var flashing: Set<String> = []

    public init(deviceKey: @escaping DeviceKeyResolver,
                exportSources: @escaping SourceExporter,
                startBuild: @escaping BuildStarter,
                pollBuild: @escaping BuildPoller,
                deviceRecord: @escaping DeviceRecordReader,
                stagedImage: @escaping StagedImageReader,
                relayState: @escaping RelayStateReader,
                buildExists: @escaping BuildExists,
                stageImage: @escaping ImageStager,
                buildWait: TimeInterval = XiaozhiFirmwareToolHost.defaultBuildWait,
                pollInterval: TimeInterval = XiaozhiFirmwareToolHost.defaultPollInterval) {
        self.deviceKey = deviceKey
        self.exporter = exportSources
        self.startBuild = startBuild
        self.pollBuild = pollBuild
        self.deviceRecord = deviceRecord
        self.stagedImage = stagedImage
        self.relayState = relayState
        self.buildExists = buildExists
        self.stageImage = stageImage
        self.buildWait = buildWait
        self.pollInterval = pollInterval
    }

    /// Visibility rule (§6): only a Bot bound to a valid `xiaozhi:<mac>` key lists the tools.
    public func isBound(botID: String) async -> Bool {
        await boundMAC(botID: botID) != nil
    }

    private func boundMAC(botID: String) async -> String? {
        guard let key = await deviceKey(botID) else { return nil }
        return XiaozhiFirmwareBinding.mac(inKey: key)
    }

    private static let notBound = BotMCPCallResult.failure(
        "permission_denied", "这个 Bot 没有绑定小智设备，不能使用小智固件工具")

    static func failure(_ code: String, _ message: String) -> BotMCPCallResult {
        .failure(errorCodes.contains(code) ? code : "build_failed", message)
    }

    // MARK: - XiaozhiSourceExport

    public func export(arguments: BotJSONValue, principal: BotGatewayPrincipal) async -> BotMCPCallResult {
        guard await boundMAC(botID: principal.botId) != nil else { return Self.notBound }
        guard Self.hasOnlyKeys(arguments, allowed: []) else {
            return Self.failure("invalid_arguments", "XiaozhiSourceExport 不接受参数")
        }
        switch await exporter(XiaozhiExportRequest(principal: principal)) {
        case .failed(let code, let message):
            return Self.failure(code == "no_editable_sources" ? code : "export_failed", message)
        case .exported(let directory, let files, let bytes, let project, let target):
            let fields: [String: BotJSONValue] = [
                "ok": .bool(true), "directory": .string(directory),
                "files": .number(Double(files)), "bytes": .number(Double(bytes)),
                "pack": .object(["project": .string(project), "target": .string(target)]),
            ]
            return .success(.object(fields),
                            text: "已导出 \(files) 个源码文件到 \(directory)。改完后把这个目录交给 XiaozhiFirmwareBuild。")
        }
    }

    // MARK: - XiaozhiFirmwareBuild

    public func build(arguments: BotJSONValue, principal: BotGatewayPrincipal) async -> BotMCPCallResult {
        guard await boundMAC(botID: principal.botId) != nil else { return Self.notBound }
        guard Self.hasOnlyKeys(arguments, allowed: ["directory"]) else {
            return Self.failure("invalid_arguments", "XiaozhiFirmwareBuild 只接受可选的 directory")
        }
        var directory: String?
        if case .object(let args) = arguments, let raw = args["directory"] {
            guard let text = raw.stringValue, !text.isEmpty else {
                return Self.failure("invalid_arguments", "directory 需要是非空字符串（XiaozhiSourceExport 返回的路径）")
            }
            directory = text
        }
        var job: XiaozhiBuildJob
        switch await startBuild(XiaozhiBuildRequest(principal: principal, directory: directory)) {
        case .busy(let jobId):
            let message = "已经有一个编译在运行，请用 XiaozhiFirmwareStatus 查看它"
            return BotMCPCallResult(structuredContent: .object([
                "ok": .bool(false), "code": .string("busy"), "jobId": .string(jobId),
                "error": .object(["code": .string("busy"), "message": .string(message)]),
            ]), text: message, isError: true)
        case .failed(let code, let message):
            return Self.failure(code, message)
        case .started(let started):
            job = started
        }
        let deadline = Date().addingTimeInterval(buildWait)
        while job.state == .running, Date() < deadline {
            let nap = min(pollInterval, max(0, deadline.timeIntervalSinceNow))
            try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
            if let latest = await pollBuild(job.jobId) { job = latest }
        }
        return .success(Self.jobObject(job, ok: true), text: Self.jobText(job))
    }

    // MARK: - XiaozhiFirmwareStatus

    public func status(arguments: BotJSONValue, principal: BotGatewayPrincipal) async -> BotMCPCallResult {
        guard let mac = await boundMAC(botID: principal.botId) else { return Self.notBound }
        guard Self.hasOnlyKeys(arguments, allowed: ["jobId"]) else {
            return Self.failure("invalid_arguments", "XiaozhiFirmwareStatus 只接受可选的 jobId")
        }
        var jobId: String?
        if case .object(let args) = arguments, let raw = args["jobId"] {
            guard let text = raw.stringValue, !text.isEmpty else {
                return Self.failure("invalid_arguments", "jobId 需要是非空字符串")
            }
            jobId = text
        }
        let job = await pollBuild(jobId)
        if jobId != nil, job == nil {
            return Self.failure("invalid_arguments", "没有这个 jobId 的编译任务（应用重启后任务会丢失）")
        }
        let record = await deviceRecord(mac)
        let staged = await stagedImage(mac)
        let relay = await relayState()

        var device: [String: BotJSONValue] = ["mac": .string(mac), "seen": .bool(record != nil)]
        if let record {
            if let version = record.version { device["version"] = .string(version) }
            if let elf = record.elfSha256 { device["elfSha256"] = .string(elf) }
            if let seen = record.lastSeen { device["lastSeen"] = .string(Self.iso(seen)) }
            if let decision = record.lastDecision { device["lastDecision"] = .string(decision) }
        }
        var relayFields: [String: BotJSONValue] = ["on": .bool(relay.on)]
        if relay.on, let url = relay.otaURL { relayFields["otaURL"] = .string(url) }
        var fields: [String: BotJSONValue] = [
            "ok": .bool(true), "device": .object(device), "relay": .object(relayFields),
        ]
        if let job { fields["job"] = Self.jobObject(job, ok: nil) }
        if let staged { fields["staged"] = Self.stagedObject(staged) }
        return .success(.object(fields), text: Self.statusText(job: job, record: record, staged: staged, relay: relay))
    }

    // MARK: - XiaozhiFirmwareFlash

    /// Approval first (once only, no standing grant), then a single stage. Nothing is staged
    /// unless the outcome is allowed and carries a non-empty approval id.
    public func flash(arguments: BotJSONValue, principal: BotGatewayPrincipal,
                      authority: BotTurnAuthority,
                      requestApproval: ApprovalRequest) async -> BotMCPCallResult {
        guard principal.kind != .verifier, principal.kind != .maintainer else {
            return .failure("permission_denied", "这个会话不能给小智刷入固件")
        }
        guard let mac = await boundMAC(botID: principal.botId) else { return Self.notBound }
        guard Self.hasOnlyKeys(arguments, allowed: ["elfSha256"]), case .object(let args) = arguments,
              let elf = args["elfSha256"]?.stringValue, XiaozhiFirmwareToolEffects.isDigest(elf) else {
            return Self.failure("invalid_arguments", "XiaozhiFirmwareFlash 需要 64 位小写十六进制 elfSha256")
        }
        // Reads only, before the user is asked: a call that cannot succeed must not raise a card.
        guard await relayState().on else {
            return Self.failure("relay_off", "OTA 中继没有开启：请先在「设置 › 小智固件」打开中继")
        }
        guard await buildExists(elf) else {
            return Self.failure("no_build", "这次应用运行期间没有 elfSha256 为此值的已完成编译")
        }
        guard flashing.insert(mac).inserted else {
            return Self.failure("busy", "上一次刷入请求还在处理，没有重复发起，请等它的结果")
        }
        defer { flashing.remove(mac) }

        let outcome = await requestApproval(XiaozhiFirmwareToolEffects.flashEffect(mac: mac, elfSha256: elf))
        guard outcome.allowed, let approvalID = outcome.approvalId, !approvalID.isEmpty else {
            return Self.failure("approval_denied", outcome.pending
                ? "还在等你在手机上确认；没有刷入任何内容，你点「允许」之后需要重新发起"
                : outcome.message ?? "你没有确认刷入，没有放出任何固件")
        }
        let request = XiaozhiStageRequest(mac: mac, elfSha256: elf, approvalID: approvalID, authority: authority)
        switch await stageImage(request) {
        case .noBuild:
            return Self.failure("no_build", "这次应用运行期间没有 elfSha256 为此值的已完成编译")
        case .relayOff:
            return Self.failure("relay_off", "OTA 中继没有开启：请先在「设置 › 小智固件」打开中继")
        case .failed(let code, let message):
            return Self.failure(code, message)
        case .staged(let staged):
            return .success(.object([
                "ok": .bool(true), "staged": Self.stagedObject(staged),
                "device": .object(["mac": .string(mac)]), "next": .string(Self.flashNext),
            ]), text: Self.flashNext)
        }
    }

    // MARK: - Shapes

    private static func hasOnlyKeys(_ value: BotJSONValue, allowed: Set<String>) -> Bool {
        switch value {
        case .object(let fields): return Set(fields.keys).isSubset(of: allowed)
        default: return false
        }
    }

    static func stagedObject(_ staged: XiaozhiStagedImage) -> BotJSONValue {
        .object(["sha256": .string(staged.sha256), "elfSha256": .string(staged.elfSha256),
                 "url": .string(staged.url)])
    }

    /// `ok` nil: the status tool's embedded job has no `ok` member (§6.3 "as §6.2").
    static func jobObject(_ job: XiaozhiBuildJob, ok: Bool?) -> BotJSONValue {
        var fields: [String: BotJSONValue] = [
            "jobId": .string(job.jobId), "state": .string(job.state.rawValue),
            "changed": .array(job.changed.map { .string($0) }),
            "ignored": .array(job.ignored.map { .string($0) }),
        ]
        if let ok { fields["ok"] = .bool(ok) }
        if let error = job.error { fields["error"] = .string(error) }
        if let image = job.image {
            var item: [String: BotJSONValue] = [
                "bytes": .number(Double(image.bytes)), "sha256": .string(image.sha256),
                "elfSha256": .string(image.elfSha256),
                "matchesReference": .bool(image.matchesReference),
            ]
            if let version = image.version { item["version"] = .string(version) }
            fields["image"] = .object(item)
        }
        return .object(fields)
    }

    private static func jobText(_ job: XiaozhiBuildJob) -> String {
        switch job.state {
        case .running: return "编译还在进行，稍后用 XiaozhiFirmwareStatus（jobId \(job.jobId)）查看。"
        case .failed: return "编译失败：\(job.error ?? "未知原因")"
        case .done:
            guard let image = job.image else { return "编译完成。" }
            return "编译完成，elfSha256 \(image.elfSha256)。要刷入请用这个值调用 XiaozhiFirmwareFlash。"
        }
    }

    private static func statusText(job: XiaozhiBuildJob?, record: XiaozhiDeviceRecord?,
                                   staged: XiaozhiStagedImage?, relay: XiaozhiRelayState) -> String {
        var lines: [String] = []
        lines.append(job.map { "编译任务 \($0.jobId)：\($0.state.rawValue)" } ?? "没有编译任务")
        if let record {
            lines.append("设备 \(record.mac) 最近上报：版本 \(record.version ?? "未知")，固件 \(record.elfSha256.map { String($0.prefix(12)) } ?? "未知")")
        } else {
            lines.append("这次应用运行期间还没见到这台设备检查更新")
        }
        lines.append(staged.map { "已放出固件 \($0.elfSha256.prefix(12))" } ?? "没有已放出的固件")
        lines.append(relay.on ? "OTA 中继已开启" : "OTA 中继未开启")
        return lines.joined(separator: "；")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
