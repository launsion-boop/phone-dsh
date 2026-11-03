// SPDX-License-Identifier: MIT

import Foundation

public struct EvidenceFilterResult: Sendable, Equatable {
    public let allowed: Set<EvidenceRef>
    public let rejected: Set<EvidenceRef>

    public init(allowed: Set<EvidenceRef>, rejected: Set<EvidenceRef>) {
        self.allowed = allowed
        self.rejected = rejected
    }
}

public struct EvidenceFilter: Sendable {
    public init() {}

    public func filter(_ proposed: Set<EvidenceRef>, mandate: WorkMandate) -> EvidenceFilterResult {
        EvidenceFilterResult(allowed: proposed.intersection(mandate.allowedEvidenceRefs),
                             rejected: proposed.subtracting(mandate.allowedEvidenceRefs))
    }

    public func context<Evidence: Sendable>(_ evidence: [Evidence], mandate: WorkMandate,
                                            ref: @Sendable (Evidence) -> EvidenceRef) -> [Evidence] {
        evidence.filter { mandate.allowedEvidenceRefs.contains(ref($0)) }
    }
}

public struct EvidenceAuditRecord: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let mandateID: UUID
    public let evidenceRefs: Set<EvidenceRef>
    public let auditedAt: Date

    public init(operationID: UUID, mandateID: UUID, evidenceRefs: Set<EvidenceRef>, auditedAt: Date) {
        self.operationID = operationID
        self.mandateID = mandateID
        self.evidenceRefs = evidenceRefs
        self.auditedAt = auditedAt
    }
}

public actor EvidenceAuditStore {
    private let fileURL: URL
    private var records: [EvidenceAuditRecord]

    public init(root: URL) throws {
        fileURL = root.appendingPathComponent("mandate/evidence-audit.json")
        records = try S4Persistence.load([EvidenceAuditRecord].self, from: fileURL) ?? []
    }

    public func record(_ record: EvidenceAuditRecord) throws {
        var updated = records
        updated.append(record)
        try S4Persistence.save(updated, to: fileURL)
        records = updated
    }

    public func all() -> [EvidenceAuditRecord] {
        records
    }
}
