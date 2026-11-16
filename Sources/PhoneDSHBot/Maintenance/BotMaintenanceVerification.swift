// SPDX-License-Identifier: MIT

import Foundation

/// Host-side re-verification for the background memory maintainer.
///
/// The maintainer model may write `review = verified`, but that is only a
/// writer assertion. This module re-reads every cited record, re-derives trust,
/// compares the current source state with the baseline captured at write time,
/// checks that contested claims keep both sides, and cross-checks important
/// facts (numbers, identifiers, quoted names) against an independent signal.
/// It only produces findings; it never writes memory content or a second
/// verification store.
///
/// Contract seam: `spec/bot/v2/README.md` §4.4 and G-1
/// (`source-revision` / `source-baseline` / `freshness`). Until P publishes
/// the frozen `BotSourceStateResolving`, `BotMaintenanceRecordSourceChecking`
/// adapts the existing `BotRecordEvidenceResolving` + record text reader and
/// reports missing revisions as an explicit unknown, never as verified.

// MARK: - Source state

public enum BotMaintenanceSourceCurrent: String, Codable, Sendable, Equatable {
    case current
    case changed
    case unavailable
    case revoked
    case erased
    case unknown
}

public struct BotMaintenanceSourceRevision: Codable, Sendable, Equatable {
    public var kind: String
    public var value: String
    public var basisReference: String?

    public init(kind: String, value: String, basisReference: String? = nil) {
        self.kind = kind
        self.value = value
        self.basisReference = basisReference
    }

    enum CodingKeys: String, CodingKey {
        case kind, value
        case basisReference = "basis_ref"
    }
}

/// The write-time snapshot of one source, taken from a durable event's
/// `source_baseline` member (G-1). Absent means old data: unknown, not current.
public struct BotMaintenanceSourceBaseline: Codable, Sendable, Equatable {
    public var reference: String
    public var subject: String?
    public var observedAtMS: Int64?
    public var revisionKind: String?
    public var revisionValue: String?
    public var authorizationReference: String?
    public var scope: String?

    public init(reference: String, subject: String? = nil,
                observedAtMS: Int64? = nil,
                revisionKind: String? = nil, revisionValue: String? = nil,
                authorizationReference: String? = nil, scope: String? = nil) {
        self.reference = reference
        self.subject = subject
        self.observedAtMS = observedAtMS
        self.revisionKind = revisionKind
        self.revisionValue = revisionValue
        self.authorizationReference = authorizationReference
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case reference = "ref"
        case subject
        case observedAtMS = "observed_at_ms"
        case revisionKind = "revision_kind"
        case revisionValue = "revision_value"
        case authorizationReference = "authorization_ref"
        case scope
    }
}

public struct BotMaintenanceSourceProbe: Sendable, Equatable {
    public var reference: String
    public var current: BotMaintenanceSourceCurrent
    public var reason: String?
    public var observedAtMS: Int64?
    public var trust: BotRecordTrust?
    public var recordType: String?
    public var text: String?
    public var subject: String?
    public var revision: BotMaintenanceSourceRevision?

    public init(reference: String, current: BotMaintenanceSourceCurrent,
                reason: String? = nil, observedAtMS: Int64? = nil,
                trust: BotRecordTrust? = nil, recordType: String? = nil,
                text: String? = nil, subject: String? = nil,
                revision: BotMaintenanceSourceRevision? = nil) {
        self.reference = reference
        self.current = current
        self.reason = reason
        self.observedAtMS = observedAtMS
        self.trust = trust
        self.recordType = recordType
        self.text = text
        self.subject = subject
        self.revision = revision
    }
}

/// Read-only source check seam. P's frozen `BotSourceStateResolving` can be
/// adapted to this in one small adapter; the default adapter below uses the
/// existing record evidence API so the maintainer can start re-checking now.
public protocol BotMaintenanceSourceChecking: Sendable {
    func probe(references: [String], callerBotID: String, callerSessionID: String)
        async throws -> [BotMaintenanceSourceProbe]
}

/// Dependency invalidation seam (L). `state` uses the frozen G-1 vocabulary;
/// `unknown` never counts as current.
public struct BotMaintenanceDependencyStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case live, erased, revoked, changed, unknown
    }

    public var reference: String
    public var state: State
    public var reason: String?
    public var observedAtMS: Int64?
    public var derivedPaths: [String]

    public init(reference: String, state: State, reason: String? = nil,
                observedAtMS: Int64? = nil, derivedPaths: [String] = []) {
        self.reference = reference
        self.state = state
        self.reason = reason
        self.observedAtMS = observedAtMS
        self.derivedPaths = derivedPaths
    }
}

/// L's `BotProvenanceSourceReading.sourceStatuses(for:)` maps onto this.
public protocol BotMaintenanceInvalidationReading: Sendable {
    func invalidationStatuses(for references: [String])
        async throws -> [String: BotMaintenanceDependencyStatus]
}

/// Feedback seam (F). A path is quoted only when the user explicitly marked
/// a claim as wrong or suppressed; absence is not a verification signal.
public protocol BotMaintenanceFeedbackReading: Sendable {
    func disputedReferences(forPaths paths: [String])
        async throws -> [String: [String]]
}

// MARK: - Default adapter over the existing record service

/// Adapts `BotRecordEvidenceResolving` + record text reading. Source revision
/// is unknown here (the frozen P resolver supplies it later); this is recorded
/// as `source-version-unknown`, never upgraded to a host verification of the
/// source's current revision.
public struct BotMaintenanceRecordSourceChecking: BotMaintenanceSourceChecking {
    private let evidence: any BotRecordEvidenceResolving
    private let text: any BotMemoryMaintenanceRecordReading

    public init(evidence: any BotRecordEvidenceResolving,
                text: any BotMemoryMaintenanceRecordReading) {
        self.evidence = evidence
        self.text = text
    }

    public func probe(references: [String], callerBotID: String,
                      callerSessionID: String) async throws -> [BotMaintenanceSourceProbe] {
        var unique: [String] = []
        var seen = Set<String>()
        for reference in references where seen.insert(reference).inserted {
            unique.append(reference)
        }
        guard !unique.isEmpty else { return [] }
        let snapshot = try await evidence.evidenceSnapshot(
            for: unique, callerBotID: callerBotID,
            callerSessionID: callerSessionID)
        var probes: [BotMaintenanceSourceProbe] = []
        for reference in unique {
            let point = snapshot.point(for: reference)
            let current: BotMaintenanceSourceCurrent
            let reason: String?
            if let point {
                if point.erased {
                    current = .erased
                    reason = "record-erased"
                } else if point.resolved {
                    current = .current
                    reason = "source-revision-unavailable"
                } else {
                    current = .unavailable
                    reason = "record-unresolved"
                }
            } else {
                current = .unavailable
                reason = "record-unresolved"
            }
            var readable: String?
            if current == .current {
                readable = try? await text.recordText(
                    reference, callerSessionID: callerSessionID)
            }
            probes.append(BotMaintenanceSourceProbe(
                reference: reference, current: current, reason: reason,
                observedAtMS: point?.observedAtMS,
                trust: point?.trust, recordType: point?.recordType,
                text: readable,
                subject: nil,
                revision: nil))
        }
        return probes
    }
}

/// Adapts P's frozen `BotSourceStateResolving` facts (real content revisions)
/// into M's probe shape. P owns the digest/unknown reasons; M does not copy
/// that computation. Current-status verdicts still come from L; P's facts here
/// distinguish resolved/erased/observation only.
public struct BotMaintenanceSourceStateChecking: BotMaintenanceSourceChecking {
    private let states: any BotSourceStateResolving
    private let text: any BotMemoryMaintenanceRecordReading

    public init(states: any BotSourceStateResolving,
                text: any BotMemoryMaintenanceRecordReading) {
        self.states = states
        self.text = text
    }

    public func probe(references: [String], callerBotID: String,
                      callerSessionID: String) async throws -> [BotMaintenanceSourceProbe] {
        guard !references.isEmpty else { return [] }
        let resolved = try await states.sourceStates(
            for: references, callerBotID: callerBotID,
            callerSessionID: callerSessionID)
        var probes: [BotMaintenanceSourceProbe] = []
        for state in resolved {
            let current: BotMaintenanceSourceCurrent
            var reason: String?
            if state.erased {
                current = .erased
                reason = BotSourceVersionUnknownReason.recordErased.rawValue
            } else if !state.resolved {
                current = .unavailable
                reason = BotSourceVersionUnknownReason.recordUnresolved.rawValue
            } else {
                current = .current
                if let unknown = state.version?.unknownReason {
                    reason = unknown.rawValue
                }
            }
            var revision: BotMaintenanceSourceRevision?
            if let known = state.version?.known {
                revision = BotMaintenanceSourceRevision(
                    kind: known.kind.rawValue, value: known.value,
                    basisReference: known.basisRef)
            }
            var readable: String?
            if current == .current {
                readable = try? await text.recordText(
                    state.ref, callerSessionID: callerSessionID)
            }
            probes.append(BotMaintenanceSourceProbe(
                reference: state.ref, current: current, reason: reason,
                observedAtMS: state.observedAtMS, trust: state.trust,
                recordType: state.recordType, text: readable,
                subject: nil, revision: revision))
        }
        return probes
    }
}

// MARK: - Findings

public enum BotMaintenanceFindingState: String, Codable, Sendable, Equatable {
    case verified
    case stale
    case disputed
    case unverifiable
}

public enum BotMaintenanceFindingReason: String, Codable, Sendable, Equatable {
    case evidenceUnresolved = "evidence-unresolved"
    case evidenceErased = "evidence-erased"
    case trustMismatch = "trust-mismatch"
    case sourceVersionChanged = "source-version-changed"
    case sourceVersionUnknown = "source-version-unknown"
    case sourceRevoked = "source-revoked"
    case sourceStatusUnknown = "source-status-unknown"
    case newerObservation = "newer-observation"
    case reviewStale = "review-stale"
    case reviewUnbacked = "review-unbacked"
    case reviewModelBasis = "review-model-basis"
    case unsupportedImportantFact = "unsupported-important-fact"
    case singleSignalFact = "single-signal-fact"
    case crossSignalMismatch = "cross-signal-mismatch"
    case conflictUndecidable = "conflict-undecidable"
    case conflictNotPreserved = "conflict-not-preserved"
    case userScopeWithoutUserEvidence = "user-scope-without-user-evidence"
}

public struct BotMaintenanceClaim: Codable, Sendable, Equatable {
    public var reference: String
    public var trust: String?
    public var observedAtMS: Int64?
    public var recordType: String?
    public var subject: String?
    public var revisionKind: String?
    public var revisionValue: String?

    public init(reference: String, trust: String? = nil,
                observedAtMS: Int64? = nil, recordType: String? = nil,
                subject: String? = nil, revisionKind: String? = nil,
                revisionValue: String? = nil) {
        self.reference = reference
        self.trust = trust
        self.observedAtMS = observedAtMS
        self.recordType = recordType
        self.subject = subject
        self.revisionKind = revisionKind
        self.revisionValue = revisionValue
    }

    enum CodingKeys: String, CodingKey {
        case reference = "ref"
        case trust
        case observedAtMS = "observed_at_ms"
        case recordType = "record_type"
        case subject
        case revisionKind = "revision_kind"
        case revisionValue = "revision_value"
    }
}

public struct BotMaintenanceDocumentVerification: Codable, Sendable, Equatable {
    public var path: String
    public var documentVersion: Int
    public var state: BotMaintenanceFindingState
    public var reasons: [BotMaintenanceFindingReason]
    public var references: [String]
    public var newerReferences: [String]
    public var preferredReference: String?
    public var claims: [BotMaintenanceClaim]
    public var checkedAtMS: Int64
    public var persistedReviewState: String?
    /// True when this document is on the batch's changed path and the host
    /// found a violation that must fail the batch.
    public var blocking: Bool

    public init(path: String, documentVersion: Int,
                state: BotMaintenanceFindingState,
                reasons: [BotMaintenanceFindingReason],
                references: [String], newerReferences: [String] = [],
                preferredReference: String? = nil,
                claims: [BotMaintenanceClaim] = [],
                checkedAtMS: Int64, persistedReviewState: String? = nil,
                blocking: Bool = false) {
        self.path = path
        self.documentVersion = documentVersion
        self.state = state
        self.reasons = reasons
        self.references = references
        self.newerReferences = newerReferences
        self.preferredReference = preferredReference
        self.claims = claims
        self.checkedAtMS = checkedAtMS
        self.persistedReviewState = persistedReviewState
        self.blocking = blocking
    }

    enum CodingKeys: String, CodingKey {
        case path
        case documentVersion = "document_version"
        case state, reasons, references, claims, blocking
        case newerReferences = "newer_refs"
        case preferredReference = "preferred_ref"
        case checkedAtMS = "checked_at_ms"
        case persistedReviewState = "persisted_review_state"
    }
}

public struct BotMaintenanceVerificationSummary: Codable, Sendable, Equatable {
    public var checked: Int
    public var verified: Int
    public var stale: Int
    public var disputed: Int
    public var unverifiable: Int
    public var blocking: Int
    public var findings: [BotMaintenanceDocumentVerification]

    public init(findings: [BotMaintenanceDocumentVerification]) {
        self.findings = findings
        self.checked = findings.count
        self.verified = findings.filter { $0.state == .verified }.count
        self.stale = findings.filter { $0.state == .stale }.count
        self.disputed = findings.filter { $0.state == .disputed }.count
        self.unverifiable = findings.filter { $0.state == .unverifiable }.count
        self.blocking = findings.filter(\.blocking).count
    }

    enum CodingKeys: String, CodingKey {
        case checked, verified, stale, disputed, unverifiable, blocking, findings
    }
}

// MARK: - Durable shape (frozen G-1 memory-maintenance.schema.json)

/// The subset the frozen `memory-maintenance.schema.json` accepts. The rich
/// finding stays internal/visual; only this shape is written to the durable
/// event, so extra diagnostics can never make the event fail schema.
public struct BotMaintenanceDurableFinding: Codable, Sendable, Equatable {
    public var path: String
    public var state: BotMaintenanceFindingState
    public var reasons: [String]
    public var references: [String]
    public var newerReferences: [String]
    public var preferredReference: String?

    public init(path: String, state: BotMaintenanceFindingState,
                reasons: [String], references: [String],
                newerReferences: [String] = [], preferredReference: String? = nil) {
        self.path = path
        self.state = state
        self.reasons = Array(Set(reasons)).sorted().prefix(8).map { $0 }
        self.references = Array(references.prefix(16))
        self.newerReferences = Array(newerReferences.prefix(8))
        self.preferredReference = preferredReference
    }

    enum CodingKeys: String, CodingKey {
        case path, state, reasons
        case references = "refs"
        case newerReferences = "newer_refs"
        case preferredReference = "preferred_ref"
    }
}

public struct BotMaintenanceDurableVerification: Codable, Sendable, Equatable {
    public var checked: Int
    public var verified: Int
    public var stale: Int
    public var disputed: Int
    public var unverifiable: Int
    public var blocking: Int
    public var findings: [BotMaintenanceDurableFinding]

    public init(checked: Int, verified: Int, stale: Int, disputed: Int,
                unverifiable: Int, blocking: Int,
                findings: [BotMaintenanceDurableFinding]) {
        self.checked = checked
        self.verified = verified
        self.stale = stale
        self.disputed = disputed
        self.unverifiable = unverifiable
        self.blocking = blocking
        self.findings = findings
    }

    enum CodingKeys: String, CodingKey {
        case checked, verified, stale, disputed, unverifiable, blocking, findings
    }
}

public extension BotMaintenanceVerificationSummary {
    /// Frozen durable projection. Unknown internal reasons collapse to the
    /// nearest frozen vocabulary item; an undecidable conflict whose both
    /// sides are cited keeps `disputed` with no invented reason.
    func durable() -> BotMaintenanceDurableVerification {
        let projected = findings.prefix(24).map { finding in
            BotMaintenanceDurableFinding(
                path: finding.path,
                state: finding.state,
                reasons: finding.reasons.compactMap(Self.durableReason),
                references: finding.references,
                newerReferences: finding.newerReferences,
                preferredReference: finding.preferredReference)
        }
        return BotMaintenanceDurableVerification(
            checked: min(24, findings.count),
            verified: verified, stale: stale, disputed: disputed,
            unverifiable: unverifiable, blocking: blocking,
            findings: projected)
    }

    static func durableReason(_ reason: BotMaintenanceFindingReason) -> String? {
        switch reason {
        case .evidenceUnresolved, .sourceRevoked, .reviewUnbacked:
            return BotMaintenanceFindingReason.evidenceUnresolved.rawValue
        case .sourceStatusUnknown:
            return BotMaintenanceFindingReason.sourceVersionUnknown.rawValue
        case .unsupportedImportantFact:
            return BotMaintenanceFindingReason.crossSignalMismatch.rawValue
        case .conflictUndecidable:
            // Both sides cited is a valid disputed outcome with no reason;
            // a missing side is reported as conflict-not-preserved.
            return nil
        default:
            return reason.rawValue
        }
    }
}

// MARK: - Request

public struct BotMaintenanceVerificationRequest: Sendable {
    public var documents: [BotMemoryDocument]
    public var callerBotID: String
    public var callerSessionID: String
    public var checkedAtMS: Int64
    /// Write-time baselines keyed by `record://` reference, captured from the
    /// batch's durable write events (`source_baseline`). Missing = old data.
    public var baselines: [String: BotMaintenanceSourceBaseline]
    /// Paths whose host recheck must be blocking (the batch's changed paths).
    public var strictPaths: Set<String>
    /// F: path -> references the user explicitly marked wrong/suppressed.
    public var disputedReferences: [String: [String]]
    /// L: current state of refs already known invalid from other paths.
    public var invalidatedReferences: [String: BotMaintenanceDependencyStatus]

    public init(documents: [BotMemoryDocument], callerBotID: String,
                callerSessionID: String, checkedAtMS: Int64,
                baselines: [String: BotMaintenanceSourceBaseline] = [:],
                strictPaths: Set<String> = [],
                disputedReferences: [String: [String]] = [:],
                invalidatedReferences: [String: BotMaintenanceDependencyStatus] = [:]) {
        self.documents = documents
        self.callerBotID = callerBotID
        self.callerSessionID = callerSessionID
        self.checkedAtMS = checkedAtMS
        self.baselines = baselines
        self.strictPaths = strictPaths
        self.disputedReferences = disputedReferences
        self.invalidatedReferences = invalidatedReferences
    }
}

// MARK: - Verifier

public struct BotMaintenanceEvidenceVerifier: Sendable {
    private let source: any BotMaintenanceSourceChecking

    public init(source: any BotMaintenanceSourceChecking) {
        self.source = source
    }

    public func verify(_ request: BotMaintenanceVerificationRequest)
        async throws -> BotMaintenanceVerificationSummary {
        let allReferences = Self.collectReferences(request)
        var probeByReference: [String: BotMaintenanceSourceProbe] = [:]
        if !allReferences.isEmpty {
            let probes = try await source.probe(
                references: allReferences,
                callerBotID: request.callerBotID,
                callerSessionID: request.callerSessionID)
            for probe in probes {
                probeByReference[BotMaintenanceReferenceKey.canonical(probe.reference)]
                    = probe
            }
        }
        var findings: [BotMaintenanceDocumentVerification] = []
        for document in request.documents {
            let finding = Self.verify(
                document: document, request: request,
                probeByReference: probeByReference)
            findings.append(finding)
        }
        return BotMaintenanceVerificationSummary(findings: findings)
    }

    // MARK: One document

    private static func verify(
        document: BotMemoryDocument,
        request: BotMaintenanceVerificationRequest,
        probeByReference: [String: BotMaintenanceSourceProbe]
    ) -> BotMaintenanceDocumentVerification {
        let strict = request.strictPaths.contains(document.path)
        var reasons: [BotMaintenanceFindingReason] = []
        var newerReferences: [String] = []
        var preferredReference: String?
        var claims: [BotMaintenanceClaim] = []
        var hardFailure = false
        var stale = false
        var disputed = false

        let evidence = canonicalUnique(document.evidence)
        let reviewRefs = canonicalUnique(document.review?.refs ?? [])
        let disputedRefs = canonicalUnique(
            request.disputedReferences[document.path] ?? [])
        let cited = canonicalUnique(evidence + reviewRefs)
        let considered = canonicalUnique(cited + disputedRefs)

        func probe(_ reference: String) -> BotMaintenanceSourceProbe? {
            probeByReference[BotMaintenanceReferenceKey.canonical(reference)]
        }

        // 1. Every cited reference must still resolve; erased never becomes
        //    valid again and is never resurrected by a later write.
        for reference in considered {
            guard let state = probe(reference) else {
                reasons.append(.evidenceUnresolved)
                hardFailure = true
                continue
            }
            switch state.current {
            case .erased:
                reasons.append(.evidenceErased)
                hardFailure = true
            case .unavailable:
                reasons.append(.evidenceUnresolved)
                hardFailure = true
            case .revoked:
                reasons.append(.sourceRevoked)
                hardFailure = true
            case .changed:
                reasons.append(.sourceVersionChanged)
                stale = true
            case .unknown:
                reasons.append(.sourceStatusUnknown)
                hardFailure = true
            case .current:
                break
            }
            if let invalidated = request.invalidatedReferences[
                BotMaintenanceReferenceKey.canonical(reference)] {
                switch invalidated.state {
                case .live:
                    break
                case .erased:
                    reasons.append(.evidenceErased)
                    hardFailure = true
                case .revoked:
                    reasons.append(.sourceRevoked)
                    hardFailure = true
                case .changed:
                    reasons.append(.sourceVersionChanged)
                    stale = true
                case .unknown:
                    reasons.append(.sourceStatusUnknown)
                    hardFailure = true
                }
            }
            if let claim = claim(for: state, baseline: request.baselines[reference]) {
                claims.append(claim)
            }
        }

        // 2. Trust is re-derived from the evidence, never from the writer's
        //    field. A mismatch fails closed.
        if !evidence.isEmpty {
            let derived = derivedTrust(evidence.compactMap { probe($0)?.trust })
            if let stored = document.trust, stored != derived.rawValue {
                reasons.append(.trustMismatch)
                hardFailure = true
            }
            if document.scope == .user
                && !evidence.contains(where: { probe($0)?.trust == .user }) {
                reasons.append(.userScopeWithoutUserEvidence)
                hardFailure = true
            }
        }

        // 3. Source revision against the write-time baseline. A missing
        //    revision on old data is explicit unknown, not verified.
        for reference in considered {
            guard let state = probe(reference) else { continue }
            let baseline = request.baselines[reference]
            if let baseline {
                if let baselineValue = baseline.revisionValue {
                    guard let current = state.revision?.value else {
                        reasons.append(.sourceVersionUnknown)
                        continue
                    }
                    if current != baselineValue {
                        reasons.append(.sourceVersionChanged)
                        stale = true
                        newerReferences.append(reference)
                    }
                } else {
                    reasons.append(.sourceVersionUnknown)
                }
            } else if state.revision == nil, state.trust == .observation {
                reasons.append(.sourceVersionUnknown)
            }
            if let observed = state.observedAtMS,
               let baselineObserved = baseline?.observedAtMS,
               observed > baselineObserved {
                newerReferences.append(reference)
            }
        }

        // 4. A review claim is a writer assertion; the host rechecks it.
        if let review = document.review {
            if review.basis == .modelInference {
                reasons.append(.reviewModelBasis)
                hardFailure = true
            }
            if review.state == .verified {
                if review.refs.isEmpty {
                    reasons.append(.reviewUnbacked)
                    hardFailure = true
                }
                for reference in reviewRefs {
                    guard let state = probe(reference) else {
                        reasons.append(.reviewUnbacked)
                        hardFailure = true
                        continue
                    }
                    if state.current != .current {
                        reasons.append(.reviewStale)
                        stale = true
                        continue
                    }
                    if let reviewedAt = review.atMS,
                       let observed = state.observedAtMS,
                       observed > reviewedAt {
                        reasons.append(.reviewStale)
                        stale = true
                    }
                }
                // A review decision that predates a source change is stale.
                if let reviewedAt = review.atMS {
                    for reference in evidence {
                        if let observed = probe(reference)?.observedAtMS,
                           observed > reviewedAt {
                            reasons.append(.reviewStale)
                            stale = true
                            newerReferences.append(reference)
                        }
                    }
                }
            }
            if review.state == .disputed {
                if review.refs.count < 2 {
                    reasons.append(.conflictNotPreserved)
                    disputed = true
                }
                for reference in reviewRefs where probe(reference)?.current != .current {
                    reasons.append(.conflictNotPreserved)
                    disputed = true
                }
            }
        }

        // 6. Cross-signal check for important facts learned from observation.
        if !evidence.isEmpty,
           derivedTrust(evidence.compactMap { probe($0)?.trust }) == .observation {
            let texts = evidence.compactMap { reference -> (String, String?)? in
                guard let state = probe(reference), let text = state.text else {
                    return nil
                }
                return (reference, text)
            }
            for fact in BotMaintenanceFacts.importantFacts(in: document.content) {
                let signals = Set(texts.compactMap { reference, text -> String? in
                    guard let text,
                          text.localizedCaseInsensitiveContains(fact) else {
                        return nil
                    }
                    return BotMaintenanceReferenceKey.signal(reference)
                })
                if signals.isEmpty {
                    reasons.append(.unsupportedImportantFact)
                    hardFailure = true
                } else if signals.count < 2 {
                    reasons.append(.singleSignalFact)
                    hardFailure = true
                }
            }
        }

        // 7. Group claims by subject (G-1 source baseline) and preserve an
        //    undecidable conflict instead of silently overwriting one side.
        let groups = Dictionary(grouping: claims.filter { $0.subject != nil },
                                by: { $0.subject! })
        for (_, group) in groups where group.count >= 2 {
            let values = Set(group.compactMap { $0.revisionValue })
            guard values.count >= 2 || group.contains(where: { $0.revisionValue == nil })
            else { continue }
            let preferred = preferredClaim(in: group)
            if let preferred {
                preferredReference = preferredReference ?? preferred.reference
                if !cited.contains(preferred.reference) {
                    reasons.append(.conflictNotPreserved)
                    disputed = true
                }
            } else {
                reasons.append(.conflictUndecidable)
                disputed = true
                let groupRefs = group.map(\.reference)
                if groupRefs.contains(where: { !cited.contains($0) }) {
                    reasons.append(.conflictNotPreserved)
                }
            }
        }

        // 7b. Feedback-disputed claims must keep the decisive side (or both
        //     sides when the host cannot order them) cited.
        if !disputedRefs.isEmpty {
            let required: [String]
            if let preferredReference,
               disputedRefs.contains(where: {
                   BotMaintenanceReferenceKey.canonical($0)
                       == BotMaintenanceReferenceKey.canonical(preferredReference)
               }) {
                required = [preferredReference]
            } else {
                required = disputedRefs
            }
            let missing = required.filter { !cited.contains($0) }
            if !missing.isEmpty {
                reasons.append(.conflictNotPreserved)
                disputed = true
            }
        }

        // 8. A doc may not claim verified when the host recheck failed.
        if document.review?.state == .verified, strict, hardFailure || stale || disputed {
            reasons.append(.reviewUnbacked)
        }

        let state: BotMaintenanceFindingState
        if hardFailure {
            state = .unverifiable
        } else if disputed {
            state = .disputed
        } else if stale {
            state = .stale
        } else {
            state = .verified
        }
        let blocking = strict
            && (state != .verified
                || reasons.contains(.conflictNotPreserved)
                || reasons.contains(.userScopeWithoutUserEvidence))
        return BotMaintenanceDocumentVerification(
            path: document.path,
            documentVersion: document.version,
            state: state,
            reasons: Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue },
            references: cited,
            newerReferences: Array(Set(newerReferences)).sorted(),
            preferredReference: preferredReference,
            claims: claims,
            checkedAtMS: request.checkedAtMS,
            persistedReviewState: document.review?.state.rawValue,
            blocking: blocking)
    }

    // MARK: Helpers

    private static func collectReferences(
        _ request: BotMaintenanceVerificationRequest
    ) -> [String] {
        var all: [String] = []
        for document in request.documents {
            all.append(contentsOf: document.evidence)
            all.append(contentsOf: document.review?.refs ?? [])
            all.append(contentsOf: request.disputedReferences[document.path] ?? [])
        }
        return canonicalUnique(all)
    }

    private static func canonicalUnique(_ references: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for reference in references {
            let key = BotMaintenanceReferenceKey.canonical(reference)
            guard seen.insert(key).inserted else { continue }
            result.append(reference)
        }
        return result
    }

    private static func claim(
        for state: BotMaintenanceSourceProbe,
        baseline: BotMaintenanceSourceBaseline?
    ) -> BotMaintenanceClaim? {
        let subject = state.subject ?? baseline?.subject
        guard subject != nil || state.revision != nil
            || state.recordType != nil else { return nil }
        return BotMaintenanceClaim(
            reference: state.reference,
            trust: state.trust?.rawValue,
            observedAtMS: state.observedAtMS,
            recordType: state.recordType,
            subject: subject,
            revisionKind: state.revision?.kind ?? baseline?.revisionKind,
            revisionValue: state.revision?.value ?? baseline?.revisionValue)
    }

    static func derivedTrust(_ trusts: [BotRecordTrust]) -> BotRecordTrust {
        if trusts.contains(.user) { return .user }
        if trusts.contains(.observation) { return .observation }
        return .assistant
    }

    private static func preferredClaim(in claims: [BotMaintenanceClaim])
        -> BotMaintenanceClaim? {
        func rank(_ claim: BotMaintenanceClaim) -> Int {
            switch claim.trust {
            case BotRecordTrust.user.rawValue: return 3
            case BotRecordTrust.observation.rawValue: return 2
            default: return 1
            }
        }
        let ranked = claims.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) > rank(rhs) }
            return (lhs.observedAtMS ?? -1) > (rhs.observedAtMS ?? -1)
        }
        guard let first = ranked.first else { return nil }
        let tied = ranked.filter {
            rank($0) == rank(first)
                && ($0.observedAtMS ?? -1) == (first.observedAtMS ?? -1)
        }
        guard tied.count == 1 else { return nil }
        return first
    }
}

// MARK: - Reference keys

enum BotMaintenanceReferenceKey {
    /// Canonical key used to match a probe back to a citation. The record
    /// service already canonicalizes; this keeps the comparison stable for
    /// simple test doubles as well.
    static func canonical(_ reference: String) -> String {
        if let parsed = BotRecordReference.canonicalize(reference) {
            return parsed
        }
        return reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Independence key for cross-signal checks: two lines of the same session
    /// are one signal (one ASR stream), a durable event is its own signal.
    static func signal(_ reference: String) -> String {
        let canonical = canonical(reference)
        guard canonical.hasPrefix("record://session/") else { return canonical }
        let rest = canonical.dropFirst("record://session/".count)
        guard let hash = rest.firstIndex(of: "#") else { return canonical }
        return "session:" + String(rest[..<hash])
    }
}

// MARK: - Important fact extraction

enum BotMaintenanceFacts {
    private static let numberExpression = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])[0-9]+(?:[.,:：][0-9]+)*(?:[%％])?"#)
    private static let quotedExpression = try? NSRegularExpression(
        pattern: #"[「『“"]([^」』”"]{1,40})[」』”"]"#)
    private static let identifierExpression = try? NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9_.\-]{2,}"#)
    private static let emailExpression = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let urlExpression = try? NSRegularExpression(
        pattern: #"https?://[^\s，。；、）)]+"#)

    /// Conservative, domain-free extraction of facts that must be traceable:
    /// numbers (with optional unit-like suffix), quoted spans, URL/e-mail and
    /// identifier-like tokens that carry a digit, underscore or dot. Common
    /// words are not treated as facts.
    static func importantFacts(in text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var facts: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 1, value.count <= 80 else { return }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return }
            facts.append(value)
        }

        if let expression = urlExpression {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                add(ns.substring(with: match.range))
            }
        }
        if let expression = emailExpression {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                add(ns.substring(with: match.range))
            }
        }
        if let expression = quotedExpression {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                add(ns.substring(with: match.range(at: 1)))
            }
        }
        if let expression = numberExpression {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                add(ns.substring(with: match.range))
            }
        }
        if let expression = identifierExpression {
            expression.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                let token = ns.substring(with: match.range)
                let hasDigit = token.contains(where: \.isNumber)
                let hasSeparator = token.contains("_") || token.contains(".")
                    || token.contains("-")
                guard hasDigit || hasSeparator else { return }
                add(token)
            }
        }
        return Array(facts.prefix(32))
    }
}
