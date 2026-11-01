// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: atomic Daily Brief persistence.

import Foundation

public actor DailyBriefStore {
    private let stateURL: URL

    public init(root: URL) throws {
        let directory = root.appendingPathComponent("DailyBrief", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = directory.appendingPathComponent("state.json")
    }

    public func load() throws -> DailyBriefPersistedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return DailyBriefPersistedState()
        }
        do {
            let data = try Data(contentsOf: stateURL)
            guard data.count <= DailyBriefLimits.maximumStateBytes else {
                throw DailyBriefError.persistence("状态文件超过大小上限")
            }
            let state = try Self.decoder.decode(DailyBriefPersistedState.self, from: data)
            try Self.validate(state)
            return state
        } catch let error as DailyBriefError {
            throw error
        } catch {
            throw DailyBriefError.persistence("状态文件损坏或版本不兼容")
        }
    }

    public func save(_ state: DailyBriefPersistedState) throws {
        try Self.validate(state)
        let data: Data
        do {
            data = try Self.encoder.encode(state)
        } catch {
            throw DailyBriefError.persistence("状态编码失败")
        }
        guard data.count <= DailyBriefLimits.maximumStateBytes else {
            throw DailyBriefError.persistence("状态文件超过大小上限")
        }
        do {
            try data.write(to: stateURL, options: .atomic)
        } catch {
            throw DailyBriefError.persistence("状态原子写入失败")
        }
    }

    private static func validate(_ state: DailyBriefPersistedState) throws {
        guard state.schemaVersion == DailyBriefLimits.schemaVersion else {
            throw DailyBriefError.persistence("不支持的状态版本 \(state.schemaVersion)")
        }
        guard state.sources.count <= DailyBriefLimits.maximumSources else {
            throw DailyBriefError.persistence("来源数超过上限")
        }
        guard Set(state.sources.map(\.id)).count == state.sources.count else {
            throw DailyBriefError.persistence("来源 ID 重复")
        }
        if let snapshot = state.snapshot {
            guard snapshot.schemaVersion == DailyBriefLimits.schemaVersion else {
                throw DailyBriefError.persistence("不支持的快照版本")
            }
            guard snapshot.items.count <= DailyBriefLimits.maximumItems else {
                throw DailyBriefError.persistence("快照条目数超过上限")
            }
        }
        if let report = state.lastReport,
           report.schemaVersion != DailyBriefLimits.schemaVersion {
            throw DailyBriefError.persistence("不支持的刷新报告版本")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }
        return decoder
    }()
}
