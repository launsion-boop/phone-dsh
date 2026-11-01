// SPDX-License-Identifier: MIT

import Foundation
import UIKit

public enum PhoneToolError: Error, Sendable {
    case invalidArguments(String)
    case permissionRequired(PhoneCapability)
    case permissionDenied(PhoneCapability)
    case capabilityDisabled(PhoneCapability)
    case unavailable(PhoneCapability?, String)
    case unknownTool(String)
    case resultTooLarge
    case noData(String)
    case cancelled
}

public enum PhoneToolEnvelope {
    public static let maximumBytes = 256 * 1024

    public static func success(tool: String, scope: String, data: [String: Any],
                               egress: Bool = true, nextCursor: Any = NSNull(),
                               truncated: Bool = false) throws -> String {
        try string([
            "ok": true,
            "tool": tool,
            "egress": egress ? "model" : "none",
            "scope": scope,
            "data": data,
            "nextCursor": nextCursor,
            "truncated": truncated,
        ])
    }

    public static func failure(tool: String, error: PhoneToolError) throws -> String {
        let code: String
        let message: String
        let capability: PhoneCapability?
        var settingsURL: Any = NSNull()
        var retryable = false
        switch error {
        case .invalidArguments(let detail):
            code = "invalid_arguments"
            message = "参数无效：\(detail)"
            capability = nil
        case .permissionRequired(let value):
            code = "permission_required"
            message = "请先在手机权限中心明确授权\(value.title)"
            capability = value
        case .permissionDenied(let value):
            code = "permission_denied"
            message = "\(value.title)权限已拒绝或受系统限制，请前往系统设置处理"
            capability = value
            settingsURL = UIApplication.openSettingsURLString
        case .capabilityDisabled(let value):
            code = "capability_disabled"
            message = "\(value.title)的应用内开关已关闭"
            capability = value
        case .unavailable(let value, let detail):
            code = "unavailable"
            message = detail
            capability = value
        case .unknownTool(let name):
            code = "unknown_tool"
            message = "不支持的工具：\(name)"
            capability = nil
        case .resultTooLarge:
            code = "result_too_large"
            message = "返回内容超过 256 KiB，请缩小范围或减少 limit"
            capability = nil
            retryable = true
        case .noData(let detail):
            code = "no_data"
            message = detail
            capability = nil
        case .cancelled:
            code = "cancelled"
            message = "操作已取消"
            capability = nil
        }
        return try string([
            "ok": false,
            "tool": tool,
            "error": [
                "code": code,
                "message": message,
                "capability": capability.map { $0.rawValue as Any } ?? NSNull(),
                "settings_url": settingsURL,
                "retryable": retryable,
            ],
        ])
    }

    public static func string(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw PhoneToolError.invalidArguments("结果不是有效 JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumBytes else { throw PhoneToolError.resultTooLarge }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PhoneToolError.unavailable(nil, "结果不是 UTF-8")
        }
        return text
    }

    public static func object(_ arguments: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw PhoneToolError.invalidArguments("需要 JSON object")
        }
        return value
    }

    public static func text(_ object: [String: Any], _ key: String,
                            required: Bool = true, limit: Int = 4000) throws -> String? {
        guard let value = object[key] else {
            if required { throw PhoneToolError.invalidArguments("缺少 \(key)") }
            return nil
        }
        guard let text = value as? String, !text.isEmpty, text.count <= limit else {
            throw PhoneToolError.invalidArguments("\(key) 必须是 1...\(limit) 字符的字符串")
        }
        return text
    }

    public static func integer(_ object: [String: Any], _ key: String,
                               default defaultValue: Int? = nil,
                               minimum: Int = 0, maximum: Int = 100) throws -> Int {
        guard let value = object[key] else {
            if let defaultValue { return defaultValue }
            throw PhoneToolError.invalidArguments("缺少 \(key)")
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else {
            throw PhoneToolError.invalidArguments("\(key) 必须是整数")
        }
        let result = number.intValue
        guard result >= minimum, result <= maximum else {
            throw PhoneToolError.invalidArguments("\(key) 超出 \(minimum)...\(maximum)")
        }
        return result
    }

    public static func flag(_ object: [String: Any], _ key: String,
                            default defaultValue: Bool = false) throws -> Bool {
        guard let value = object[key] else { return defaultValue }
        guard let flag = value as? Bool else {
            throw PhoneToolError.invalidArguments("\(key) 必须是布尔值")
        }
        return flag
    }

    public static func requireConfirmation(_ object: [String: Any]) throws {
        guard try flag(object, "confirmed") else {
            throw PhoneToolError.invalidArguments("写操作必须显式 confirmed=true")
        }
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(_ object: [String: Any], _ key: String, alias: String? = nil,
                            default defaultValue: Date? = nil) throws -> Date {
        let selectedKey = object[key] == nil && alias != nil && object[alias!] != nil ? alias! : key
        if object[selectedKey] == nil, let defaultValue { return defaultValue }
        guard let text = try text(object, selectedKey, limit: 64) else {
            throw PhoneToolError.invalidArguments("缺少 \(selectedKey)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withFraction = formatter.date(from: text)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = withFraction ?? formatter.date(from: text) else {
            throw PhoneToolError.invalidArguments("\(key) 需要带时区的 ISO8601")
        }
        return date
    }
}
