// SPDX-License-Identifier: MIT

import Foundation

/// Aggregates L's G-1 `sourceStatuses` for one decision-material lookup into
/// the G-2 material `state`/`reason` pair. The caller supplies the resolver
/// (normally `BotProvenanceService.sourceStatuses(for:botID:)`), so this adapter
/// never invents a state and never owns resource identity or the status
/// vocabulary: L remains the single authority.
public struct BotDecisionMaterialStateAdapter: Sendable {
    public typealias StatusResolver =
        @Sendable (BotDerivedRef, String?) async throws -> [BotSourceStatus]

    private let resolve: StatusResolver

    public init(resolve: @escaping StatusResolver) {
        self.resolve = resolve
    }

    /// L's artifact-scoped query carries the Bot owner so `agent/` artifacts
    /// cannot collide across Bots; `user/` stays shared inside L's key. The
    /// refs overload has no artifact baseline and must not be used here.
    public init(provenance: any BotProvenanceQuerying) {
        resolve = { artifact, botID in
            try await provenance.sourceStatuses(for: artifact, botID: botID)
        }
    }

    public func state(
        for request: BotDecisionContextService.BotMaterialStateRequest
    ) async -> (BotDecisionMaterialState, BotDecisionMaterialReason?) {
        // One material document without evidence has no source to verify.
        guard !request.evidence.isEmpty else {
            return (.unknown, .noBaseline)
        }
        let artifact = BotDerivedRef(
            kind: .memory, id: request.path, version: request.version)
        let statuses: [BotSourceStatus]
        do {
            statuses = try await resolve(artifact, request.botID)
        } catch {
            // The resolver itself is unavailable; do not turn this into
            // current. The material can still be shown as unknown.
            return (.unknown, .sourceVersionUnknown)
        }
        guard !statuses.isEmpty else {
            return (.unknown, request.evidence.isEmpty ? .noBaseline : .recordUnresolved)
        }
        let byRef = Dictionary(statuses.map { ($0.ref, $0) },
                               uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let refs = request.evidence.filter { seen.insert($0).inserted }
        var resolved: [BotSourceStatus] = []
        if refs.isEmpty {
            resolved = statuses
        } else {
            for ref in refs {
                guard let status = byRef[ref] else {
                    return (.unknown, .recordUnresolved)
                }
                resolved.append(status)
            }
        }
        guard let worst = resolved.max(by: { $0.state.severity < $1.state.severity }) else {
            return (.unknown, .noBaseline)
        }
        return (Self.state(worst.state), Self.reason(worst))
    }

    private static func state(_ state: BotProvenanceStatus) -> BotDecisionMaterialState {
        switch state {
        case .current: return .current
        case .changed: return .changed
        case .unavailable: return .unavailable
        case .revoked: return .revoked
        case .erased: return .erased
        case .unknown: return .unknown
        }
    }

    private static func reason(_ status: BotSourceStatus) -> BotDecisionMaterialReason? {
        if status.state == .current { return nil }
        if let mapped = status.reasons.compactMap({
            BotDecisionMaterialReason(rawValue: $0.rawValue)
        }).first {
            return mapped
        }
        // G-2's material reason enum is narrower than G-1's full reason set.
        // Keep the documented fallback per state rather than inventing a new
        // value that the frozen schema does not allow.
        switch status.state {
        case .current: return nil
        case .changed: return .sourceChanged
        case .unavailable: return .recordUnresolved
        case .revoked: return .grantRevoked
        case .erased: return .recordErased
        case .unknown: return .sourceVersionUnknown
        }
    }
}
