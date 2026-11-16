// SPDX-License-Identifier: MIT

import Foundation

/// Adapts R's web/connector conditional rechecker to L's provenance seam.
///
/// L owns `BotResourceIdentity` and the state/reason vocabulary. This adapter
/// only turns the web/connector identity plus its baseline into one conditional
/// request and maps the producer outcome back to L's closed outcome. The HTTP
/// transport is injected (production: `GatewayWebRecheckTransport`), so the
/// existing host allow-list/credential policy remains the authorization
/// boundary and no new Grant is created.
public struct BotProvenanceWebRecheckAdapter: BotProvenanceRechecking {
    private let rechecker: BotWebSourceRechecker
    private let timeoutMilliseconds: Int
    private let maximumBodyBytes: Int

    public init(
        transport: any BotWebRecheckTransport,
        timeoutMilliseconds: Int = 2_000,
        maximumBodyBytes: Int = 1_048_576,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        rechecker = BotWebSourceRechecker(transport: transport, now: now)
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumBodyBytes = maximumBodyBytes
    }

    public func recheck(resource: BotResourceIdentity,
                        baseline: BotProvenanceSourceVersion,
                        botID: String?) async -> BotProvenanceRecheckOutcome {
        let kind: BotWebResourceKind
        switch resource.kind {
        case .webURL: kind = .webURL
        case .connectorResource: kind = .connector
        default: return .notPerformed
        }
        let request = BotWebRecheckRequest(
            resource: BotWebResourceIdentity(
                kind: kind, url: resource.key,
                owner: resource.owner ?? botID, scope: resource.scope),
            baseline: Self.webBaseline(baseline),
            timeoutMilliseconds: timeoutMilliseconds,
            maximumBodyBytes: maximumBodyBytes)
        return Self.outcome(await rechecker.recheck(request))
    }

    private static func webBaseline(_ version: BotProvenanceSourceVersion)
        -> BotWebRevision? {
        guard case let .known(known) = version else {
            return nil
        }
        let mapped: BotWebRevision.Basis
        switch known.basis {
        case .etag: mapped = .etag
        case .lastModified: mapped = .lastModified
        case .contentSHA256: mapped = .contentSHA256
        case .providerVersion: return nil
        }
        return BotWebRevision(basis: mapped, value: known.value,
                              observedAtMS: known.observedAtMS ?? 0)
    }

    private static func outcome(_ outcome: BotWebRecheckOutcome)
        -> BotProvenanceRecheckOutcome {
        switch outcome {
        case let .unchanged(current):
            return .same(atMS: current.observedAtMS)
        case let .changed(_, current):
            return .changed(
                version: .known(BotKnownProvenanceSourceVersion(
                    basis: basis(current.basis),
                    value: current.value,
                    observedAtMS: current.observedAtMS,
                    basisRef: nil)),
                atMS: current.observedAtMS)
        case let .basisMismatch(_, current):
            return .revisionBasisMismatch(atMS: current.observedAtMS)
        case let .denied(code, _):
            return .denied(detail: code.rawValue)
        case let .unavailable(code):
            return .unavailable(detail: code.rawValue)
        case .notPerformed:
            return .notPerformed
        case .cancelled:
            return .notPerformed
        case .observed:
            // A first observation has no comparable baseline. L must keep the
            // item unknown/no-baseline rather than receiving a fake same.
            return .notPerformed
        }
    }

    private static func basis(_ basis: BotWebRevision.Basis)
        -> BotProvenanceSourceVersion.BotSourceBasis {
        switch basis {
        case .etag: return .etag
        case .lastModified: return .lastModified
        case .contentSHA256: return .contentSHA256
        }
    }
}
