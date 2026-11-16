// SPDX-License-Identifier: MIT

import Foundation

/// Write-side boundary. `prepareBaseline` validates and canonicalizes the
/// optional `derivation` member; the fact writer embeds the returned JSON into
/// its own durable event data. It stores nothing and does not require a carrier
/// to exist — the carrier is the event that will contain the member.
public protocol BotProvenanceRecording: Sendable {
    func prepareBaseline(artifact: BotDerivedRef,
                         sources: [BotDerivationSource]) async throws -> BotJSONValue
    func prepareBaseline(_ derivation: BotDerivation) async throws -> BotJSONValue
    func invalidate(sourceRef: String,
                    reason: BotInvalidationReason) async throws -> BotInvalidationResult
    func invalidate(sourceRefs: [String],
                    reason: BotInvalidationReason) async throws -> BotInvalidationResult
}

/// Read boundary. `currentState` returns the G-1 derivation view; the historical
/// name `BotDerivedState` is a typealias so callers can use either.
public protocol BotProvenanceQuerying: Sendable {
    func forwardTrace(sourceRef: String) async throws -> [BotDerivedRef]
    func reverseTrace(derivedRef: BotDerivedRef) async throws -> [BotDerivation]
    func currentState(for derivedRef: BotDerivedRef) async throws -> BotDerivationView
    func currentStates(for derivedRefs: [BotDerivedRef]) async throws
        -> [BotDerivedRef: BotDerivationView]
    func trace(_ record: String) async throws -> [BotDerivationView]
    func sourceStatuses(for artifact: BotDerivedRef) async throws -> [BotSourceStatus]
    func sourceStatuses(for refs: [String]) async throws -> [String: BotSourceStatus]
    func generation() async throws -> BotProvenanceGeneration
    func derivedRefs(forEventID eventID: String) async throws -> [BotDerivedRef]
    func derivedRef(forEventID eventID: String) async throws -> BotDerivedRef?
}

public actor BotProvenanceService: BotProvenanceRecording, BotProvenanceQuerying {
    private let eventLog: any BotEventLog
    private let evidenceResolver: (any BotProvenanceEvidenceResolving)?
    private let rechecker: (any BotProvenanceRechecking)?
    private var eventBuffer: [BotEvent] = []
    private var bufferHead = 0
    private var snapshotCache: BotProvenanceSnapshot?
    private var cachedEventIDs: [String: Int] = [:]

    public init(eventLog: any BotEventLog,
                resolver: (any BotProvenanceEvidenceResolving)? = nil,
                rechecker: (any BotProvenanceRechecking)? = nil) {
        self.eventLog = eventLog
        self.evidenceResolver = resolver
        self.rechecker = rechecker
    }

    // MARK: - write side

    public func prepareBaseline(artifact: BotDerivedRef,
                                sources: [BotDerivationSource]) async throws -> BotJSONValue {
        try await prepareBaseline(BotDerivation(artifact: artifact, sources: sources))
    }

    public func prepareBaseline(_ derivation: BotDerivation) async throws -> BotJSONValue {
        let canonical = try Self.validated(derivation)
        return try Self.jsonValue(canonical)
    }

    public func invalidate(sourceRef: String,
                           reason: BotInvalidationReason) async throws -> BotInvalidationResult {
        try await invalidate(sourceRefs: [sourceRef], reason: reason)
    }

    public func invalidate(sourceRefs: [String],
                           reason: BotInvalidationReason) async throws -> BotInvalidationResult {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        return snapshot.invalidated(sourceRefs: sourceRefs, reason: reason, facts: facts)
    }

    /// Convenience for the memory erasure batch: `BotMemoryPhysicalEraseOutcome.
    /// erasureRecord` already names the durable erasure; this reads the erased
    /// records from that event and invalidates every dependent artifact in one
    /// pass. No second store and no per-source query loop.
    public func invalidate(erasureRecord: String,
                           reason: BotInvalidationReason = .sourceErased) async throws
        -> BotInvalidationResult {
        guard let parsed = BotRecordReference.parse(erasureRecord),
              case .event = parsed else {
            return try await invalidate(sourceRefs: [erasureRecord], reason: reason)
        }
        let records = try await erasedRecords(forErasureRecord: erasureRecord)
        return try await invalidate(sourceRefs: records, reason: reason)
    }

    private func erasedRecords(forErasureRecord record: String) async throws -> [String] {
        guard let parsed = BotRecordReference.parse(record),
              case let .event(commitSeq) = parsed else { return [] }
        let batch = try await eventLog.events(after: commitSeq - 1, limit: 1)
        guard let event = batch.first, event.type == "erasure" else { return [] }
        var result: [String] = []
        for key in ["erasedEvents", "erasedSessionRecords"] {
            for item in event.data[key]?.arrayValue ?? [] {
                if let value = item["record"]?.stringValue { result.append(value) }
            }
        }
        return result
    }

    // MARK: - read side

    public func forwardTrace(sourceRef: String) async throws -> [BotDerivedRef] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        return snapshot.trace(sourceRef, facts: facts).map(\.artifact)
    }

    public func reverseTrace(derivedRef: BotDerivedRef) async throws -> [BotDerivation] {
        try await refresh().reverseTrace(for: derivedRef)
    }

    public func currentState(for derivedRef: BotDerivedRef) async throws -> BotDerivationView {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        return snapshot.view(for: derivedRef, facts: facts)
    }

    public func currentStates(for derivedRefs: [BotDerivedRef]) async throws
        -> [BotDerivedRef: BotDerivationView] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        var result: [BotDerivedRef: BotDerivationView] = [:]
        for ref in derivedRefs {
            result[ref] = snapshot.view(for: ref, facts: facts)
        }
        return result
    }

    public func trace(_ record: String) async throws -> [BotDerivationView] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        return snapshot.trace(record, facts: facts)
    }

    public func sourceStatuses(for artifact: BotDerivedRef) async throws -> [BotSourceStatus] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot)
        return snapshot.sourceStatuses(for: artifact, facts: facts)
    }

    public func sourceStatuses(for refs: [String]) async throws -> [String: BotSourceStatus] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot, extraRefs: refs)
        return snapshot.sourceStatuses(for: refs, facts: facts)
    }

    public func generation() async throws -> BotProvenanceGeneration {
        try await refresh().generation
    }

    public func derivedRefs(forEventID eventID: String) async throws -> [BotDerivedRef] {
        let snapshot = try await refresh()
        return snapshot.derivedRefs(forEventID: eventID, eventIDToSeq: cachedEventIDs)
    }

    public func derivedRef(forEventID eventID: String) async throws -> BotDerivedRef? {
        let refs = try await derivedRefs(forEventID: eventID)
        return refs.count == 1 ? refs[0] : nil
    }

    // MARK: - cache / facts

    private func refresh() async throws -> BotProvenanceSnapshot {
        var added = false
        do {
            while true {
                let batch = try await eventLog.events(after: bufferHead, limit: 500)
                guard !batch.isEmpty else { break }
                eventBuffer.append(contentsOf: batch)
                bufferHead = batch.last?.commitSeq ?? bufferHead
                added = true
                if batch.count < 500 { break }
            }
        } catch {
            eventBuffer = []
            bufferHead = 0
            snapshotCache = nil
            cachedEventIDs = [:]
            while true {
                let batch = try await eventLog.events(after: bufferHead, limit: 500)
                guard !batch.isEmpty else { break }
                eventBuffer.append(contentsOf: batch)
                bufferHead = batch.last?.commitSeq ?? bufferHead
                added = true
                if batch.count < 500 { break }
            }
        }
        if !added, let cached = snapshotCache { return cached }
        let snapshot = BotProvenanceSnapshot.build(events: eventBuffer)
        var ids: [String: Int] = [:]
        for event in eventBuffer {
            if let seq = event.commitSeq, ids[event.eventId] == nil {
                ids[event.eventId] = seq
            }
        }
        cachedEventIDs = ids
        snapshotCache = snapshot
        return snapshot
    }

    /// One batched resolve per query. Event records come from the snapshot;
    /// session records come from the injected P adapter. The result is the
    /// single fact set L uses to decide state.
    private func facts(for snapshot: BotProvenanceSnapshot,
                       extraRefs: [String] = []) async
        -> [String: BotProvenanceResolvedFacts] {
        var facts = snapshot.eventFacts
        // G-1 r11/r12: event refs must reach P too. Session refs are not the
        // only facts source; P returns trust/version for event carriers.
        var referenced = Set<String>()
        for raw in extraRefs {
            if let parsed = BotRecordReference.parse(raw) {
                referenced.insert(parsed.canonical)
            }
        }
        for assertion in snapshot.assertions.values.joined() {
            for source in assertion.sources {
                if let parsed = BotRecordReference.parse(source.record) {
                    referenced.insert(parsed.canonical)
                }
                let resource = source.resource
                    ?? snapshot.observationResourceByRef[
                        BotRecordReference.canonicalize(source.record) ?? source.record]
                if let resource,
                   let latest = snapshot.observations[resource.canonical]?.last {
                    referenced.insert(latest.ref)
                }
            }
        }
        if let evidenceResolver, !referenced.isEmpty {
            var byOwner: [String: (botID: String?, sessionID: String?, refs: [String])] = [:]
            for assertion in snapshot.assertions.values.joined() {
                let key = "\(assertion.botID ?? "")\u{1F}\(assertion.sessionID ?? "")"
                var group = byOwner[key] ?? (assertion.botID, assertion.sessionID, [])
                for source in assertion.sources {
                    guard let parsed = BotRecordReference.parse(source.record) else { continue }
                    let canonical = parsed.canonical
                    if referenced.contains(canonical), !group.refs.contains(canonical) {
                        group.refs.append(canonical)
                    }
                    let resource = source.resource
                        ?? snapshot.observationResourceByRef[canonical]
                    if let resource,
                       let latest = snapshot.observations[resource.canonical]?.last,
                       !group.refs.contains(latest.ref) {
                        group.refs.append(latest.ref)
                    }
                }
                byOwner[key] = group
            }
            let attributed = Set(byOwner.values.flatMap(\.refs))
            let extras = referenced.filter { !attributed.contains($0) }.sorted()
            if !extras.isEmpty {
                byOwner["\u{1F}"] = (nil, nil, extras)
            }
            for group in byOwner.values where !group.refs.isEmpty {
                // P's batch resolver has a 512-distinct-reference ceiling.
                var start = 0
                while start < group.refs.count {
                    let end = min(group.refs.count, start + 512)
                    let chunk = Array(group.refs[start..<end])
                    let resolved = await evidenceResolver.sourceFacts(
                        for: chunk, botID: group.botID, sessionID: group.sessionID)
                    for (ref, fact) in resolved {
                        if let existing = facts[ref], existing.resolved, !fact.resolved {
                            continue
                        }
                        facts[ref] = BotProvenanceResolvedFacts(
                            resolved: fact.resolved, erased: fact.erased,
                            isObservation: fact.version != nil,
                            observedAtMS: fact.observedAtMS,
                            recordType: fact.recordType, trust: fact.trust,
                            currentVersion: fact.version,
                            identity: nil, latestRef: nil,
                            latestObservedAtMS: nil, latestVersion: nil,
                            resource: nil, recheckOutcome: nil,
                            scanLimitExceeded: false)
                    }
                    start = end
                }
            }
        }
        for ref in Array(facts.keys) {
            guard var fact = facts[ref] else { continue }
            // Resource identity comes only from the durable observation
            // carriers; P facts deliberately do not supply it.
            if fact.resource == nil,
               let resource = snapshot.observationResourceByRef[ref] {
                fact.resource = resource
                fact.isObservation = true
            }
            if snapshot.scanLimitExceeded, fact.isObservation {
                fact.scanLimitExceeded = true
            }
            if let resource = fact.resource {
                let entries = snapshot.observations[resource.canonical] ?? []
                if fact.currentVersion == nil,
                   let own = entries.last(where: { $0.ref == ref }) {
                    fact.currentVersion = own.version
                    fact.observedAtMS = fact.observedAtMS ?? own.observedAtMS
                    fact.trust = fact.trust ?? "observation"
                }
                if fact.latestRef == nil, let latest = entries.last, latest.ref != ref {
                    fact.latestRef = latest.ref
                    fact.latestObservedAtMS = latest.observedAtMS
                    fact.latestVersion = facts[latest.ref]?.currentVersion
                        ?? latest.version
                }
            }
            facts[ref] = fact
        }
        if let rechecker {
            for assertion in snapshot.assertions.values.joined() {
                for source in assertion.sources {
                    guard let baseline = source.sourceVersion else { continue }
                    let ref = BotRecordReference.canonicalize(source.record) ?? source.record
                    guard var fact = facts[ref], fact.isObservation,
                          let resource = source.resource ?? fact.resource else { continue }
                    fact.recheckOutcome = await rechecker.recheck(
                        resource: resource, baseline: baseline, botID: assertion.botID)
                    facts[ref] = fact
                }
            }
        }
        return facts
    }

    // MARK: - validation

    static func validated(_ derivation: BotDerivation) throws -> BotDerivation {
        guard !derivation.artifact.id.isEmpty,
              derivation.artifact.id.unicodeScalars.count <= BotDerivation.maximumIDScalars else {
            throw BotProvenanceError.invalidDerivation("artifact id must be 1...200 scalars")
        }
        if let version = derivation.artifact.version, version < 1 {
            throw BotProvenanceError.invalidDerivation("artifact version must be >= 1")
        }
        guard derivation.sources.count <= BotDerivation.maximumSources else {
            throw BotProvenanceError.invalidDerivation("sources must be 0...16")
        }
        if let basis = derivation.basis,
           basis.isEmpty || basis.unicodeScalars.count > BotDerivation.maximumBasisScalars {
            throw BotProvenanceError.invalidDerivation("basis must be 1...200 scalars")
        }
        var seen = Set<String>()
        var sources: [BotDerivationSource] = []
        for source in derivation.sources {
            guard let parsed = BotRecordReference.parse(source.record),
                  parsed.canonical == source.record else {
                throw BotProvenanceError.invalidDerivation(
                    "source record must be a canonical record:// reference")
            }
            let role = source.role ?? .basis
            let key = "\(parsed.canonical)\u{1F}\(role.rawValue)"
            guard seen.insert(key).inserted else {
                throw BotProvenanceError.invalidDerivation(
                    "duplicate (record, role) \(parsed.canonical)/\(role.rawValue)")
            }
            if let grantId = source.grantId,
               grantId.isEmpty || grantId.unicodeScalars.count > 64 {
                throw BotProvenanceError.invalidDerivation("grantId must be 1...64 scalars")
            }
            if let error = source.sourceVersion?.validationError() {
                throw BotProvenanceError.invalidDerivation(error)
            }
            if let basisRef = source.sourceVersion?.basisRefValue,
               BotRecordReference.parse(basisRef) == nil {
                throw BotProvenanceError.invalidDerivation(
                    "sourceVersion.basis_ref is not a canonical record reference")
            }
            sources.append(BotDerivationSource(
                record: parsed.canonical, role: source.role,
                sourceVersion: source.sourceVersion, grantId: source.grantId))
        }
        return BotDerivation(
            artifact: BotDerivedRef(
                kind: derivation.artifact.kind, id: derivation.artifact.id,
                version: derivation.artifact.version),
            sources: sources, basis: derivation.basis)
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> BotJSONValue {
        try BotJSONValue.parse(JSONEncoder().encode(value))
    }
}

private extension BotProvenanceSourceVersion {
    var basisRefValue: String? {
        switch self {
        case let .known(known):
            return known.basisRef
        case let .unknown(_, _, basisRef):
            return basisRef
        }
    }
}
