// SPDX-License-Identifier: MIT

import Foundation

/// One host-derived current-state entry produced by a real context recheck
/// (G-1 r5 §4.5). It mirrors the G-1 source-status vocabulary without inventing
/// a second status store: `current` means this read performed a real provider
/// query and the revision matched the baseline; it is never a verification.
public struct BotContextRecheck: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case current
        case changed
        case unavailable
        case revoked
        case erased
        case unknown
    }

    public enum Reason: String, Codable, Sendable, Hashable {
        case sourceChanged = "source-changed"
        case newerObservationUnversioned = "newer-observation-unversioned"
        case revisionBasisMismatch = "revision-basis-mismatch"
        case noBaseline = "no-baseline"
        case sourceVersionUnknown = "source-version-unknown"
        case refreshNotPerformed = "refresh-not-performed"
        case refreshUnavailable = "refresh-unavailable"
        case refreshDenied = "refresh-denied"
        case grantRevoked = "grant-revoked"
    }

    public var source: BotContextSourceKind
    public var state: State
    public var reasons: [Reason]
    public var sourceVersion: BotContextSourceVersion?
    public var baseline: BotContextSourceVersion?
    public var observedAtMS: Int64?
    public var recheckedAtMS: Int64?
    public var latestRef: String?

    public init(source: BotContextSourceKind, state: State,
                reasons: [Reason] = [],
                sourceVersion: BotContextSourceVersion? = nil,
                baseline: BotContextSourceVersion? = nil,
                observedAtMS: Int64? = nil,
                recheckedAtMS: Int64? = nil,
                latestRef: String? = nil) {
        self.source = source
        self.state = state
        self.reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        self.sourceVersion = sourceVersion
        self.baseline = baseline
        self.observedAtMS = observedAtMS
        self.recheckedAtMS = recheckedAtMS
        self.latestRef = latestRef
    }
}

/// What a source's real provider observed during this read. `denied` means the
/// OS/user refused the query; `notPerformed` means this source has no queryable
/// provider for the requested fact (the caller must show unknown, never
/// current).
public enum BotContextRecheckProbe: Sendable, Equatable {
    case version(BotContextSourceVersion)
    case denied(String)
    case unavailable(String)
    case notPerformed(String)
}

/// Implemented by adapters that can really re-query their OS/event source for
/// the same resource identity on demand.
public protocol BotContextSourceRechecking: BotContextSource {
    func recheck(permissionRevision: Int,
                 baseline: BotContextSourceVersion?,
                 latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe
}

/// Pure state machine used by the registry and tests. It never performs an OS
/// query itself; the adapter must supply a real probe result.
public enum BotContextRecheckEvaluator {
    public static func evaluate(source: BotContextSourceKind,
                                probe: BotContextRecheckProbe,
                                baseline: BotContextSourceVersion?,
                                observedAtMS: Int64?,
                                latestRef: String?,
                                recheckedAtMS: Int64) -> BotContextRecheck {
        switch probe {
        case .denied:
            return BotContextRecheck(
                source: source, state: .unknown, reasons: [.refreshDenied],
                baseline: baseline, observedAtMS: observedAtMS,
                recheckedAtMS: recheckedAtMS, latestRef: latestRef)
        case .unavailable:
            return BotContextRecheck(
                source: source, state: .unknown, reasons: [.refreshUnavailable],
                baseline: baseline, observedAtMS: observedAtMS,
                recheckedAtMS: recheckedAtMS, latestRef: latestRef)
        case .notPerformed:
            return BotContextRecheck(
                source: source, state: .unknown, reasons: [.refreshNotPerformed],
                baseline: baseline, observedAtMS: observedAtMS,
                recheckedAtMS: recheckedAtMS, latestRef: latestRef)
        case .version(.unknown(_, _, _)):
            return BotContextRecheck(
                source: source, state: .unknown, reasons: [.sourceVersionUnknown],
                sourceVersion: probeVersion(probe), baseline: baseline,
                observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                latestRef: latestRef)
        case .version(.known(let basis, let value, _, _, let probeSubject)):
            guard let baseline else {
                return BotContextRecheck(
                    source: source, state: .unknown, reasons: [.noBaseline],
                    sourceVersion: .known(basis, value: value),
                    observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                    latestRef: latestRef)
            }
            switch baseline {
            case .unknown:
                return BotContextRecheck(
                    source: source, state: .unknown, reasons: [.sourceVersionUnknown],
                    sourceVersion: .known(basis, value: value),
                    baseline: baseline, observedAtMS: observedAtMS,
                    recheckedAtMS: recheckedAtMS, latestRef: latestRef)
            case .known(let baselineBasis, let baselineValue, _, _, let baselineSubject):
                guard baselineBasis == basis else {
                    return BotContextRecheck(
                        source: source, state: .unknown, reasons: [.revisionBasisMismatch],
                        sourceVersion: .known(basis, value: value), baseline: baseline,
                        observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                        latestRef: latestRef)
                }
                if basis == .contentSHA256 {
                    let normalizedBaseline = baselineSubject ?? .recordText
                    let normalizedProbe = probeSubject ?? .recordText
                    guard normalizedBaseline == normalizedProbe else {
                        return BotContextRecheck(
                            source: source, state: .unknown, reasons: [.refreshNotPerformed],
                            sourceVersion: .known(basis, value: value), baseline: baseline,
                            observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                            latestRef: latestRef)
                    }
                }
                if baselineValue == value {
                    return BotContextRecheck(
                        source: source, state: .current, reasons: [],
                        sourceVersion: .known(basis, value: value), baseline: baseline,
                        observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                        latestRef: latestRef)
                }
                return BotContextRecheck(
                    source: source, state: .changed, reasons: [.sourceChanged],
                    sourceVersion: .known(basis, value: value), baseline: baseline,
                    observedAtMS: observedAtMS, recheckedAtMS: recheckedAtMS,
                    latestRef: latestRef)
            }
        }
    }

    private static func probeVersion(_ probe: BotContextRecheckProbe) -> BotContextSourceVersion? {
        if case .version(let version) = probe { return version }
        return nil
    }
}
