// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

extension JSONValue {
    var fields: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var text: String? { if case .string(let value) = self { return value }; return nil }
}

enum ADBTools {
    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
    static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:],
                     required: [String] = []) -> JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
        ])])
    }
    static let coordinate = property("integer", "Pixel coordinate in the latest Android screenshot, from 0 to 32767.")
    static let descriptors: [JSONValue] = [
        tool("android_connect", "Enable Android control, save the TCP/IP ADB target and check its connection directly from iPhone. Use this when the user supplies an address or control is disabled; no Settings visit is required. Android must accept this iPhone debugging key.",
             ["host": property("string", "Android IP address or hostname, without adb prefix or port."),
              "port": property("integer", "TCP/IP ADB port, 1–65535; default 5555. Pairing-code/TLS ports are unsupported.")], required: ["host"]),
        tool("android_status", "Check the Android device configured in iPhone Settings; returns model, Android release and screen size."),
        tool("android_screenshot", "Capture the configured Android screen as a PNG image. Inspect it before choosing tap/swipe pixel coordinates."),
        tool("android_tap", "Tap the Android screen at pixel coordinates from a recent screenshot.", ["x": coordinate, "y": coordinate], required: ["x", "y"]),
        tool("android_swipe", "Swipe or long-press (same start/end) on Android. Coordinates are screenshot pixels.",
             ["x": coordinate, "y": coordinate, "endX": coordinate, "endY": coordinate,
              "durationMs": property("integer", "Gesture duration 1–10000 ms; default 300.")], required: ["x", "y", "endX", "endY"]),
        tool("android_input_text", "Type printable ASCII text into the focused Android field. Unicode requires a device IME and is rejected, not silently lost.",
             ["text": property("string", "Printable ASCII text, at most 1000 characters. Literal %s is unsupported by Android input.")], required: ["text"]),
        tool("android_key", "Press an Android key: HOME, BACK, ENTER, APP_SWITCH, DEL, POWER, VOLUME_UP, VOLUME_DOWN, WAKEUP, or a numeric key code.",
             ["key": property("string", "Android key name or decimal code 0–400.")], required: ["key"]),
        tool("android_launch_app", "Open the launcher activity of an installed Android package.",
             ["packageName": property("string", "Application package ID, e.g. com.android.settings.")], required: ["packageName"]),
        tool("android_ui_dump", "Read Android's UI hierarchy XML for accessible text and element bounds. Some apps expose limited content."),
        tool("android_shell", "Run a shell command on the configured Android device as the ADB shell user. It can change device state. No automatic retries; after timeout/disconnect inspect state before repeating.",
             ["command": property("string", "Android shell command, under 3800 UTF-8 bytes; this is not the iPhone workspace shell."),
              "timeoutMs": property("integer", "Wall-clock timeout from 100 to 120000 ms; default 30000.")], required: ["command"]),
    ] + ADBPackageTools.descriptors

    /// W5 runtime tiering (spec/bot/v1 §2, PC-20261112-w5). Only the entry
    /// point that enables Android control stays visible before a target is
    /// configured; every other Android tool is listed only while the saved
    /// configuration is enabled. Without `android_connect` the model could
    /// never establish the connection that makes the rest visible.
    static let coreNames: Set<String> = ["android_connect"]

    static var coreDescriptors: [JSONValue] {
        descriptors.filter { coreNames.contains($0.fields["name"]?.text ?? "") }
    }

    /// A real connection state change (saved target / enabled flag) is the only
    /// input. The list is recomputed per `tools/list`, so the next request
    /// after a change already reflects it and an unchanged state cannot churn
    /// the upstream request sequence.
    static func descriptors(configured: Bool) -> [JSONValue] {
        configured ? Self.descriptors : coreDescriptors
    }

    struct Plan: Sendable {
        var command: String
        var connection: ADBConfiguration?
        var timeout: TimeInterval = 30
        var image = false
        var workspaceAPK: String?
        var sha256: String?
        var requiresSuccess = false
        var outputLimit: Int { image ? 8 * 1024 * 1024 : 256 * 1024 }
    }

    static func plan(name: String, arguments: JSONValue) throws -> Plan {
        guard case .object(let args) = arguments,
              let descriptor = descriptors.first(where: { $0.fields["name"]?.text == name }) else {
            throw ADBFailure("Unknown Android tool or invalid arguments")
        }
        let properties = descriptor.fields["inputSchema"]!.fields["properties"]!.fields
        guard Set(args.keys).isSubset(of: Set(properties.keys)) else { throw ADBFailure("Unknown Android tool argument") }
        func text(_ key: String) throws -> String {
            guard let value = args[key]?.text, !value.isEmpty, !value.utf8.contains(0) else { throw ADBFailure("\(key) must be a nonempty string without NUL") }
            return value
        }
        func integer(_ key: String, range: ClosedRange<Int>, fallback: Int? = nil) throws -> Int {
            if args[key] == nil, let fallback { return fallback }
            guard case .number(let number) = args[key], number.isFinite,
                  number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound)
            else { throw ADBFailure("\(key) must be an integer in \(range)") }
            return Int(number)
        }
        switch name {
        case "android_connect":
            let endpoint = try ADBEndpoint(host: text("host"), port: UInt16(integer("port", range: 1...65535, fallback: 5555)))
            return Plan(command: "getprop ro.product.model; getprop ro.build.version.release; wm size",
                        connection: ADBConfiguration(enabled: true, host: endpoint.host, port: endpoint.port))
        case "android_status": return Plan(command: "getprop ro.product.model; getprop ro.build.version.release; wm size")
        case "android_screenshot": return Plan(command: "screencap -p", image: true)
        case "android_ui_dump":
            // shell_v2 raw has no controlling terminal. Use a unique shell-owned
            // temporary file; /dev/tty would fail on otherwise valid devices.
            return Plan(command: "p=$(mktemp /data/local/tmp/phone-dsh-ui.XXXXXX) || exit 1; trap 'rm -f \"$p\"' EXIT; uiautomator dump \"$p\" >/dev/null && cat \"$p\"")
        case "android_tap": return Plan(command: "input tap \(try integer("x", range: 0...32767)) \(try integer("y", range: 0...32767))")
        case "android_swipe":
            return Plan(command: "input swipe \(try integer("x", range: 0...32767)) \(try integer("y", range: 0...32767)) \(try integer("endX", range: 0...32767)) \(try integer("endY", range: 0...32767)) \(try integer("durationMs", range: 1...10000, fallback: 300))")
        case "android_input_text":
            let value = try text("text")
            guard value.utf8.count <= 1000, value.utf8.allSatisfy({ (32...126).contains($0) }), !value.contains("%s") else {
                throw ADBFailure("Android input text supports printable ASCII only (1000 characters max, no literal %s); Unicode needs a device IME")
            }
            return Plan(command: "input text " + quote(value.replacingOccurrences(of: " ", with: "%s")))
        case "android_key":
            let key = try text("key").uppercased().replacingOccurrences(of: "KEYCODE_", with: "")
            let known = ["HOME", "BACK", "ENTER", "APP_SWITCH", "DEL", "POWER", "VOLUME_UP", "VOLUME_DOWN", "WAKEUP"]
            guard known.contains(key) || (key.allSatisfy(\.isNumber) && Int(key).map { (0...400).contains($0) } == true) else {
                throw ADBFailure("Unsupported Android key")
            }
            return Plan(command: "input keyevent " + (known.contains(key) ? "KEYCODE_" + key : key))
        case "android_launch_app":
            let package = try text("packageName")
            guard package.count <= 255, package.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil else {
                throw ADBFailure("Invalid Android package name")
            }
            return Plan(command: "monkey -p \(quote(package)) -c android.intent.category.LAUNCHER 1")
        case "android_shell":
            let command = try text("command")
            guard command.utf8.count < 3800 else { throw ADBFailure("Android command is too long") }
            return Plan(command: command, timeout: Double(try integer("timeoutMs", range: 100...120000, fallback: 30000)) / 1000)
        default: return try ADBPackageTools.plan(name: name, args: args)
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func textResult(_ message: String, error: Bool = false) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(error)])
    }
    static func result(_ result: ADBShellResult, plan: Plan) throws -> JSONValue {
        if plan.image && result.exitCode == 0 {
            guard result.stdout.count >= 24, result.stdout.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ADBFailure("Android screenshot did not return a PNG image")
            }
            return .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"),
                                                       "data": .string(result.stdout.base64EncodedString())])]), "isError": .bool(false)])
        }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        // Some vendor pm wrappers print Failure while returning zero. Never
        // report an installation/uninstallation as successful without its ack.
        let success = stdout.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "Success" }
        let failed = result.exitCode != 0 || (plan.requiresSuccess && (!success || stdout.contains("Failure") || stderr.contains("Failure")))
        return textResult("exitCode: \(result.exitCode)\n" + stdout
                          + (stderr.isEmpty ? "" : "\nstderr:\n" + stderr)
                          + (plan.requiresSuccess && !success ? "\nPackage manager did not confirm Success; inspect device state." : ""), error: failed)
    }
}
