// SPDX-License-Identifier: MIT

import Foundation

public enum OfficeLimits {
    public static let maximumJSONBytes = 256 * 1024
    public static let maximumImportBytes = 512 * 1024 * 1024
    public static let copyChunkBytes = 1024 * 1024
    public static let maximumPageItems = 50
}

public struct OfficeArtifactRef: Codable, Equatable, Sendable {
    public let artifactID: String
    public let version: Int
    public let sha256: String
    public let mediaType: String
    public let byteCount: Int
    public let name: String

    public init(artifactID: String, version: Int = 1, sha256: String,
                mediaType: String, byteCount: Int, name: String) {
        self.artifactID = artifactID
        self.version = version
        self.sha256 = sha256
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.name = name
    }
}

public struct OfficeArtifactPage: Codable, Equatable, Sendable {
    public let items: [OfficeArtifactRef]
    public let nextCursor: Int?
    public let total: Int
}

public enum OfficeToolError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case unknownTool(String)
    case unknownArtifact(String)
    case invalidRange(String)
    case unsupported(String)
    case unavailable(String)
    case resultTooLarge
    case cancelled
}

extension OfficeToolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): return "参数无效：\(detail)"
        case .unknownTool(let name): return "不支持的工具：\(name)"
        case .unknownArtifact(let id): return "未找到文件：\(id)"
        case .invalidRange(let detail): return "读取范围无效：\(detail)"
        case .unsupported(let detail): return "当前不支持：\(detail)"
        case .unavailable(let detail): return "能力不可用：\(detail)"
        case .resultTooLarge: return "返回内容超过 256 KiB，请缩小范围或使用 cursor"
        case .cancelled: return "操作已取消"
        }
    }
}

public enum OfficeJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw OfficeToolError.invalidArguments("需要 JSON object")
        }
        return object
    }

    public static func string(_ object: [String: Any], _ key: String, required: Bool = true) throws -> String? {
        guard let value = object[key] else {
            if required { throw OfficeToolError.invalidArguments("缺少 \(key)") }
            return nil
        }
        guard let text = value as? String, !text.isEmpty else {
            throw OfficeToolError.invalidArguments("\(key) 必须是非空字符串")
        }
        return text
    }

    public static func int(_ object: [String: Any], _ key: String,
                           default defaultValue: Int? = nil,
                           minimum: Int = 0, maximum: Int = Int.max) throws -> Int {
        guard let value = object[key] else {
            if let defaultValue { return defaultValue }
            throw OfficeToolError.invalidArguments("缺少 \(key)")
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else {
            throw OfficeToolError.invalidArguments("\(key) 必须是整数")
        }
        let result = number.intValue
        guard result >= minimum, result <= maximum else {
            throw OfficeToolError.invalidArguments("\(key) 超出 \(minimum)...\(maximum)")
        }
        return result
    }

    public static func data(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw OfficeToolError.invalidArguments("结果不是有效 JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= OfficeLimits.maximumJSONBytes else { throw OfficeToolError.resultTooLarge }
        return data
    }

    public static func string(_ value: Any) throws -> String {
        let data = try self.data(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OfficeToolError.unavailable("结果不是 UTF-8")
        }
        return text
    }
}
