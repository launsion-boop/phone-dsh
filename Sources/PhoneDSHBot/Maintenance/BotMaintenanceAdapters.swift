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
            // Different roles/baselines can report the same ref. Never crash on
            // `uniqueKeysWithValues` and never let a benign duplicate hide a
            // worse one; keep the worst state per ref for the caller to map.
            var merged: [String: BotSourceStatus] = [:]
            for status in statuses {
                if let existing = merged[status.ref],
                   Self.severity(existing.state) >= Self.severity(status.state) {
                    continue
                }
                merged[status.ref] = status
            }
            return merged
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
            let candidate = BotMaintenanceDependencyStatus(
                reference: status.ref,
                state: mapped,
                reason: status.reasons.first?.rawValue,
                observedAtMS: status.observedAtMS,
                derivedPaths: [])
            if let existing = result[reference],
               Self.dependencySeverity(existing.state) >= Self.dependencySeverity(candidate.state) {
                continue
            }
            result[reference] = candidate
        }
        return result
    }

    private static func severity(_ state: BotProvenanceStatus) -> Int {
        switch state {
        case .current: return 0
        case .changed: return 1
        case .unknown, .unavailable: return 2
        case .revoked: return 3
        case .erased: return 4
        }
    }

    private static func dependencySeverity(
        _ state: BotMaintenanceDependencyStatus.State) -> Int {
        switch state {
        case .live: return 0
        case .changed: return 1
        case .unknown: return 2
        case .revoked: return 3
        case .erased: return 4
        }
    }
}

/// Uses the existing `phone record read <ref> --around N` command, filters to
/// lines after the cited seq, and bounds the material. No new record API or
/// durable shape is introduced.
public struct BotMaintenanceRecordRecentContextReader:
    BotMaintenanceRecentContextReading {
    public typealias RawRead =
        @Sendable (String, String, Int) async -> String?

    private let rawRead: RawRead

    public init(service: BotRecordService) {
        self.rawRead = { reference, sessionID, around in
            let output = await service.execute(
                arguments: ["read", reference, "--around", String(around)],
                callerSessionID: sessionID)
            guard output.exitCode == 0 else { return nil }
            return output.stdout
        }
    }

    init(rawRead: @escaping RawRead) {
        self.rawRead = rawRead
    }

    public func recentContext(after references: [String],
                              callerSessionID: String,
                              lineLimit: Int,
                              characterLimit: Int)
        async throws -> [BotMaintenanceRecentContext] {
        var result: [BotMaintenanceRecentContext] = []
        for reference in references {
            guard reference.hasPrefix("record://session/"),
                  let parsed = BotRecordReference.parse(reference),
                  let seq = parsed.seq else { continue }
            let raw = await rawRead(reference, callerSessionID, 20)
            guard let raw, let data = raw.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let payload = root["data"] as? [String: Any],
                  let lines = payload["lines"] as? [[String: Any]] else {
                result.append(BotMaintenanceRecentContext(
                    citedReference: reference, lines: [], truncated: false,
                    available: false))
                continue
            }
            var selected: [BotMaintenanceRecentContextLine] = []
            var chars = 0
            var truncated = false
            for line in lines {
                guard let lineSeq = (line["seq"] as? NSNumber)?.intValue,
                      lineSeq > seq,
                      let lineRef = line["ref"] as? String,
                      let type = line["type"] as? String,
                      let rawLine = line["raw"] as? String else { continue }
                let text = BotMemoryMaintenanceText.readableText(raw: rawLine)
                guard !text.isEmpty else { continue }
                if selected.count >= max(0, lineLimit) || chars >= characterLimit {
                    truncated = true
                    break
                }
                let bounded = String(text.prefix(max(0, characterLimit - chars)))
                selected.append(BotMaintenanceRecentContextLine(
                    reference: lineRef, type: type, text: bounded))
                chars += bounded.count
            }
            result.append(BotMaintenanceRecentContext(
                citedReference: reference, lines: selected,
                truncated: truncated, available: true))
        }
        return result
    }
}
