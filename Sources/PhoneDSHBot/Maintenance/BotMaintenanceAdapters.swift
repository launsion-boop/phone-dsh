// SPDX-License-Identifier: MIT

import Foundation

/// Production adapters from the frozen F/L read services to the maintainer
/// verification seams. They do not own state and do not relax a verdict:
/// retracted feedback is dropped, and `unknown`/`unavailable` provenance never
/// becomes `live`.
public struct BotFeedbackDisputeAdapter: BotMaintenanceFeedbackReading {
    public typealias Query =
        @Sendable ([String]) async throws -> [String: [BotFeedbackDisputedRef]]

    private let query: Query

    public init(query: any BotFeedbackQuerying) {
        self.query = { paths in try await query.disputedRefs(paths: paths) }
    }

    /// Production scoped injection: C supplies L r16's
    /// `sourceStatuses(for: artifact, botID:)` (or an equivalent scoped read)
    /// here. The request carries the real botID and artifact baseline; the
    /// closure must not fall back to a global no-bot query.
    public init(scopedQuery: @escaping Query) {
        self.query = scopedQuery
    }

    init(rawQuery: @escaping Query) {
        self.query = rawQuery
    }

    public func disputedReferences(forPaths paths: [String]) async throws
        -> [String: [String]] {
        let raw = try await query(paths)
        var result: [String: [String]] = [:]
        for (path, items) in raw {
            // A retracted correction is not a current dispute. An active
            // correction whose refs were not replayed still marks the path as
            // disputed; the empty array is preserved so the verifier can fail
            // closed instead of treating it as "no dispute".
            let active = items.filter { $0.state == "active" }
            guard !active.isEmpty else { continue }
            result[path] = Array(Set(active.flatMap(\.refs))).sorted()
        }
        return result
    }
}

/// Maps L's `BotProvenanceQuerying.sourceStatuses(for:)` to M's dependency
/// state. `current` is the only live state; every other status keeps its
/// meaning (unknown and unavailable are not live).
public struct BotProvenanceInvalidationAdapter: BotMaintenanceInvalidationReading {
    public typealias Query =
        @Sendable (BotMaintenanceInvalidationRequest) async throws -> [String: BotSourceStatus]

    private let query: Query

    public init(provenance: any BotProvenanceQuerying) {
        self.query = { request in
            // Prefer the artifact baseline (G-1 currentState/derivation view)
            // when the caller supplied one; fall back to refs only for a
            // legacy call that has no artifact context.
            let artifact = request.artifact
            let derived = BotDerivedRef(
                kind: .memory, id: artifact.path, version: artifact.version)
            let statuses = try await provenance.sourceStatuses(for: derived)
            return Dictionary(uniqueKeysWithValues: statuses.map {
                ($0.ref, $0)
            })
        }
    }

    /// Production scoped injection: C supplies L r16's
    /// `sourceStatuses(for: artifact, botID:)` (or an equivalent scoped read)
    /// here. The request carries the real botID and artifact baseline; the
    /// closure must not fall back to a global no-bot query.
    public init(scopedQuery: @escaping Query) {
        self.query = scopedQuery
    }

    init(rawQuery: @escaping Query) {
        self.query = rawQuery
    }

    public func invalidationStatuses(for request: BotMaintenanceInvalidationRequest)
        async throws -> [String: BotMaintenanceDependencyStatus] {
        let raw = try await query(request)
        var result: [String: BotMaintenanceDependencyStatus] = [:]
        for (reference, status) in raw {
            let mapped: BotMaintenanceDependencyStatus.State
            switch status.state {
            case .current: mapped = .live
            case .changed: mapped = .changed
            case .revoked: mapped = .revoked
            case .erased: mapped = .erased
            case .unavailable, .unknown: mapped = .unknown
            }
            result[reference] = BotMaintenanceDependencyStatus(
                reference: status.ref,
                state: mapped,
                reason: status.reasons.first?.rawValue,
                observedAtMS: status.observedAtMS,
                derivedPaths: [])
        }
        return result
    }
}
