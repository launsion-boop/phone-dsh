// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Daily Brief domain values.

import CryptoKit
import Foundation

public enum DailyBriefLimits {
    public static let schemaVersion = 1
    public static let maximumFeedBytes = 2 * 1024 * 1024
    public static let maximumSources = 50
    public static let maximumItems = 500
    public static let maximumStateBytes = 1024 * 1024
    public static let summaryCharacters = 280
}

public enum DailyBriefCostSource: String, Codable, Equatable, Sendable {
    case actual
    case estimate
    case unavailable
}

public enum DailyBriefError: Error, Equatable, Sendable {
    case invalidSource(String)
    case invalidFeed(String)
    case responseTooLarge
    case httpStatus(Int)
    case invalidResponse
    case noEnabledSources
    case persistence(String)
}

extension DailyBriefError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSource(let detail): return "来源地址不可用：\(detail)"
        case .invalidFeed(let detail): return "订阅内容无法解析：\(detail)"
        case .responseTooLarge: return "订阅响应超过 2 MiB 上限"
        case .httpStatus(let status): return "订阅服务返回 HTTP \(status)"
        case .invalidResponse: return "订阅服务返回了无效响应"
        case .noEnabledSources: return "先添加并启用一个资讯来源"
        case .persistence(let detail): return "本地简报数据无法保存：\(detail)"
        }
    }
}

public struct DailyBriefSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var isEnabled: Bool
    public var eTag: String?
    public var lastModified: String?

    public init(id: String = UUID().uuidString, name: String, url: URL,
                isEnabled: Bool = true, eTag: String? = nil, lastModified: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.eTag = eTag
        self.lastModified = lastModified
    }
}

public struct DailyBriefItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceID: String
    public var sourceName: String
    public var title: String
    public var summary: String
    public var link: URL?
    public var publishedAt: Date?

    public init(id: String, sourceID: String, sourceName: String,
                title: String, summary: String, link: URL?, publishedAt: Date?) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.title = title
        self.summary = summary
        self.link = link
        self.publishedAt = publishedAt
    }
}

public struct DailyBriefSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var createdAt: Date
    public var items: [DailyBriefItem]
    public var sourceCursors: [String: String]

    public init(schemaVersion: Int = DailyBriefLimits.schemaVersion,
                id: String, createdAt: Date, items: [DailyBriefItem],
                sourceCursors: [String: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.items = items
        self.sourceCursors = sourceCursors
    }

    public var shareText: String {
        var lines = ["每日简报", "更新于 \(DailyBriefDates.iso8601.string(from: createdAt))", ""]
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). \(item.title)")
            lines.append(item.sourceName)
            if let publishedAt = item.publishedAt {
                lines.append("发布时间 \(DailyBriefDates.iso8601.string(from: publishedAt))")
            }
            if !item.summary.isEmpty { lines.append(item.summary) }
            if let link = item.link { lines.append(link.absoluteString) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

public struct DailyBriefSourceIssue: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceName: String
    public var message: String

    public init(sourceID: String, sourceName: String, message: String) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.message = message
    }
}

public struct DailyBriefRefreshReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var startedAt: Date
    public var finishedAt: Date
    public var itemCount: Int
    public var newItemCount: Int
    public var networkBytes: Int
    public var sourceIssues: [DailyBriefSourceIssue]
    public var costSource: DailyBriefCostSource

    public init(schemaVersion: Int = DailyBriefLimits.schemaVersion,
                startedAt: Date, finishedAt: Date, itemCount: Int, newItemCount: Int,
                networkBytes: Int, sourceIssues: [DailyBriefSourceIssue],
                costSource: DailyBriefCostSource) {
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.itemCount = itemCount
        self.newItemCount = newItemCount
        self.networkBytes = networkBytes
        self.sourceIssues = sourceIssues
        self.costSource = costSource
    }
}

public struct DailyBriefPersistedState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sources: [DailyBriefSource]
    public var snapshot: DailyBriefSnapshot?
    public var lastReport: DailyBriefRefreshReport?

    public init(schemaVersion: Int = DailyBriefLimits.schemaVersion,
                sources: [DailyBriefSource] = [], snapshot: DailyBriefSnapshot? = nil,
                lastReport: DailyBriefRefreshReport? = nil) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.snapshot = snapshot
        self.lastReport = lastReport
    }
}

public struct DailyBriefTransportResponse: Equatable, Sendable {
    public var data: Data
    public var notModified: Bool
    public var eTag: String?
    public var lastModified: String?

    public init(data: Data, notModified: Bool = false,
                eTag: String? = nil, lastModified: String? = nil) {
        self.data = data
        self.notModified = notModified
        self.eTag = eTag
        self.lastModified = lastModified
    }

    public static var notModified: DailyBriefTransportResponse {
        DailyBriefTransportResponse(data: Data(), notModified: true)
    }
}

public protocol DailyBriefTransport: Sendable {
    func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse
}

public struct DailyBriefRefreshOutcome: Equatable, Sendable {
    public var sources: [DailyBriefSource]
    public var snapshotToPublish: DailyBriefSnapshot?
    public var currentSnapshot: DailyBriefSnapshot?
    public var report: DailyBriefRefreshReport

    public init(sources: [DailyBriefSource], snapshotToPublish: DailyBriefSnapshot?,
                currentSnapshot: DailyBriefSnapshot?, report: DailyBriefRefreshReport) {
        self.sources = sources
        self.snapshotToPublish = snapshotToPublish
        self.currentSnapshot = currentSnapshot
        self.report = report
    }
}

public enum DailyBriefDates {
    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

public enum DailyBriefIDs {
    public static func item(sourceID: String, guid: String?, link: URL?,
                            title: String, publishedAt: Date?) -> String {
        let identity: String
        if let guid, !guid.isEmpty {
            identity = "guid:\(guid)"
        } else if let link {
            identity = "link:\(link.absoluteString)"
        } else {
            let date = publishedAt.map { DailyBriefDates.iso8601.string(from: $0) } ?? "undated"
            identity = "title:\(title)|date:\(date)"
        }
        return digest("item\u{0}\(sourceID)\u{0}\(identity)")
    }

    public static func snapshot(createdAt: Date, items: [DailyBriefItem],
                                sourceCursors: [String: String]) -> String {
        let itemIDs = items.map(\.id).joined(separator: "\u{1}")
        let cursors = sourceCursors.keys.sorted().map { "\($0)=\(sourceCursors[$0] ?? "")" }
            .joined(separator: "\u{1}")
        return digest("snapshot\u{0}\(DailyBriefDates.iso8601.string(from: createdAt))\u{0}\(itemIDs)\u{0}\(cursors)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
