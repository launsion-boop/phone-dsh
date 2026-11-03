// SPDX-License-Identifier: MIT

import Foundation

public enum MandateTokenError: Error, Equatable {
    case invalid
    case expired
    case consumed
    case grantVersionChanged
}

public actor MandateTokenStore {
    private struct TokenRecord: Codable {
        let digest: String
        let mandate: WorkMandate
        let grantVersion: Int
        let expiresAt: Date
        var consumedAt: Date?
    }

    private let fileURL: URL
    private var records: [String: TokenRecord]

    public init(root: URL) throws {
        fileURL = root.appendingPathComponent("deleg/mandate-tokens.json")
        records = try S4Persistence.load([String: TokenRecord].self, from: fileURL) ?? [:]
    }

    public func issue(mandate: WorkMandate, grant: ConnectorGrant,
                      validFor: TimeInterval = 5 * 60, now: Date = Date()) throws -> String {
        let raw = UUID().uuidString + UUID().uuidString
        let digest = S4Persistence.digest(raw)
        let record = TokenRecord(digest: digest, mandate: mandate, grantVersion: grant.version,
                                 expiresAt: now.addingTimeInterval(validFor), consumedAt: nil)
        var updated = records
        updated[digest] = record
        try S4Persistence.save(updated, to: fileURL)
        records = updated
        return raw
    }

    public func mandate(for token: String, grant: ConnectorGrant, now: Date = Date()) throws -> WorkMandate {
        let record = try validRecord(token: token, grant: grant, now: now)
        return record.mandate
    }

    public func consume(token: String, grant: ConnectorGrant, now: Date = Date()) throws -> WorkMandate {
        let digest = S4Persistence.digest(token)
        let record = try validRecord(token: token, grant: grant, now: now)
        var updatedRecord = record
        updatedRecord.consumedAt = now
        var updated = records
        updated[digest] = updatedRecord
        try S4Persistence.save(updated, to: fileURL)
        records = updated
        return record.mandate
    }

    private func validRecord(token: String, grant: ConnectorGrant, now: Date) throws -> TokenRecord {
        guard let record = records[S4Persistence.digest(token)] else { throw MandateTokenError.invalid }
        if record.consumedAt != nil { throw MandateTokenError.consumed }
        if record.expiresAt <= now { throw MandateTokenError.expired }
        if record.grantVersion != grant.version { throw MandateTokenError.grantVersionChanged }
        return record
    }
}
