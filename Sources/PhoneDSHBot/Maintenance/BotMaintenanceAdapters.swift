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
        @Sendable ([String]) async throws -> [String: BotSourceStatus]

    private let query: Query

    public init(provenance: any BotProvenanceQuerying) {
        self.query = { refs in try await provenance.sourceStatuses(for: refs) }
    }

    init(rawQuery: @escaping Query) {
        self.query = rawQuery
    }

    public func invalidationStatuses(for references: [String]) async throws
        -> [String: BotMaintenanceDependencyStatus] {
        let raw = try await query(references)
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
