// SPDX-License-Identifier: MIT

import Foundation

/// Tool definitions and effect declarations for the two device-app host tools.
/// The definitions are appended per caller (bound Bots only); they are not in
/// the static catalog.
public enum DeviceAppToolDefinitions {
    public static let stage = BotMCPToolDefinition(
        name: DeviceAppToolNames.stage,
        description: "Check a device app bundle without installing it. Pass files:[{path,content}] (main.py and app.json are required). Runs the static check, hashes every file and returns the file list with sizes, the bundle digest, or the first violation (code, path, line). Read-only; nothing is sent to the device. The device is the one this Bot is bound to.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("files")]),
            "properties": .object(["files": .object([
                "type": .string("array"), "minItems": .number(1), "maxItems": .number(8),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([.string("path"), .string("content")]),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "content": .object(["type": .string("string")]),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let install = BotMCPToolDefinition(
        name: DeviceAppToolNames.install,
        description: "Install the bundle you staged earlier in this session on this Bot's device. Pass the full 64-hex digest returned by DeviceAppStage. Every call asks the user to confirm on the phone, even when the user just asked for the app; a decline or expiry installs nothing. Report success only when the result says ok.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("digest")]),
            "properties": .object(["digest": .object([
                "type": .string("string"), "pattern": .string("^[0-9a-f]{64}$"),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let all = [stage, install]
}

public enum DeviceAppToolEffects {
    public static let installOperation = "device.app.install"
    public static let stageOperation = "device.app.stage"

    /// Classifier form: derived from the call arguments alone.
    public static func stageEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: DeviceAppToolNames.stage, operation: stageOperation,
                      resource: "device-app:stage", mutability: .read, policy: .auto,
                      label: "检查设备应用",
                      detail: "只做静态检查和哈希，不向设备发送任何内容。", isMcp: isMcp)
    }

    public static func classifierInstallEffect(digest: String, isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(
            tool: DeviceAppToolNames.install, operation: installOperation,
            resource: digest.isEmpty ? "device-app:install" : "device-app:install&digest=\(digest)",
            mutability: .destructive, policy: .ask,
            label: "在设备上安装应用",
            detail: "把已检查的设备应用装到绑定的设备上；每次安装都需要你确认。", isMcp: isMcp)
    }

    /// Runtime form shown on the approval card. No `grantResource`, so no
    /// standing grant is ever offered; the resource carries the full digest.
    static func installEffect(deviceKey: String, manifest: DeviceAppManifestSummary,
                              entries: [DeviceAppFileEntry], digest: String) -> BotToolEffect {
        let device = display(deviceKey, max: 80)
        let name = display(manifest.name, max: 40)
        let title = display(manifest.title, max: 40)
        let resource = "device-app:install&device=\(device)&app=\(name)&digest=\(digest)"
        let files = entries.map { "- \(display($0.path, max: 64))  \($0.size) 字节" }.joined(separator: "\n")
        let perms = manifest.perms.isEmpty
            ? "无" : manifest.perms.map { display($0, max: 16) }.joined(separator: "、")
        let detail = """
            设备：\(device)
            应用：\(title)（\(name)，版本 \(manifest.version)）
            文件：
            \(files)
            权限：\(perms)
            摘要：\(digest.prefix(8))（完整摘要已绑定到这次确认）
            程序由 Bot 编写并在设备上运行，每次安装都需要你确认。
            """
        return BotToolEffect(
            tool: DeviceAppToolNames.install, operation: installOperation,
            resource: resource, target: resource, mutability: .destructive, policy: .ask,
            label: "在设备上安装应用「\(title)」", detail: detail,
            known: true, isMcp: true)
    }

    /// Model-written text on a card: no controls, format or separator
    /// characters, collapsed spaces, clipped by scalars.
    static func display(_ value: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                out.append(" ")
            case .format:
                continue
            default:
                out.append(scalar)
            }
        }
        let collapsed = String(out).split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let scalars = Array(collapsed.unicodeScalars)
        guard scalars.count > max else { return collapsed }
        var clipped = String.UnicodeScalarView()
        clipped.append(contentsOf: scalars.prefix(max - 1))
        return String(clipped) + "…"
    }
}
