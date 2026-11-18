// SPDX-License-Identifier: MIT

import Foundation

/// Customer-facing wording of the device-app install journey
/// (device-app.md §12, `device-app-v1.4`). The customer is not a developer: no codes,
/// digests, tool names or paths of the host. Stable machine codes stay in the result
/// fields; the sentence below goes in `message` and in the visible text, and the Bot is
/// told (authoring guide) to relay it in its own words.
public enum DeviceAppCustomerText {
    /// Said when a device program is open and how the user leaves it (real gesture:
    /// holding OK 0.7 s sends `back`; DEVICE_APP_AUTHORING.md "Keys").
    public static let exitHint = "长按确定键退出。"
    public static let unknownDevice = "你的设备"

    static let interrupted = "传输中断，设备上原来的应用没有改变。要重试吗？"
    static let notConnected = "设备没连上，请靠近设备并确认蓝牙已开"
    static let notInstallTarget = "这台设备不支持安装应用，可能需要先升级设备"
    static let generic = "安装没有成功，设备上原来的应用没有改变。要重试吗？"
    static let unresolved = "没能确认设备上有没有装好。请靠近设备并确认蓝牙已开，然后让我再装一次；装不上也不会影响设备上原来的应用。"

    /// One row per code: every device error of device-app.md §8 (including the reserved
    /// `device_not_authorized`), every installer code of the phone and the host's own.
    public static let table: [String: String] = [
        // device-app.md §8
        "bad_request": "设备没能理解这次传输，请稍后再试一次",
        "forbidden_path": "这个应用里有设备不允许的文件，我改一下再装",
        "too_large": "这个应用太大，设备放不下，我把它做小一点再装",
        "no_space": "设备空间不够，请先删掉一个设备应用",
        // phone-internal: the device answered `no_space` with an "out of memory" message (RAM, not flash).
        "no_memory": "设备现在装不下，请重启设备再试一次；设备上已有的应用都还在",
        "busy": "设备正在传输另一个应用，稍后再试",
        "bad_session": interrupted,
        "offset_mismatch": interrupted,
        "hash_mismatch": "传到设备上的内容和原来的不一致，没有安装，设备上原来的应用没有改变。要重试吗？",
        "digest_mismatch": "设备上的内容和你确认的不一致，没有安装，设备上原来的应用没有改变。要重试吗？",
        "not_found": "设备上找不到这个应用",
        "running": "设备上的应用还开着，没能替换。请在设备上长按确定键退出后再试",
        "host_only": "这一步只能由手机完成，没有改动设备",
        "declined": "设备拒绝了这次安装，设备上原来的应用没有改变",
        "device_not_authorized": "手机还没有获得在这台设备上装应用的许可，没有改动设备",
        // phone-side preflight and installer
        "device_not_found": "没找到这台设备，请到设备页面确认它还在列表里",
        "device_not_connected": notConnected,
        "device_tools_missing": notInstallTarget,
        "device_protocol_mismatch": notInstallTarget,
        "device_info_failed": "读不到设备的状态，请靠近设备并确认蓝牙已开",
        "stop_failed": "设备上的应用停不下来，请在设备上长按确定键退出后再试",
        "call_failed": interrupted,
        "transfer_interrupted": interrupted,
        "too_many_resumes": interrupted,
        "protocol": interrupted,
        "not_executed": interrupted,
        "link_busy": "设备正在传输另一个应用，稍后再试",
        "cancelled": "安装被取消了，设备上原来的应用没有改变",
        "invalid_bundle": "应用内容没有通过检查，没有安装，我改一下再装",
        "commit_not_installed": "没有装上，设备上原来的应用没有改变。要重试吗？",
        "not_installed": "没有装上，设备上原来的应用没有改变。要重试吗？",
        "outcome_unknown": unresolved,
    ]

    /// The sentence for a machine code. An unknown code gets the generic sentence, never
    /// the code itself.
    public static func sentence(forCode code: String) -> String { table[code] ?? generic }

    // MARK: - Remove and list (device-app-v1.5, spec §8.2)

    static let removeGeneric = "没能删除，设备上的应用没有改变。要重试吗？"
    static let removeBusy = "设备正忙着处理另一个应用，稍后再试"
    static let removeUnresolved = "没能确认设备上有没有删掉。请靠近设备并确认蓝牙已开，然后让我再看一下；没删掉的话也不会有别的影响。"
    static let listGeneric = "读不到设备上的应用，请靠近设备并确认蓝牙已开"
    static let notSupported = "这台设备不支持设备应用，可能需要先升级设备"

    /// Remove sentences, one per code a removal can end with. Never says 安装; an unknown code
    /// gets `removeGeneric`, never the code.
    public static let removeTable: [String: String] = [
        "device_not_found": table["device_not_found"]!,
        "device_not_connected": notConnected,
        "device_tools_missing": notSupported,
        "device_protocol_mismatch": notSupported,
        "device_info_failed": listGeneric,
        "not_found": "设备上找不到这个应用，可能已经删掉了",
        "stop_failed": table["stop_failed"]!,
        "running": table["stop_failed"]!,
        "busy": removeBusy,
        "link_busy": removeBusy,
        "bad_request": "设备没能理解这次操作，请稍后再试一次",
        "host_only": table["host_only"]!,
        "declined": "设备拒绝了这次删除，设备上的应用没有改变",
        "device_not_authorized": "手机还没有获得在这台设备上操作应用的许可，没有改动设备",
        "call_failed": removeGeneric,
        "not_executed": removeGeneric,
        "protocol": removeGeneric,
        "transfer_interrupted": removeGeneric,
        "cancelled": "删除被取消了，设备上的应用没有改变",
        "not_removed": "没有删掉，设备上的应用没有改变。要重试吗？",
        "outcome_unknown": removeUnresolved,
    ]

    public static func removeSentence(forCode code: String) -> String { removeTable[code] ?? removeGeneric }

    /// List sentences: reading the device can only fail to reach or understand it.
    public static let listTable: [String: String] = [
        "device_not_found": table["device_not_found"]!,
        "device_not_connected": notConnected,
        "device_tools_missing": notSupported,
        "device_protocol_mismatch": notSupported,
        "device_info_failed": listGeneric,
        "busy": removeBusy,
        "link_busy": removeBusy,
        "call_failed": listGeneric,
        "not_executed": listGeneric,
        "protocol": listGeneric,
    ]

    public static func listSentence(forCode code: String) -> String { listTable[code] ?? listGeneric }

    public static func removed(title: String, wasRunning: Bool) -> String {
        wasRunning ? "已把「\(title)」停掉并从设备上删除。" : "已从设备上删除「\(title)」。"
    }

    /// "设备上现在有 2 个设备应用：\n「专注计时器」（正在运行）\n「计数器」". Titles are device text,
    /// already sanitized by the caller.
    public static func listed(titles: [(title: String, running: Bool)]) -> String {
        guard !titles.isEmpty else { return "设备上现在没有设备应用。" }
        let rows = titles.map { "「\($0.title)」" + ($0.running ? "（正在运行）" : "") }
        return "设备上现在有 \(titles.count) 个设备应用：\n" + rows.joined(separator: "\n")
    }

    /// Plain reason of a §9 static-check failure, for the Bot to fix (it never reaches the customer).
    public static func validation(code: String, path: String, line: Int) -> String {
        let reason: String
        switch code {
        case "size": reason = "文件太大、太多，或缺少 main.py / app.json"
        case "lex": reason = "有语法问题（引号、括号或缩进）"
        case "fstring": reason = "用了 f-string"
        case "import": reason = "导入了不允许的模块"
        case "name": reason = "用了不允许的名字"
        case "underscore": reason = "用了不允许的下划线名字"
        case "perm": reason = "用了没有声明权限的功能"
        case "except": reason = "except 写法会吞掉用户的退出"
        case "exit_path": reason = "没有读按键，用户无法退出"
        case DeviceAppToolHost.manifestFailureCode: reason = "app.json 缺失或写法不对"
        default: reason = "没有通过检查"
        }
        let place = path.isEmpty ? "" : "（\(path)\(line > 0 ? " 第 \(line) 行" : "")）"
        return "检查没通过：\(reason)\(place)，改好后再检查一次"
    }

    /// Device permission names as the customer says them.
    public static func permission(_ perm: String) -> String {
        switch perm {
        case "audio": return "喇叭"
        case "mic": return "麦克风"
        case "battery": return "电量"
        default: return perm
        }
    }

    /// "共 2 个文件，1.7 KB" / "共 1 个文件，300 字节".
    public static func sizeLine(files: Int, bytes: Int) -> String {
        let size = bytes < 1024 ? "\(bytes) 字节" : String(format: "%.1f KB", Double(bytes) / 1024)
        return "共 \(files) 个文件，\(size)"
    }

    public static func installed(title: String, opened: Bool) -> String {
        opened
            ? "已装好「\(title)」并已在设备上打开。\(exitHint)"
            : "已装好，但没能自动打开，请在设备上选「\(title)」打开。"
    }
}
