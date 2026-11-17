// SPDX-License-Identifier: MIT
//
// device-bot-v1 (spec/device/v1/device-bot.md): key space (§3), name and description templates
// (§5) and the idempotent creation decision (§6). Pure functions; the shared golden file
// spec/device/v1/golden/device-bot-binding.jsonl runs through exactly these.

import Foundation

/// §3. A key is derived once from the device class and never edited afterwards. An input that does
/// not fit its row has no key (`nil`) and creates nothing.
public enum DeviceBotKey {
    /// Link device: lowercase `device_id` as listed by `tools/list`, no prefix, no `:`.
    public static func link(deviceID: String) -> String? {
        let value = deviceID.lowercased()
        return value.isEmpty || value.contains(":") ? nil : value
    }

    /// Standard GATT: `gatt:` + lowercase CoreBluetooth peripheral UUID (8-4-4-4-12).
    public static func gatt(peripheralUUID: String) -> String? {
        let value = peripheralUUID.lowercased()
        return isUUID(value) ? "gatt:" + value : nil
    }

    /// LAN MCP: `lan:` + canonical host, plus `:<port>` unless the port is 443. A non-canonical
    /// host is rejected, not repaired.
    public static func lan(host: String, port: Int) -> String? {
        guard DeviceBotText.isCanonicalHost(host), (1...65535).contains(port) else { return nil }
        return "lan:" + host + (port == 443 ? "" : ":\(port)")
    }

    /// TonoLink board (legacy): `tonolink:` + lowercase BLE name.
    public static func tonolink(bleName: String) -> String? {
        let value = bleName.lowercased()
        return value.isEmpty ? nil : legacyTonoLinkPrefix + value
    }

    public static let legacyTonoLinkPrefix = "tonolink:"

    /// The BLE name inside a legacy key; `nil` for any other key.
    public static func tonolinkName(inKey key: String) -> String? {
        key.hasPrefix(legacyTonoLinkPrefix) ? String(key.dropFirst(legacyTonoLinkPrefix.count)) : nil
    }

    private static func isUUID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if scalar != "-" { return false }
            } else if !DeviceBotText.isLowerHex(scalar) {
                return false
            }
        }
        return true
    }
}

/// §5. Bot name and description come from fixed templates; no device-reported free text reaches
/// the description.
public enum DeviceBotText {
    public static let nameMaxScalars = 60
    public static let fallbackName = "设备助手"
    public static let boardName = "手机助手"
    public static let boardDescription =
        "通过小智 Link 帮你操作这台 iPhone：打开 App、点按、输入、看屏幕，也能调板子的灯效。对板子说「你好小智」就会找我。"

    /// Fixed GATT label order; other profile names are ignored.
    public static let gattLabels: [(profile: String, label: String)] = [
        ("battery", "电池"), ("temperature", "温度"), ("humidity", "湿度"),
        ("manufacturer", "厂商"), ("model", "型号"), ("alert", "提醒"),
    ]

    /// Steps 1-5 of §5 without the collision suffix.
    public static func sanitizedName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            let mapped: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .format: continue
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator: mapped = " "
            default: mapped = scalar
            }
            if mapped == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            scalars.append(mapped)
        }
        let kept = trimSpaces(Array(scalars)).prefix(nameMaxScalars)
        let text = trimSpaces(Array(kept))
        return text.isEmpty ? fallbackName : stringOf(text)
    }

    /// The full name: sanitized, then ` 2`, ` 3`… (smallest free number >= 2) when another Bot
    /// already has exactly that name; the base is shortened so the whole stays within 60 scalars.
    public static func name(_ raw: String, rosterNames: [String]) -> String {
        let base = sanitizedName(raw)
        let taken = Set(rosterNames.map { Array($0.unicodeScalars).map(\.value) })
        func isTaken(_ candidate: String) -> Bool { taken.contains(candidate.unicodeScalars.map(\.value)) }
        if !isTaken(base) { return base }
        let baseScalars = Array(base.unicodeScalars)
        var number = 2
        while true {
            let suffix = " \(number)"
            let room = max(0, nameMaxScalars - suffix.unicodeScalars.count)
            let candidate = stringOf(trimSpaces(Array(baseScalars.prefix(room)))) + suffix
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    public static func linkDescription(tools: [String]) -> String {
        var seen = Set<String>()
        var listed: [String] = []
        for tool in tools where isToolName(tool) && seen.insert(tool).inserted {
            listed.append(tool)
            if listed.count == 8 { break }
        }
        return "管理一台通过 Link 连接的设备。" + (listed.isEmpty ? "" : "可用工具：" + listed.joined(separator: "、") + "。")
    }

    public static func gattDescription(profiles: [String]) -> String {
        let granted = Set(profiles)
        let labels = gattLabels.filter { granted.contains($0.profile) }.map(\.label)
        return "管理一台标准蓝牙设备。" + (labels.isEmpty ? "" : "已授权：" + labels.joined(separator: "、") + "。")
    }

    public static func lanDescription(host: String) -> String {
        "管理一台局域网设备" + (isCanonicalHost(host) ? "（\(host)）" : "") + "。"
    }

    /// `^[a-z0-9_.-]{1,64}$`, strict (no trailing-newline allowance).
    public static func isToolName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy { isLowerAlnum($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    /// `^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$`, strict.
    public static func isCanonicalHost(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...253).contains(scalars.count),
              isLowerAlnum(scalars[0]), isLowerAlnum(scalars[scalars.count - 1]) else { return false }
        return scalars.allSatisfy { isLowerAlnum($0) || $0 == "." || $0 == "-" }
    }

    static func isLowerAlnum(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x30 && s.value <= 0x39)
    }

    static func isLowerHex(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x61 && s.value <= 0x66) || (s.value >= 0x30 && s.value <= 0x39)
    }

    private static func trimSpaces(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0, end = scalars.count
        while start < end, scalars[start] == " " { start += 1 }
        while end > start, scalars[end - 1] == " " { end -= 1 }
        return Array(scalars[start..<end])
    }

    private static func stringOf(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// §6 state: the two persisted maps plus the facts the decision reads.
public struct DeviceBotState: Equatable, Sendable {
    public var bindings: [String: String]
    public var intents: [String: String]
    public var roster: Set<String>
    /// creation id to Bot id, from the durable `teammate.created` rows.
    public var created: [String: String]

    public init(bindings: [String: String] = [:], intents: [String: String] = [:],
                roster: Set<String> = [], created: [String: String] = [:]) {
        self.bindings = bindings
        self.intents = intents
        self.roster = roster
        self.created = created
    }
}

public enum DeviceBotAction: Equatable, Sendable {
    case none
    case bind(bot: String)
    case create(creationID: String)
}

/// §6. Names and descriptions never identify a Bot; only the binding and the creation id do.
public enum DeviceBotBinding {
    /// Returns the action and the state to persist **before** acting (an intent is recorded
    /// before the Bot is created). Entries of unknown keys are never touched.
    public static func decide(_ state: DeviceBotState, key: String, newCreationID: String,
                              alias: String? = nil) -> (action: DeviceBotAction, state: DeviceBotState) {
        var next = state
        if let bound = next.bindings[key], next.roster.contains(bound) { return (.none, next) }
        next.bindings[key] = nil   // a stale binding is dropped first
        if let alias, let aliased = next.bindings[alias], next.roster.contains(aliased) {
            next.bindings[key] = aliased
            return (.bind(bot: aliased), next)
        }
        if let creationID = next.intents[key] {
            if let bot = next.created[creationID], next.roster.contains(bot) {
                next.bindings[key] = bot
                next.intents[key] = nil
                return (.bind(bot: bot), next)
            }
            return (.create(creationID: creationID), next)
        }
        next.intents[key] = newCreationID
        return (.create(creationID: newCreationID), next)
    }

    /// After a successful create.
    public static func complete(_ state: DeviceBotState, key: String, bot: String) -> DeviceBotState {
        var next = state
        next.bindings[key] = bot
        next.intents[key] = nil
        return next
    }
}
