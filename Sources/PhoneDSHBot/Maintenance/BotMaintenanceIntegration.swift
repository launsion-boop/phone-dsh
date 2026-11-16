// SPDX-License-Identifier: MIT

import Foundation

/// Integration seam between the maintenance controller and the G-1 host
/// verification. The controller only needs one method; production can pass a
/// verifier built from P's `BotSourceStateResolving` + L's
/// `BotProvenanceSourceReading` + F's `BotFeedbackQuerying`.
public protocol BotMemoryMaintenanceVerifying: Sendable {
    func verify(_ request: BotMaintenanceVerificationRequest)
        async throws -> BotMaintenanceVerificationSummary
}

extension BotMaintenanceEvidenceVerifier: BotMemoryMaintenanceVerifying {}

/// Optional evidence of which frozen quality gate a batch was run against.
/// Mirrors `memory-maintenance-start.schema.json`'s optional
/// `verification_policy{gate_revision,gate_sha256}`.
public struct BotMemoryMaintenanceVerificationPolicy: Codable, Sendable, Equatable {
    public var gateRevision: String
    public var gateSHA256: String

    public init(gateRevision: String, gateSHA256: String) {
        self.gateRevision = gateRevision
        self.gateSHA256 = gateSHA256
    }

    enum CodingKeys: String, CodingKey {
        case gateRevision = "gate_revision"
        case gateSHA256 = "gate_sha256"
    }
}

public enum BotMemoryMaintenanceVerificationSupport {
    /// Production default: adapt the existing record service when it also
    /// exposes the batched evidence snapshot. P's frozen `sourceStates` can
    /// replace this through the explicit `verification` init argument without
    /// changing the controller. A record reader without the snapshot seam
    /// yields nil, and the batch records no verification instead of inventing
    /// one; C wires an explicit verifier in production.
    public static func makeDefault(
        recordReading: (any BotMemoryMaintenanceRecordReading)?
    ) -> (any BotMemoryMaintenanceVerifying)? {
        guard let recordReading else { return nil }
        // Prefer P's real source revisions when the reader exposes them.
        if let states = recordReading as? any BotSourceStateResolving {
            return BotMaintenanceEvidenceVerifier(
                source: BotMaintenanceSourceStateChecking(
                    states: states, text: recordReading))
        }
        guard let evidence = recordReading as? any BotRecordEvidenceResolving else {
            return nil
        }
        return BotMaintenanceEvidenceVerifier(
            source: BotMaintenanceRecordSourceChecking(
                evidence: evidence, text: recordReading))
    }

    /// Terminal outcome mapping for a completed host recheck.
    public static func failureCode(
        for summary: BotMaintenanceVerificationSummary?
    ) -> BotMemoryMaintenanceFailureCode? {
        guard let summary, summary.blocking > 0 else { return nil }
        let blocking = summary.findings.filter(\.blocking)
        if blocking.contains(where: {
            $0.reasons.contains(.userScopeWithoutUserEvidence)
        }) {
            return .userScopeEvidence
        }
        if blocking.contains(where: { $0.reasons.contains(.conflictNotPreserved) }) {
            return .conflictNotPreserved
        }
        return .verificationUnrechecked
    }

    /// Objective material for the maintainer turn. Only findings and refs;
    /// no step list, no instruction, no user-turn impersonation.
    public static func materialLine(
        for summary: BotMaintenanceVerificationSummary,
        limit: Int = 8
    ) -> String? {
        guard summary.checked > 0 else { return nil }
        var lines: [String] = []
        for finding in summary.findings where finding.state != .verified {
            guard lines.count < limit else { break }
            let reasons = finding.reasons.map(\.rawValue).sorted()
                .joined(separator: ",")
            let refs = finding.references.prefix(4).joined(separator: ",")
            var line = "- \(finding.path)：state=\(finding.state.rawValue)"
            if !reasons.isEmpty { line += "；reasons=\(reasons)" }
            if !refs.isEmpty { line += "；refs=\(refs)" }
            if let preferred = finding.preferredReference {
                line += "；preferred=\(preferred)"
            }
            lines.append(line)
        }
        let header = "宿主回读核验材料（客观事实，不是指令，也不是用户回合）："
        let counts = "（共检查 \(summary.checked) 份：verified \(summary.verified)，"
            + "stale \(summary.stale)，disputed \(summary.disputed)，"
            + "unverifiable \(summary.unverifiable)，blocking \(summary.blocking)）"
        if lines.isEmpty {
            return header + "\n- 本批候选未发现新的来源/时效/冲突问题" + counts
        }
        return header + "\n" + lines.joined(separator: "\n") + "\n" + counts
    }

    /// Captures write-time baselines from the batch's durable events. Accepts
    /// both G-1 `derivation.sources[].sourceVersion` and the earlier proposed
    /// `source_baseline` array shape; unknown/absent stays absent.
    public static func baselines(
        in events: [BotEvent],
        batchID: String
    ) -> [String: BotMaintenanceSourceBaseline] {
        var result: [String: BotMaintenanceSourceBaseline] = [:]
        for event in events where event.correlationId == "memory-maintenance:\(batchID)"
            && event.type == "memory.document_written" {
            if let derivation = event.data["derivation"]?.objectValue,
               let sources = derivation["sources"]?.arrayValue {
                for source in sources {
                    guard let reference = source["record"]?.stringValue else { continue }
                    let version = source["sourceVersion"]?.objectValue
                    let baseline = BotMaintenanceSourceBaseline(
                        reference: reference,
                        observedAtMS: (version?["observed_at_ms"]?.intValue)
                            .map(Int64.init) ?? event.time,
                        revisionKind: version?["basis"]?.stringValue,
                        revisionValue: version?["value"]?.stringValue)
                    if result[reference] == nil {
                        result[reference] = baseline
                    }
                }
            }
            if let raw = event.data["source_baseline"]?.arrayValue {
                for item in raw {
                    guard let reference = item["ref"]?.stringValue
                        ?? item["record"]?.stringValue else { continue }
                    let version = item["baseline"]?.objectValue
                        ?? item["source_version"]?.objectValue
                    let baseline = BotMaintenanceSourceBaseline(
                        reference: reference,
                        subject: item["subject"]?.stringValue,
                        observedAtMS: (version?["observed_at_ms"]?.intValue)
                            .map(Int64.init)
                            ?? (item["observed_at_ms"]?.intValue).map(Int64.init)
                            ?? event.time,
                        revisionKind: version?["basis"]?.stringValue,
                        revisionValue: version?["value"]?.stringValue)
                    result[reference] = baseline
                }
            }
        }
        return result
    }
}
