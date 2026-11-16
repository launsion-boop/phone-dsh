// SPDX-License-Identifier: MIT

// Source inspection over G-1 artifact-scoped statuses.
//
// The old UI adapter resolved every source through the refs overload, which
// has no artifact baseline. That loses the very comparison the inspector
// exists for: a file observation can be `current` for one memory version and
// `changed` for another, and a revoked grant must not be flattened into
// `unknown`. This helper asks L for each derived artifact's current state, then
// merges only entries that really describe the same record, role, state and
// source version.

import Foundation

public struct BotArtifactSourceInspectionEntry: Sendable, Equatable {
    public var artifact: BotDerivedRef
    public var role: BotDerivationRole?
    public var status: BotSourceStatus
    public var review: BotReviewEffective

    public init(artifact: BotDerivedRef, role: BotDerivationRole?,
                status: BotSourceStatus, review: BotReviewEffective) {
        self.artifact = artifact
        self.role = role
        self.status = status
        self.review = review
    }
}

public struct BotArtifactSourceInspectionMerged: Sendable, Equatable {
    public var record: String
    public var role: BotDerivationRole?
    public var state: BotProvenanceStatus
    public var reasons: [BotProvenanceReason]
    public var trust: String?
    public var observedAtMS: Int64?
    public var sourceVersion: BotProvenanceSourceVersion?
    public var review: BotReviewEffective
    public var artifactCount: Int
    public var resourceKind: String?
    public var recordType: String?

    public init(record: String, role: BotDerivationRole?, state: BotProvenanceStatus,
                reasons: [BotProvenanceReason], trust: String?,
                observedAtMS: Int64?, sourceVersion: BotProvenanceSourceVersion?,
                review: BotReviewEffective, artifactCount: Int,
                resourceKind: String? = nil, recordType: String? = nil) {
        self.record = record
        self.role = role
        self.state = state
        self.reasons = reasons
        self.trust = trust
        self.observedAtMS = observedAtMS
        self.sourceVersion = sourceVersion
        self.review = review
        self.artifactCount = artifactCount
        self.resourceKind = resourceKind
        self.recordType = recordType
    }

    /// Internal row identity. The UI keeps this in `id` and never displays it.
    public var identity: String {
        let version: String
        if let sourceVersion, let data = try? JSONEncoder().encode(sourceVersion) {
            version = String(data: data, encoding: .utf8) ?? "none"
        } else {
            version = "none"
        }
        return "\(record)\u{1F}\(role?.rawValue ?? "none")\u{1F}"
            + "\(state.rawValue)\u{1F}\(version)\u{1F}\(review.state.rawValue)"
    }
}

public enum BotArtifactSourceInspection {
    /// One entry per (artifact, source, role). The caller merges them with
    /// `merge`; no state is invented and no refs overload is used.
    public static func entries(eventIDs: [String], botID: String,
                               provenance: any BotProvenanceQuerying) async throws
        -> [BotArtifactSourceInspectionEntry] {
        var seenArtifacts = Set<String>()
        var result: [BotArtifactSourceInspectionEntry] = []
        for eventID in eventIDs {
            guard !eventID.isEmpty else { continue }
            let artifacts = try await provenance.derivedRefs(forEventID: eventID)
            for artifact in artifacts {
                guard seenArtifacts.insert(artifact.canonical).inserted else { continue }
                let view = try await provenance.currentState(for: artifact, botID: botID)
                for source in view.sources {
                    result.append(BotArtifactSourceInspectionEntry(
                        artifact: artifact,
                        role: BotDerivationRole(rawValue: source.role),
                        status: source.status, review: view.reviewEffective))
                }
            }
        }
        return result
    }

    /// Merge entries that describe the same record, role, current state, source
    /// version and review verdict. Different baselines stay separate rows: the
    /// user must see that the same record is current for one artifact and
    /// changed for another.
    public static func merge(_ entries: [BotArtifactSourceInspectionEntry])
        -> [BotArtifactSourceInspectionMerged] {
        var merged: [String: BotArtifactSourceInspectionMerged] = [:]
        for entry in entries {
            let candidate = BotArtifactSourceInspectionMerged(
                record: entry.status.ref,
                role: entry.role,
                state: entry.status.state,
                reasons: entry.status.reasons,
                trust: entry.status.trust,
                observedAtMS: entry.status.observedAtMS,
                sourceVersion: entry.status.sourceVersion,
                review: entry.review,
                artifactCount: 1,
                resourceKind: entry.status.resource?.kind.rawValue,
                recordType: entry.status.recordType)
            let key = candidate.identity
            guard var current = merged[key] else {
                merged[key] = candidate
                continue
            }
            current.artifactCount += 1
            for reason in candidate.reasons where !current.reasons.contains(reason) {
                current.reasons.append(reason)
            }
            if current.trust == nil { current.trust = candidate.trust }
            if current.observedAtMS == nil { current.observedAtMS = candidate.observedAtMS }
            if current.sourceVersion == nil { current.sourceVersion = candidate.sourceVersion }
            if current.resourceKind == nil { current.resourceKind = candidate.resourceKind }
            if current.recordType == nil { current.recordType = candidate.recordType }
            merged[key] = current
        }
        return merged.values.sorted { left, right in
            if left.state.severity != right.state.severity {
                return left.state.severity > right.state.severity
            }
            if left.record != right.record { return left.record < right.record }
            return (left.role?.rawValue ?? "") < (right.role?.rawValue ?? "")
        }
    }

    public static func inspect(eventIDs: [String], botID: String,
                               provenance: any BotProvenanceQuerying) async throws
        -> [BotArtifactSourceInspectionMerged] {
        merge(try await entries(eventIDs: eventIDs, botID: botID, provenance: provenance))
    }

    public static func roleLabel(_ role: BotDerivationRole?) -> String? {
        switch role {
        case .evidence: return "作为依据"
        case .review: return "作为核对依据"
        case .trigger: return "作为触发来源"
        case .creator: return "作为创建者"
        case .recipient: return "作为接收方"
        case .basis: return "作为版本依据"
        case nil: return nil
        }
    }
}
