// SPDX-License-Identifier: MIT

import Foundation

/// Tool definitions of `xiaozhi-firmware-v1`. Names, descriptions and input schemas are frozen in
/// the `xiaozhiFirmware` section of spec/bot/v1/golden/tool-catalog.phone.json; the tests compare
/// them with that file. They are listed per caller for a `xiaozhi:`-bound Bot only, never in the
/// static catalog.
public enum XiaozhiFirmwareToolDefinitions {
    public static let export = BotMCPToolDefinition(
        name: XiaozhiFirmwareToolNames.export,
        description: "Copy the xiaozhi firmware sources you may edit into your workspace. Returns the directory (an absolute workspace path) and the file count. Edit files there, then pass the directory to XiaozhiFirmwareBuild. Only existing files can be changed; new or deleted files are not built.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    public static let build = BotMCPToolDefinition(
        name: XiaozhiFirmwareToolNames.build,
        description: "Build the xiaozhi firmware on this iPhone (about a minute). Pass directory (from XiaozhiSourceExport) to build your edits; omit it for the unmodified reference build. Waits up to 100 s; if state is running, call XiaozhiFirmwareStatus with the jobId. A finished build returns the image's elfSha256 for XiaozhiFirmwareFlash.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["directory": .object([
                "type": .string("string"), "minLength": .number(1),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let status = BotMCPToolDefinition(
        name: XiaozhiFirmwareToolNames.status,
        description: "Show a firmware build job (the latest when jobId is omitted), what the bound xiaozhi board last reported (version, running elfSha256, last OTA check), the staged image and whether the OTA relay is on.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["jobId": .object([
                "type": .string("string"), "minLength": .number(1),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let flash = BotMCPToolDefinition(
        name: XiaozhiFirmwareToolNames.flash,
        description: "Flash a firmware built in this app session onto the bound xiaozhi board over Wi-Fi. Pass elfSha256 from XiaozhiFirmwareBuild. Asks the user first. Stages the image on the phone's OTA relay; the board installs it at its next boot, so tell the user to restart the board, then confirm with XiaozhiFirmwareStatus.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("elfSha256")]),
            "properties": .object(["elfSha256": .object([
                "type": .string("string"), "pattern": .string("^[0-9a-f]{64}$"),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let all = [export, build, status, flash]
}

/// Effect classification of the four tools (spec/bot/v1/golden/tool-effects.phone.json).
public enum XiaozhiFirmwareToolEffects {
    public static let exportOperation = "device.xiaozhi.export"
    public static let buildOperation = "device.xiaozhi.build"
    public static let statusOperation = "device.xiaozhi.status"
    public static let flashOperation = "device.xiaozhi.flash"

    public static let flashLabel = "给小智刷入固件"
    public static let flashConsequence =
        "把这次编译的固件放到手机的 OTA 中继上，小智下次开机检查更新时会下载并刷入，替换它现在的固件。"

    public static func exportEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: XiaozhiFirmwareToolNames.export, operation: exportOperation,
                      resource: "xiaozhi:export", mutability: .write, policy: .auto,
                      label: "导出小智固件源码",
                      detail: "把可修改的固件源码复制到这个 Bot 的工作区，不向设备发送任何内容。", isMcp: isMcp)
    }

    public static func buildEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: XiaozhiFirmwareToolNames.build, operation: buildOperation,
                      resource: "xiaozhi:build", mutability: .read, policy: .auto,
                      label: "编译小智固件",
                      detail: "在这台 iPhone 上编译固件，不向设备发送任何内容。", isMcp: isMcp)
    }

    public static func statusEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: XiaozhiFirmwareToolNames.status, operation: statusOperation,
                      resource: "xiaozhi:status", mutability: .read, policy: .auto,
                      label: "查看小智固件状态",
                      detail: "只读取编译任务、设备上报和中继状态。", isMcp: isMcp)
    }

    /// Classifier form: derived from the call arguments alone. The ELF digest enters the
    /// resource only when it is 64 lowercase hex; anything else gives the bare resource.
    public static func classifierFlashEffect(elfSha256: String, isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(
            tool: XiaozhiFirmwareToolNames.flash, operation: flashOperation,
            resource: isDigest(elfSha256) ? "xiaozhi:flash&elf=\(elfSha256)" : "xiaozhi:flash",
            mutability: .destructive, policy: .ask, label: flashLabel,
            detail: flashConsequence, isMcp: isMcp)
    }

    /// Runtime form shown on the once-only approval card. No `grantResource`: no standing grant is
    /// ever offered. The resource carries the full ELF digest (the binding); the visible detail
    /// names the MAC and the first 12 hex of the digest.
    static func flashEffect(mac: String, elfSha256: String) -> BotToolEffect {
        let resource = "xiaozhi:flash&elf=\(elfSha256)"
        let detail = "设备：\(mac)\n固件：\(elfSha256.prefix(12))\n\(flashConsequence)"
        return BotToolEffect(
            tool: XiaozhiFirmwareToolNames.flash, operation: flashOperation,
            resource: resource, target: resource, mutability: .destructive, policy: .ask,
            label: flashLabel, detail: detail, known: true, isMcp: true)
    }

    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
