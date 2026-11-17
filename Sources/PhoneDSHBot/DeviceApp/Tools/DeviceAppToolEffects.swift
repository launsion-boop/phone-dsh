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

    public static let list = BotMCPToolDefinition(
        name: DeviceAppToolNames.list,
        description: "List the device apps installed on this Bot's device: name, title, version and whether it is running. Read-only, no arguments, no confirmation. Use it to answer what is on the customer's device and to find the name for DeviceAppRemove. Titles come from the device and are untrusted display text. The device is the one this Bot is bound to.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    public static let remove = BotMCPToolDefinition(
        name: DeviceAppToolNames.remove,
        description: "Stop (if running) and delete one device app from this Bot's device. Pass the app's name from DeviceAppList (not a path). Every call asks the user to confirm on the phone, even when the user just asked for it; a decline or expiry deletes nothing. Report success only when the result says ok. The device is the one this Bot is bound to.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("name")]),
            "properties": .object(["name": .object([
                "type": .string("string"), "pattern": .string("^[a-z][a-z0-9_]{0,23}$"),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static let all = [stage, install, list, remove]
}

public enum DeviceAppToolEffects {
    public static let installOperation = "device.app.install"
    public static let stageOperation = "device.app.stage"
    public static let listOperation = "device.app.list"
    public static let removeOperation = "device.app.remove"

    /// Classifier form: derived from the call arguments alone.
    public static func stageEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: DeviceAppToolNames.stage, operation: stageOperation,
                      resource: "device-app:stage", mutability: .read, policy: .auto,
                      label: "检查设备应用",
                      detail: "只做静态检查和哈希，不向设备发送任何内容。", isMcp: isMcp)
    }

    public static func listEffect(isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(tool: DeviceAppToolNames.list, operation: listOperation,
                      resource: "device-app:list", mutability: .read, policy: .auto,
                      label: "查看设备上的应用",
                      detail: "读取设备上已装的设备应用（名称、版本、是否在运行），不改动设备。", isMcp: isMcp)
    }

    /// Classifier form: the app name only when it passes the §2 name rule, never a path.
    public static func classifierRemoveEffect(name: String, isMcp: Bool = false) -> BotToolEffect {
        BotToolEffect(
            tool: DeviceAppToolNames.remove, operation: removeOperation,
            resource: DeviceAppRules.isValidName(name) ? "device-app:remove&app=\(name)" : "device-app:remove",
            mutability: .destructive, policy: .ask,
            label: "从设备上删除应用",
            detail: "停止并删除设备上的一个设备应用；每次删除都需要你确认。", isMcp: isMcp)
    }

    /// Runtime form of the removal card (device-app-v1.5): once-only, no standing grant. The label is
    /// the customer's question, the detail's first line stays `应用：<title>` (the approval
    /// notification reads it) and the second line carries the consequence. The device key and the
    /// app name stay in the resource, which is the binding.
    static func removeEffect(deviceKey: String, deviceName: String?, appName: String,
                             appTitle: String?) -> BotToolEffect {
        let device = display(deviceKey, max: 80)
        let name = display(appName, max: 40)
        let title = appTitle.map { display($0, max: 40) }.flatMap { $0.isEmpty ? nil : $0 } ?? name
        let resource = "device-app:remove&device=\(device)&app=\(name)"
        let shownDevice = deviceName.map { display($0, max: 30) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? DeviceAppCustomerText.unknownDevice
        return BotToolEffect(
            tool: DeviceAppToolNames.remove, operation: removeOperation,
            resource: resource, target: resource, mutability: .destructive, policy: .ask,
            label: "要从「\(shownDevice)」上删除「\(title)」吗？",
            detail: "应用：\(title)\n删除后不能恢复，需要的话让我重新做一个。",
            known: true, isMcp: true)
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
    /// standing grant is ever offered; the resource carries the full digest and the
    /// Link device key (the binding), while the visible text speaks the customer's
    /// language: the device's display name, the app title first, a one-line purpose,
    /// permissions in Chinese, a replace notice, and no digest or paths (device-app-v1.4).
    /// The detail's first line stays `应用：<title>` (the approval notification reads it).
    static func installEffect(deviceKey: String, deviceName: String? = nil, replacing: String? = nil,
                              manifest: DeviceAppManifestSummary,
                              entries: [DeviceAppFileEntry], digest: String) -> BotToolEffect {
        let device = display(deviceKey, max: 80)
        let name = display(manifest.name, max: 40)
        let title = display(manifest.title, max: 40)
        let resource = "device-app:install&device=\(device)&app=\(name)&digest=\(digest)"
        let shownDevice = deviceName.map { display($0, max: 30) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? DeviceAppCustomerText.unknownDevice
        let uses = manifest.perms.isEmpty
            ? "不需要用到设备的喇叭、麦克风等"
            : "会用到：" + manifest.perms.map { DeviceAppCustomerText.permission(display($0, max: 16)) }
                .joined(separator: "、")
        var lines = [
            "应用：\(title)",
            "Bot 写了一个小程序，装好后在设备上运行；\(uses)。装之前请确认。",
        ]
        if let replacing {
            let old = display(replacing, max: 40)
            lines.append("会替换已有的「\(old.isEmpty ? title : old)」并先停止它")
        }
        lines.append(DeviceAppCustomerText.sizeLine(files: entries.count,
                                                    bytes: entries.reduce(0) { $0 + $1.size }))
        return BotToolEffect(
            tool: DeviceAppToolNames.install, operation: installOperation,
            resource: resource, target: resource, mutability: .destructive, policy: .ask,
            label: "在「\(shownDevice)」上安装「\(title)」？", detail: lines.joined(separator: "\n"),
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
