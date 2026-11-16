// SPDX-License-Identifier: MIT

import Foundation

struct BotProvenanceAssertion: Sendable, Equatable {
    struct Review: Sendable, Equatable {
        var state: String
        var basis: String?
    }

    var artifact: BotDerivedRef
    var sources: [BotDerivationSource]
    var basis: String?
    var carrierSeq: Int
    var carrierRecord: String
    var eventType: String
    var botID: String?
    var sessionID: String?
    var review: Review?
}

struct BotProvenanceObservation: Sendable, Equatable {
    var ref: String
    var observedAtMS: Int64
    var version: BotProvenanceSourceVersion?
    var resource: BotResourceIdentity?
}

/// Immutable read model over durable events. It owns no durable state: the same
/// events rebuild the same view. `derivation` is an optional member of the
/// artifact's own carrier event; no carrier field is written or trusted.
public struct BotProvenanceSnapshot: Sendable {
    public static let maximumDepth = 8
    public static let maximumObjects = 10_000
    public static let maximumObservationEvents = 10_000
    public static let maximumObservationIdentities = 32

    let assertions: [BotDerivedRef: [BotProvenanceAssertion]]
    let carrierByName: [String: BotDerivedRef]
    let bySource: [String: Set<BotDerivedRef>]
    let eventFacts: [String: BotProvenanceResolvedFacts]
    let erasedRecords: Set<String>
    let revokedGrants: [String: Int]
    let observations: [String: [BotProvenanceObservation]]
    /// Same kind+key, possibly different owner/scope, for scope mismatch.
    let observationsByKindKey: [String: [BotProvenanceObservation]]
    /// Source ref -> resource identity, built from durable observation carriers
    /// only (including session refs named by a DSH origin).
    let observationResourceByRef: [String: BotResourceIdentity]
    let scanLimitExceeded: Bool
    let cyclicArtifacts: Set<BotDerivedRef>
    let artifactByCarrier: [String: BotDerivedRef]
    public let generation: BotProvenanceGeneration

    public var referencedRecords: [String] { bySource.keys.sorted() }

    public func artifacts() -> [BotDerivedRef] { assertions.keys.sorted() }

    public func derivedRefs(forEventID eventID: String, eventIDToSeq: [String: Int]) -> [BotDerivedRef] {
        guard let seq = eventIDToSeq[eventID] else { return [] }
        let record = "record://event/\(seq)"
        return assertions.values.compactMap { list in
            list.first(where: { $0.carrierRecord == record })?.artifact
        }.sorted()
    }

    /// One view for one artifact. `facts` must already contain every referenced
    /// record the host can resolve; event records have a built-in fallback.
    func view(for artifact: BotDerivedRef,
              facts: [String: BotProvenanceResolvedFacts]) -> BotDerivationView {
        var memo: [BotDerivedRef: BotDerivationView] = [:]
        var stack: [BotDerivedRef] = []
        var objects = 0
        return makeView(artifact, facts: facts, memo: &memo, stack: &stack, depth: 0,
                        objects: &objects)
    }

    func sourceStatuses(for artifact: BotDerivedRef,
                        facts: [String: BotProvenanceResolvedFacts]) -> [BotSourceStatus] {
        guard let assertion = latestAssertion(for: artifact) else { return [] }
        return statuses(for: assertion, facts: facts)
    }

    /// M's read-only view for arbitrary refs (evidence ∪ review.refs). Without
    /// an artifact baseline this is the no-baseline branch: observations are
    /// unknown/no-baseline, non-observations are current.
    func sourceStatuses(for refs: [String],
                        facts: [String: BotProvenanceResolvedFacts]) -> [String: BotSourceStatus] {
        var result: [String: BotSourceStatus] = [:]
        for raw in refs {
            let canonical = BotRecordReference.canonicalize(raw) ?? raw
            guard result[canonical] == nil else { continue }
            let resolvedFacts = facts[canonical] ?? eventFacts[canonical]
            result[canonical] = status(
                ref: canonical, roles: ["evidence"], baseline: nil, grantId: nil,
                carrierSeq: Int.max, explicitResource: nil, facts: resolvedFacts)
        }
        return result
    }

    func trace(_ record: String,
               facts: [String: BotProvenanceResolvedFacts]) -> [BotDerivationView] {
        let canonical = BotRecordReference.canonicalize(record) ?? record
        var found = Set<BotDerivedRef>()
        var queue: [(String, Int)] = [(canonical, 0)]
        var visited = Set<String>()
        var truncated = false
        while let (ref, depth) = queue.first {
            queue.removeFirst()
            guard visited.insert(ref).inserted else { continue }
            if depth > Self.maximumDepth { truncated = true; continue }
            for artifact in bySource[ref] ?? [] {
                guard found.insert(artifact).inserted else { continue }
                if found.count > Self.maximumObjects { truncated = true; break }
                if let assertion = latestAssertion(for: artifact) {
                    queue.append((assertion.carrierRecord, depth + 1))
                }
            }
        }
        return found.sorted().map { artifact in
            var view = self.view(for: artifact, facts: facts)
            if truncated { view.truncated = true }
            return view
        }
    }

    public func reverseTrace(for artifact: BotDerivedRef) -> [BotDerivation] {
        (assertions[artifact] ?? []).map {
            BotDerivation(artifact: $0.artifact, sources: $0.sources, basis: $0.basis)
        }
    }

    func invalidated(sourceRefs: [String], reason: BotInvalidationReason,
                     facts: [String: BotProvenanceResolvedFacts])
        -> BotInvalidationResult {
        var canonical: [String] = []
        var unresolved: [String] = []
        for raw in sourceRefs {
            guard let ref = BotRecordReference.canonicalize(raw) else {
                unresolved.append(raw)
                continue
            }
            if !canonical.contains(ref) { canonical.append(ref) }
        }
        var affected = Set<BotDerivedRef>()
        var queue = canonical
        while let ref = queue.popLast() {
            for artifact in bySource[ref] ?? [] {
                guard affected.insert(artifact).inserted else { continue }
                if let assertion = latestAssertion(for: artifact) {
                    queue.append(assertion.carrierRecord)
                }
            }
        }
        var states: [BotDerivationView] = []
        for artifact in affected.sorted() {
            var view = self.view(for: artifact, facts: facts)
            if reason.status.severity >= view.state.severity {
                view.state = reason.status
                view.reasons = [reason.reason]
            }
            states.append(view)
        }
        for ref in canonical {
            let status = self.status(ref: ref, roles: ["evidence"], baseline: nil,
                                     grantId: nil, carrierSeq: Int.max,
                                     explicitResource: nil,
                                     facts: facts[ref] ?? eventFacts[ref])
            if !status.resolved || status.state == .unavailable {
                if !unresolved.contains(ref) { unresolved.append(ref) }
            }
        }
        return BotInvalidationResult(
            sourceRefs: canonical, affected: states.map(\.artifact), states: states,
            unresolvedSources: unresolved, generation: generation)
    }

    // MARK: - status

    private func statuses(for assertion: BotProvenanceAssertion,
                          facts: [String: BotProvenanceResolvedFacts]) -> [BotSourceStatus] {
        assertion.sources.map { source in
            let canonical = BotRecordReference.canonicalize(source.record) ?? source.record
            return status(ref: canonical,
                          roles: [source.role?.rawValue ?? "basis"],
                          baseline: source.sourceVersion, grantId: source.grantId,
                          carrierSeq: assertion.carrierSeq,
                          explicitResource: source.resource,
                          facts: facts[canonical] ?? eventFacts[canonical])
        }
    }

    /// The single current-state decision (provenance.md §4.3 order, r6).
    private func status(ref: String, roles: [String],
                        baseline: BotProvenanceSourceVersion?,
                        grantId: String?, carrierSeq: Int,
                        explicitResource: BotResourceIdentity?,
                        facts: BotProvenanceResolvedFacts?) -> BotSourceStatus {
        var status = BotSourceStatus(
            ref: ref, roles: roles.sorted(), resolved: false, erased: false,
            state: .current, reasons: [], observedAtMS: nil, recordType: nil,
            trust: nil, sourceVersion: baseline, latestRef: nil, baseline: baseline)
        guard let facts else {
            status.state = .unavailable
            status.reasons = [.recordUnresolved]
            return status
        }
        status.resolved = facts.resolved
        status.erased = facts.erased
        status.observedAtMS = facts.observedAtMS
        status.recordType = facts.recordType
        status.trust = facts.trust
        guard facts.resolved else {
            status.state = .unavailable
            status.reasons = [.recordUnresolved]
            return status
        }
        if facts.erased {
            status.state = .erased
            status.reasons = [.recordErased]
            return status
        }
        if facts.scanLimitExceeded, facts.isObservation, baseline != nil {
            status.state = .unknown
            status.reasons = [.scanLimitExceeded]
            return status
        }
        if let grantId, let revoked = revokedGrants[Self.normalizedGrant(grantId)],
           revoked > carrierSeq {
            status.state = .revoked
            status.reasons = [.grantRevoked]
            return status
        }
        let isObservation = facts.isObservation || facts.currentVersion != nil
        if let current = facts.currentVersion, baseline == nil, isObservation {
            status.sourceVersion = current
        }
        if let baseline, case let .unknown(reason, _, _) = baseline {
            switch reason {
            case .recordUnresolved, .invalidReference:
                status.state = .unavailable
                status.reasons = [.recordUnresolved]
            case .recordErased:
                status.erased = true
                status.state = .erased
                status.reasons = [.recordErased]
            case .recordWithoutContent, .sourceUnversioned:
                status.state = .unknown
                status.reasons = [.sourceVersionUnknown]
            }
            return status
        }
        if !isObservation {
            status.state = .current
            return status
        }
        if baseline == nil {
            status.state = .unknown
            status.reasons = [.noBaseline]
            return status
        }
        guard let resource = explicitResource ?? facts.resource else {
            status.state = .unknown
            status.reasons = [.noResourceIdentity]
            return status
        }
        status.resource = resource
        let observedAt = facts.observedAtMS ?? 0
        // Same kind+key under a different owner/scope is a different
        // authorization domain, not a newer version of this resource.
        let kindEntries = observationsByKindKey[resource.kindKey] ?? []
        if let mismatch = kindEntries.last(where: { entry in
            entry.resource?.canonical != resource.canonical
                && isNewer(entry, thanAt: observedAt, ref: ref)
        }) {
            _ = mismatch
            status.state = .unknown
            status.reasons = [.resourceScopeMismatch]
            return status
        }
        let sameResource = (observations[resource.canonical] ?? [])
            .filter { $0.ref != ref }
        if let latest = sameResource.last,
           isNewer(latest, thanAt: observedAt, ref: ref) {
            let latestRef = facts.latestRef ?? latest.ref
            status.latestRef = latestRef
            guard let latestVersion = facts.latestVersion ?? latest.version else {
                status.state = .unknown
                status.reasons = [.newerObservationUnversioned]
                return status
            }
            guard let baseline else {
                status.state = .unknown
                status.reasons = [.noBaseline]
                return status
            }
            if case let .known(base) = baseline,
               case let .known(latestKnown) = latestVersion {
                if base.basis != latestKnown.basis {
                    status.state = .unknown
                    status.reasons = [.revisionBasisMismatch]
                } else if base.value != latestKnown.value {
                    status.state = .changed
                    status.reasons = [.sourceChanged]
                } else {
                    status.state = .current
                    status.reasons = []
                }
                return status
            }
            status.state = .unknown
            status.reasons = [.newerObservationUnversioned]
            return status
        }
        // No newer observation is not freshness. A real recheck is required.
        switch facts.recheckOutcome ?? .notPerformed {
        case let .same(atMS):
            status.state = .current
            status.recheckedAtMS = atMS
        case let .changed(version, _):
            if case let .known(base) = baseline,
               case let .known(newKnown) = version {
                if base.basis != newKnown.basis {
                    status.state = .unknown
                    status.reasons = [.revisionBasisMismatch]
                } else if base.value != newKnown.value {
                    status.state = .changed
                    status.reasons = [.sourceChanged]
                } else {
                    status.state = .current
                }
            } else {
                status.state = .unknown
                status.reasons = [.newerObservationUnversioned]
            }
        case .revisionBasisMismatch:
            status.state = .unknown
            status.reasons = [.revisionBasisMismatch]
        case .denied:
            status.state = .unknown
            status.reasons = [.refreshDenied]
        case .unavailable:
            status.state = .unknown
            status.reasons = [.refreshUnavailable]
        case .notPerformed:
            status.state = .unknown
            status.reasons = [.refreshNotPerformed]
        }
        return status
    }

    private func isNewer(_ entry: BotProvenanceObservation,
                         thanAt observedAt: Int64, ref: String) -> Bool {
        entry.observedAtMS > observedAt
            || (entry.observedAtMS == observedAt
                && Self.recordOrder(entry.ref) > Self.recordOrder(ref))
    }

    // MARK: - view

    private func makeView(_ artifact: BotDerivedRef,
                          facts: [String: BotProvenanceResolvedFacts],
                          memo: inout [BotDerivedRef: BotDerivationView],
                          stack: inout [BotDerivedRef],
                          depth: Int, objects: inout Int) -> BotDerivationView {
        if let cached = memo[artifact] { return cached }
        let generation = self.generation
        if depth > Self.maximumDepth || objects > Self.maximumObjects {
            return BotDerivationView(
                artifact: artifact, carrier: nil, state: .unavailable,
                reasons: [.recordUnresolved], sources: [],
                reviewEffective: .init(state: .unknown), upstream: [],
                generation: generation, truncated: true)
        }
        objects += 1
        guard let assertion = latestAssertion(for: artifact) else {
            let reasons: [BotProvenanceReason] = artifact.kind == .skill
                ? [.noSkillWriteEvent] : [.noDerivation]
            let view = BotDerivationView(
                artifact: artifact, carrier: nil, state: .unknown, reasons: reasons,
                sources: [], reviewEffective: .init(state: .unknown), upstream: [],
                generation: generation)
            memo[artifact] = view
            return view
        }
        stack.append(artifact)
        defer { stack.removeLast() }

        var sourceViews: [BotDerivationSourceView] = []
        var upstream: [BotUpstreamView] = []
        for source in assertion.sources {
            let ref = BotRecordReference.canonicalize(source.record) ?? source.record
            let sourceStatus = status(
                ref: ref, roles: [source.role?.rawValue ?? "basis"],
                baseline: source.sourceVersion, grantId: source.grantId,
                carrierSeq: assertion.carrierSeq,
                explicitResource: source.resource,
                facts: facts[ref] ?? eventFacts[ref])
            sourceViews.append(BotDerivationSourceView(
                record: ref, role: source.role?.rawValue ?? "basis", status: sourceStatus))
            if let upstreamArtifact = artifactByCarrier[ref] {
                guard upstreamArtifact != artifact,
                      !stack.contains(upstreamArtifact) else { continue }
                let nested = makeView(upstreamArtifact, facts: facts, memo: &memo,
                                      stack: &stack, depth: depth + 1, objects: &objects)
                upstream.append(BotUpstreamView(
                    artifact: nested.artifact, state: nested.state))
            }
        }
        sourceViews.sort { ($0.record, $0.role) < ($1.record, $1.role) }
        upstream.sort {
            ($0.artifact.kind.rawValue, $0.artifact.id, $0.artifact.version ?? 0)
                < ($1.artifact.kind.rawValue, $1.artifact.id, $1.artifact.version ?? 0)
        }
        let states = sourceViews.map(\.status.state) + upstream.map(\.state)
        var state = states.isEmpty ? BotProvenanceStatus.current : BotProvenanceStatus.worst(states)
        var reasonSet = Set(sourceViews.flatMap(\.status.reasons))
        if upstream.contains(where: { $0.state != .current }) {
            reasonSet.insert(.upstreamInvalidated)
        }
        if artifact.kind == .skill {
            state = .unknown
            reasonSet = [.noSkillWriteEvent]
        } else if sourceViews.isEmpty {
            state = .unknown
            reasonSet = [.noDerivation]
        }
        var view = BotDerivationView(
            artifact: artifact, carrier: assertion.carrierRecord, state: state,
            reasons: reasonSet.sorted { $0.rawValue < $1.rawValue },
            sources: sourceViews, reviewEffective: reviewEffective(
                assertion.review, state: state,
                reasons: reasonSet.sorted { $0.rawValue < $1.rawValue }),
            upstream: upstream, generation: generation)

        if cyclicArtifacts.contains(artifact) {
            let members = cycleMembers(containing: artifact)
            view.state = .unavailable
            view.reasons = [.cycleDetected]
            view.reviewEffective = .init(state: .unknown, reasons: [.cycleDetected])
            view.upstream = members.filter { $0 != artifact }.map {
                BotUpstreamView(artifact: $0, state: .unavailable)
            }.sorted {
                ($0.artifact.kind.rawValue, $0.artifact.id, $0.artifact.version ?? 0)
                    < ($1.artifact.kind.rawValue, $1.artifact.id, $1.artifact.version ?? 0)
            }
        }
        memo[artifact] = view
        return view
    }

    private func reviewEffective(_ review: BotProvenanceAssertion.Review?,
                                 state: BotProvenanceStatus,
                                 reasons: [BotProvenanceReason]) -> BotReviewEffective {
        guard let review else { return .init(state: .unknown) }
        switch review.state {
        case "disputed":
            return .init(state: .disputed, reasons: reasons)
        case "unverified":
            return .init(state: .unverified,
                         reasons: review.basis == "model-inference" ? [.reviewModelBasis] : [])
        case "verified":
            if state == .current {
                return .init(state: .verified)
            }
            return .init(state: .unverified, reasons: reasons)
        default:
            return .init(state: .unknown)
        }
    }

    private func latestAssertion(for artifact: BotDerivedRef) -> BotProvenanceAssertion? {
        guard let list = assertions[artifact] else { return nil }
        if let version = artifact.version {
            return list.last { $0.artifact.version == version }
        }
        return list.last
    }

    private func cycleMembers(containing artifact: BotDerivedRef) -> [BotDerivedRef] {
        // Tarjan SCC results are precomputed into cyclicArtifacts; recovering
        // the exact member set is cheap for the display path.
        var members: Set<BotDerivedRef> = [artifact]
        var changed = true
        while changed {
            changed = false
            for candidate in assertions.keys where !members.contains(candidate) {
                if reaches(candidate, target: artifact, visited: []) {
                    members.insert(candidate)
                    changed = true
                }
            }
        }
        return members.sorted()
    }

    private func reaches(_ from: BotDerivedRef, target: BotDerivedRef,
                         visited: Set<BotDerivedRef>) -> Bool {
        guard !visited.contains(from), visited.count < Self.maximumObjects else { return false }
        guard let assertion = latestAssertion(for: from) else { return false }
        var nextVisited = visited
        nextVisited.insert(from)
        for source in assertion.sources {
            let ref = BotRecordReference.canonicalize(source.record) ?? source.record
            guard let upstream = artifactByCarrier[ref] else { continue }
            if upstream == target { return true }
            if reaches(upstream, target: target, visited: nextVisited) { return true }
        }
        return false
    }

    private static func normalizedGrant(_ raw: String) -> String {
        raw.hasPrefix("grant:") ? String(raw.dropFirst("grant:".count)) : raw
    }

    private static func recordOrder(_ ref: String) -> String {
        if ref.hasPrefix("record://event/") {
            let seq = Int(ref.split(separator: "/").last ?? "") ?? 0
            return String(format: "1|%012d|", seq)
        }
        let tail = ref.replacingOccurrences(of: "record://session/", with: "")
        let parts = tail.split(separator: "#", maxSplits: 1).map(String.init)
        let session = parts.first ?? ""
        let seq = Int(parts.last ?? "") ?? 0
        return "0|\(String(format: "%012d", seq))|\(session)"
    }
}

// MARK: - building

extension BotProvenanceSnapshot {
    public static func build(events raw: [BotEvent]) -> BotProvenanceSnapshot {
        let durable = raw.compactMap { event -> BotEvent? in
            guard let seq = event.commitSeq, seq >= 1 else { return nil }
            return event
        }.sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }

        var bySeq: [Int: BotEvent] = [:]
        for event in durable {
            guard let seq = event.commitSeq, bySeq[seq] == nil else { continue }
            bySeq[seq] = event
        }
        var erased = Set<String>()
        var revoked: [String: Int] = [:]
        var lastErasureSeq = 0
        var lastGrantSeq = 0
        var observations: [String: [BotProvenanceObservation]] = [:]
        var observationsByKindKey: [String: [BotProvenanceObservation]] = [:]
        var observationResourceByRef: [String: BotResourceIdentity] = [:]
        var observationEvents = 0
        var eventFacts: [String: BotProvenanceResolvedFacts] = [:]
        var assertionMap: [BotDerivedRef: [BotProvenanceAssertion]] = [:]
        var eventIDToSeq: [String: Int] = [:]
        for event in bySeq.values {
            if let seq = event.commitSeq, eventIDToSeq[event.eventId] == nil {
                eventIDToSeq[event.eventId] = seq
            }
        }

        for event in bySeq.values.sorted(by: { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }) {
            guard let seq = event.commitSeq else { continue }
            let record = "record://event/\(seq)"
            if event.isErasedPayload { erased.insert(record) }
            switch event.type {
            case "erasure":
                lastErasureSeq = max(lastErasureSeq, seq)
                erased.formUnion(erasureRecords(event))
            case "grant.revoked":
                lastGrantSeq = max(lastGrantSeq, seq)
                for id in grantIDs(event) {
                    revoked[normalizedGrant(id)] = max(revoked[normalizedGrant(id)] ?? 0, seq)
                }
            default:
                break
            }
            var facts = BotProvenanceResolvedFacts(
                resolved: true, erased: erased.contains(record), isObservation: false,
                observedAtMS: event.time > 0 ? event.time : nil,
                recordType: event.type, trust: trust(for: event.type),
                currentVersion: nil, identity: nil, latestRef: nil,
                latestObservedAtMS: nil, latestVersion: nil,
                resource: nil, recheckOutcome: nil, scanLimitExceeded: false)
            if let observation = carrierObservation(for: event) {
                facts.isObservation = true
                if observation.aliases.contains(record) {
                    facts.currentVersion = observation.version
                    facts.observedAtMS = observation.observedAtMS
                    facts.resource = observation.resource
                }
                if let resource = observation.resource {
                    let entry = BotProvenanceObservation(
                        ref: observation.sourceRef,
                        observedAtMS: observation.observedAtMS,
                        version: observation.version, resource: resource)
                    observations[resource.canonical, default: []].append(entry)
                    observationsByKindKey[resource.kindKey, default: []].append(entry)
                    for alias in Set(observation.aliases) {
                        observationResourceByRef[alias] = resource
                    }
                    observationEvents += 1
                }
            }
            facts.erased = erased.contains(record)
            eventFacts[record] = facts

            if let derivation = decodeDerivation(event.data["derivation"]) {
                let review = decodeReview(event.data["review"])
                var sources = derivation.sources
                // G-1 §1.3: review_effective must consider evidence ∪
                // review.refs. A writer that put a review ref only in `review`
                // still gets it checked as a source (role review).
                for ref in reviewRefs(event.data["review"]) {
                    guard let canonical = BotRecordReference.canonicalize(ref),
                          !sources.contains(where: {
                              BotRecordReference.canonicalize($0.record) == canonical
                          }) else { continue }
                    sources.append(BotDerivationSource(record: canonical, role: .review))
                }
                let assertion = BotProvenanceAssertion(
                    artifact: derivation.artifact, sources: sources,
                    basis: derivation.basis, carrierSeq: seq, carrierRecord: record,
                    eventType: event.type, botID: event.principal.botId,
                    sessionID: event.principal.sessionId,
                    review: review)
                assertionMap[derivation.artifact, default: []].append(assertion)
                continue
            }
            for assertion in fallbackAssertions(
                event, record: record, eventIDToSeq: eventIDToSeq) {
                assertionMap[assertion.artifact, default: []].append(assertion)
            }
        }

        // Erasure may appear after the event it covers; rebuild erased flags
        // from the final set instead of the incremental view.
        for record in Array(eventFacts.keys) where erased.contains(record) {
            eventFacts[record]?.erased = true
        }
        var sortedAssertions: [BotDerivedRef: [BotProvenanceAssertion]] = [:]
        for (artifact, list) in assertionMap {
            sortedAssertions[artifact] = list.sorted { $0.carrierSeq < $1.carrierSeq }
        }
        var bySource: [String: Set<BotDerivedRef>] = [:]
        var artifactByCarrier: [String: BotDerivedRef] = [:]
        for (artifact, list) in sortedAssertions {
            for assertion in list {
                for source in assertion.sources {
                    bySource[BotRecordReference.canonicalize(source.record) ?? source.record,
                            default: []].insert(artifact)
                }
                artifactByCarrier[assertion.carrierRecord] = artifact
            }
        }
        var dependencies: [BotDerivedRef: Set<BotDerivedRef>] = [:]
        for (artifact, list) in sortedAssertions {
            for assertion in list {
                for source in assertion.sources {
                    let ref = BotRecordReference.canonicalize(source.record) ?? source.record
                    if let upstream = artifactByCarrier[ref], upstream != artifact {
                        dependencies[artifact, default: []].insert(upstream)
                    }
                }
            }
        }
        let cyclic = stronglyConnectedCycles(dependencies)
        let observationIndex = observations.mapValues(Self.sortedObservations)
        let kindKeyIndex = observationsByKindKey.mapValues(Self.sortedObservations)
        let scanExceeded = observationEvents > maximumObservationEvents
            || observationIndex.count > maximumObservationIdentities
        let head = bySeq.keys.max() ?? 0
        return BotProvenanceSnapshot(
            assertions: sortedAssertions,
            carrierByName: [:],
            bySource: bySource,
            eventFacts: eventFacts,
            erasedRecords: erased,
            revokedGrants: revoked,
            observations: observationIndex,
            observationsByKindKey: kindKeyIndex,
            observationResourceByRef: observationResourceByRef,
            scanLimitExceeded: scanExceeded,
            cyclicArtifacts: cyclic,
            artifactByCarrier: artifactByCarrier,
            generation: BotProvenanceGeneration(
                headCommitSeq: head, lastErasureSeq: lastErasureSeq,
                lastGrantSeq: lastGrantSeq))
    }

    // MARK: extraction

    private static func fallbackAssertions(
        _ event: BotEvent, record: String, eventIDToSeq: [String: Int]
    ) -> [BotProvenanceAssertion] {
        let review = decodeReview(event.data["review"])
        switch event.type {
        case "memory.document_written", "memory.document_deleted":
            guard let path = event.data["path"]?.stringValue,
                  let version = event.data["version"]?.intValue, version >= 1 else { return [] }
            var sources = stringRefs(event.data["evidence"]).map {
                BotDerivationSource(record: $0, role: .evidence)
            }
            sources.append(contentsOf: reviewRefs(event.data["review"]).map {
                BotDerivationSource(record: $0, role: .review)
            })
            return [BotProvenanceAssertion(
                artifact: BotDerivedRef(kind: .memory, id: path, version: version),
                sources: dedupe(sources), basis: nil, carrierSeq: event.commitSeq ?? 0,
                carrierRecord: record, eventType: event.type,
                botID: event.principal.botId, sessionID: event.principal.sessionId,
                review: review)]
        case "memory.review_requested":
            guard let path = event.data["path"]?.stringValue else { return [] }
            let version = event.data["version"]?.intValue
            let sources = stringRefs(event.data["evidence"]).map {
                BotDerivationSource(record: $0, role: .evidence)
            }
            return [BotProvenanceAssertion(
                artifact: BotDerivedRef(kind: .review, id: path, version: version),
                sources: dedupe(sources), basis: nil, carrierSeq: event.commitSeq ?? 0,
                carrierRecord: record, eventType: event.type,
                botID: event.principal.botId, sessionID: event.principal.sessionId,
                review: review)]
        case "memory.review_resolved":
            guard let path = event.data["path"]?.stringValue else { return [] }
            return [BotProvenanceAssertion(
                artifact: BotDerivedRef(kind: .review, id: path), sources: [],
                basis: nil, carrierSeq: event.commitSeq ?? 0, carrierRecord: record,
                eventType: event.type, botID: event.principal.botId,
                sessionID: event.principal.sessionId, review: review)]
        case "routine.defined", "routine.updated", "routine.deleted":
            guard let document = event.data["document"],
                  let routines = document["routines"]?.arrayValue else { return [] }
            var result: [BotProvenanceAssertion] = []
            for routine in routines {
                guard let id = routine["id"]?.stringValue, !id.isEmpty else { continue }
                var sources: [BotDerivationSource] = []
                if let causation = event.causationId,
                   let seq = eventIDToSeq[causation] {
                    sources.append(BotDerivationSource(
                        record: "record://event/\(seq)", role: .creator))
                }
                result.append(BotProvenanceAssertion(
                    artifact: BotDerivedRef(kind: .routine, id: id), sources: sources,
                    basis: nil, carrierSeq: event.commitSeq ?? 0, carrierRecord: record,
                    eventType: event.type, botID: event.principal.botId,
                    sessionID: event.principal.sessionId, review: nil))
            }
            return result
        case "proactive.considered":
            let sources = structuredRefs(event.data).map {
                BotDerivationSource(record: $0, role: .trigger)
            }
            return [BotProvenanceAssertion(
                artifact: BotDerivedRef(kind: .proactive, id: event.eventId),
                sources: dedupe(sources), basis: nil, carrierSeq: event.commitSeq ?? 0,
                carrierRecord: record, eventType: event.type,
                botID: event.principal.botId, sessionID: event.principal.sessionId,
                review: nil)]
        case "card.presented", "ui.send_to_user", "comm.outbound":
            let kind: BotDerivedKind = event.type == "ui.send_to_user"
                ? .notification : .delivery
            let sources = structuredRefs(event.data).map {
                BotDerivationSource(record: $0, role: .evidence)
            }
            return [BotProvenanceAssertion(
                artifact: BotDerivedRef(kind: kind, id: event.eventId),
                sources: dedupe(sources), basis: nil, carrierSeq: event.commitSeq ?? 0,
                carrierRecord: record, eventType: event.type,
                botID: event.principal.botId, sessionID: event.principal.sessionId,
                review: nil)]
        default:
            return []
        }
    }

    private static func decodeDerivation(_ value: BotJSONValue?) -> BotDerivation? {
        guard let value else { return nil }
        guard let data = try? value.encoded() else { return nil }
        guard var derivation = try? JSONDecoder().decode(BotDerivation.self, from: data) else {
            return nil
        }
        if derivation.sources.count > BotDerivation.maximumSources { return nil }
        if derivation.artifact.id.isEmpty
            || derivation.artifact.id.unicodeScalars.count > BotDerivation.maximumIDScalars {
            return nil
        }
        if let basis = derivation.basis,
           basis.unicodeScalars.count > BotDerivation.maximumBasisScalars {
            return nil
        }
        var seen = Set<String>()
        var canonicalSources: [BotDerivationSource] = []
        for source in derivation.sources {
            guard let canonical = BotRecordReference.canonicalize(source.record) else {
                return nil
            }
            let key = "\(canonical)\u{1F}\(source.role?.rawValue ?? "basis")"
            guard seen.insert(key).inserted else { return nil }
            canonicalSources.append(BotDerivationSource(
                record: canonical, role: source.role, resource: source.resource,
                sourceVersion: source.sourceVersion, grantId: source.grantId))
        }
        derivation.sources = canonicalSources
        return derivation
    }

    private static func decodeReview(_ value: BotJSONValue?) -> BotProvenanceAssertion.Review? {
        guard let value, let state = value["state"]?.stringValue else { return nil }
        return BotProvenanceAssertion.Review(
            state: state, basis: value["basis"]?.stringValue)
    }

    private static func reviewRefs(_ value: BotJSONValue?) -> [String] {
        guard let value, let refs = value["refs"]?.arrayValue else { return [] }
        return refs.compactMap { $0.stringValue }.filter {
            BotRecordReference.parse($0) != nil
        }
    }

    private static func stringRefs(_ value: BotJSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.stringValue }.filter {
            BotRecordReference.parse($0) != nil
        }
    }

    private static func structuredRefs(_ data: BotJSONValue) -> [String] {
        var result: [String] = []
        for key in ["evidence", "refs", "sources", "records", "record"] {
            guard let value = data[key] else { continue }
            if let text = value.stringValue, BotRecordReference.parse(text) != nil {
                result.append(text)
            }
            for item in value.arrayValue ?? [] {
                if let text = item.stringValue, BotRecordReference.parse(text) != nil {
                    result.append(text)
                }
            }
        }
        return result
    }

    private static func dedupe(_ sources: [BotDerivationSource]) -> [BotDerivationSource] {
        var seen = Set<String>()
        var result: [BotDerivationSource] = []
        for source in sources {
            let key = "\(BotRecordReference.canonicalize(source.record) ?? source.record)"
                + "\u{1F}\(source.role?.rawValue ?? "basis")"
            guard seen.insert(key).inserted else { continue }
            result.append(source)
        }
        return result
    }

    private static func erasureRecords(_ event: BotEvent) -> Set<String> {
        var result = Set<String>()
        for key in ["erasedEvents", "erasedSessionRecords"] {
            for item in event.data[key]?.arrayValue ?? [] {
                if let record = item["record"]?.stringValue { result.insert(record) }
            }
        }
        return result
    }

    private static func grantIDs(_ event: BotEvent) -> [String] {
        var result: [String] = []
        for key in ["grantId", "grant_id", "id"] {
            if let value = event.data[key]?.stringValue { result.append(value) }
        }
        return result
    }

    
    /// Root R1: `source+origin` alone is not enough when `source` is a tool or
    /// channel. Identity is owner + a stable resource key (URL/path/device id).
    /// A tool name, MCP server name without a resource path, or other channel
    /// marker yields nil and the read view reports no-resource-identity.
    static func observationIdentity(source: String, origin: String,
                                    owner: String?) -> String? {
        guard let key = resourceKey(source: source, origin: origin) else { return nil }
        return "\(owner ?? "unknown")\u{1F}\(source)\u{1F}\(key)"
    }

    static func resourceKey(source: String, origin: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch source {
        case "web", "attachment":
            guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
                    || trimmed.hasPrefix("file://") else { return nil }
            return trimmed
        case "connector":
            // mcp://server alone identifies a server/tool channel, not a
            // resource; require an actual path after the authority.
            guard let scheme = trimmed.range(of: "://") else { return nil }
            let rest = trimmed[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/"), slash < rest.endIndex else {
                return nil
            }
            return trimmed
        case "device", "device-task":
            return trimmed
        default:
            // tool / agent / subagent / unknown are channels, not resources.
            return nil
        }
    }

    private static func isObservationCarrier(_ type: String) -> Bool {
        type == "conversation.tool_result" || type == "comm.inbound"
            || type == "context.observed"
    }

    private static func trust(for type: String) -> String? {
        switch type {
        case "conversation.user_message": return "user"
        case "conversation.tool_result": return "assistant"
        default: return nil
        }
    }

    struct CarrierObservation: Sendable, Equatable {
        var source: String
        var origin: String?
        var owner: String?
        var observedAtMS: Int64
        var version: BotProvenanceSourceVersion?
        var resource: BotResourceIdentity?
        /// The one record that represents this observation in the latest
        /// index (the original source record when the carrier names one).
        var sourceRef: String
        /// Event/carrier refs that resolve to the same observation for facts
        /// and resource lookup, but must not become second index entries.
        var aliases: [String]
    }

    /// G-1 r11 §2.4: real carriers only. `conversation.tool_result` carries the
    /// v1 observation envelope in its message text; `context.observed` is flat
    /// data. `data.observation` is not a contract and is not read here.
    static func carrierObservation(for event: BotEvent) -> CarrierObservation? {
        switch event.type {
        case "conversation.tool_result", "comm.inbound":
            guard let text = observationEnvelopeText(event),
                  let envelope = BotObservationEnvelope.decode(text) else { return nil }
            let owner = envelope.owner.isEmpty ? event.principal.botId : envelope.owner
            let resource = parseResource(event.data["resource"])
                ?? derivedResource(source: envelope.source, origin: envelope.origin,
                                   owner: owner)
            let eventRef = "record://event/\(event.commitSeq ?? 0)"
            let original = BotRecordReference.canonicalize(envelope.ref)
            return CarrierObservation(
                source: envelope.source, origin: envelope.origin, owner: owner,
                observedAtMS: event.time > 0 ? event.time : 0,
                version: parseVersion(event.data["source_version"]),
                resource: resource,
                sourceRef: original ?? eventRef,
                aliases: [eventRef, original].compactMap { $0 })
        case "context.observed":
            guard event.data["schema"]?.stringValue == "bot-context-observation/v1",
                  let source = event.data["source"]?.stringValue,
                  let observedAt = event.data["observed_at_ms"]?.intValue,
                  let owner = event.data["owner_bot_id"]?.stringValue
                    ?? event.principal.botId else { return nil }
            let payload = event.data["payload"] ?? .object([:])
            let resource = parseResource(event.data["resource"])
                ?? derivedContextResource(source: source, payload: payload, owner: owner)
            let recordRef = event.data["record_ref"]?.stringValue.flatMap {
                BotRecordReference.canonicalize($0)
            }
            let carrierRef = "record://event/\(event.commitSeq ?? 0)"
            return CarrierObservation(
                source: source, origin: nil, owner: owner,
                observedAtMS: Int64(observedAt),
                version: parseVersion(event.data["source_version"]),
                resource: resource,
                sourceRef: recordRef ?? carrierRef,
                aliases: [carrierRef, recordRef].compactMap { $0 })
        default:
            return nil
        }
    }

    private static func observationEnvelopeText(_ event: BotEvent) -> String? {
        let content = event.data["message"]?["content"]?.arrayValue ?? []
        var text = content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: "\n")
        if text.isEmpty { text = event.data["text"]?.stringValue ?? "" }
        guard !text.isEmpty else { return nil }
        return text
    }

    /// G-3 context sources have no URL; the resource id is the OS object id in
    /// the minimal payload. Known payload keys are checked generically; no
    /// tool/channel name is ever used as a resource key.
    static func derivedContextResource(source: String, payload: BotJSONValue,
                                       owner: String) -> BotResourceIdentity? {
        let keys = ["eventIdentifier", "contactId", "contactIdentifier", "regionId",
                    "assetIdentifier", "localIdentifier", "identifier", "id", "url", "path"]
        for key in keys {
            if let value = payload[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return BotResourceIdentity(
                    kind: .contextSource, key: "\(source):\(value)", owner: owner)
            }
        }
        return nil
    }

    static func sortedObservations(_ entries: [BotProvenanceObservation])
        -> [BotProvenanceObservation] {
        entries.sorted { lhs, rhs in
            if lhs.observedAtMS != rhs.observedAtMS {
                return lhs.observedAtMS < rhs.observedAtMS
            }
            return recordOrder(lhs.ref) < recordOrder(rhs.ref)
        }
    }

    static func parseResource(_ value: BotJSONValue?) -> BotResourceIdentity? {
        guard let value, let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(BotResourceIdentity.self, from: data)
    }

    /// Only registered sources are derivable from origin. connector/tool need
    /// an explicit resource id; their origin is a channel, not a resource.
    static func derivedResource(source: String, origin: String,
                                owner: String?) -> BotResourceIdentity? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case "web":
            guard let key = normalizedWebURL(trimmed) else { return nil }
            return BotResourceIdentity(kind: .webURL, key: key, owner: owner)
        case "attachment":
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") else { return nil }
            return BotResourceIdentity(kind: .file, key: trimmed, owner: owner)
        case "device", "device-task":
            guard !trimmed.isEmpty else { return nil }
            return BotResourceIdentity(kind: .contextSource, key: trimmed, owner: owner)
        default:
            return nil
        }
    }

    static func normalizedWebURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string
    }

    static func parseVersion(_ value: BotJSONValue?) -> BotProvenanceSourceVersion? {
        guard let value, let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(BotProvenanceSourceVersion.self, from: data)
    }


    /// Kosaraju SCC; every node in a component larger than one (or with a
    /// self edge) is cyclic.
    private static func stronglyConnectedCycles(_ edges: [BotDerivedRef: Set<BotDerivedRef>])
        -> Set<BotDerivedRef> {
        var nodes = Set(edges.keys)
        for targets in edges.values { nodes.formUnion(targets) }
        var adjacency: [BotDerivedRef: [BotDerivedRef]] = [:]
        var reverse: [BotDerivedRef: [BotDerivedRef]] = [:]
        for node in nodes { adjacency[node] = [] ; reverse[node] = [] }
        for (node, targets) in edges {
            for target in targets {
                adjacency[node, default: []].append(target)
                reverse[target, default: []].append(node)
            }
        }
        var visited = Set<BotDerivedRef>()
        var order: [BotDerivedRef] = []
        for node in nodes.sorted() where !visited.contains(node) {
            var stack: [(BotDerivedRef, Bool)] = [(node, false)]
            while let (current, finished) = stack.popLast() {
                if finished {
                    order.append(current)
                    continue
                }
                guard visited.insert(current).inserted else { continue }
                stack.append((current, true))
                for next in adjacency[current] ?? [] where !visited.contains(next) {
                    stack.append((next, false))
                }
            }
        }
        var component: [BotDerivedRef: Int] = [:]
        var index = 0
        for node in order.reversed() where component[node] == nil {
            var stack = [node]
            component[node] = index
            while let current = stack.popLast() {
                for next in reverse[current] ?? [] where component[next] == nil {
                    component[next] = index
                    stack.append(next)
                }
            }
            index += 1
        }
        var sizes: [Int: Int] = [:]
        for value in component.values { sizes[value, default: 0] += 1 }
        var cyclic = Set<BotDerivedRef>()
        for (node, value) in component where sizes[value, default: 0] > 1 {
            cyclic.insert(node)
        }
        for (node, targets) in edges where targets.contains(node) {
            cyclic.insert(node)
        }
        return cyclic
    }
}
