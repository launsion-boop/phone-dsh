// SPDX-License-Identifier: MIT

import Foundation

public struct PhoneCapabilityAuditRecord: Codable, Equatable, Sendable {
    public let capability: PhoneCapability
    public let tool: String
    public let at: Date
    public let egress: Bool
    public let outcome: String

    public init(capability: PhoneCapability, tool: String, at: Date = Date(),
                egress: Bool = false, outcome: String) {
        self.capability = capability
        self.tool = tool
        self.at = at
        self.egress = egress
        self.outcome = outcome
    }
}

public actor PhoneCapabilityAudit {
    public static let shared = PhoneCapabilityAudit(directory: FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask).first)
    public static let capacity = 200

    private var records: [PhoneCapabilityAuditRecord] = []
    private let directory: URL?
    private var loaded = false
    public private(set) var persistenceError: String?

    public init(directory: URL? = nil) {
        self.directory = directory
    }

    public func record(_ entry: PhoneCapabilityAuditRecord) {
        loadIfNeeded()
        records.append(entry)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
        persist()
    }

    public func recent(limit: Int = PhoneCapabilityAudit.capacity) -> [PhoneCapabilityAuditRecord] {
        loadIfNeeded()
        guard limit > 0 else { return [] }
        return records.suffix(min(limit, Self.capacity)).reversed()
    }

    public func removeAll() {
        loadIfNeeded()
        records.removeAll()
        guard let file = fileURL else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { persistenceError = error.localizedDescription }
    }

    private var fileURL: URL? { directory?.appendingPathComponent("permissions-audit.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file = fileURL, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 256 * 1024 else {
                persistenceError = "权限审计文件超过读取上限"
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = Array(try decoder.decode([PhoneCapabilityAuditRecord].self,
                                               from: Data(contentsOf: file)).suffix(Self.capacity))
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        guard let directory, let file = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: file, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
