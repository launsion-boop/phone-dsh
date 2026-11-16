// SPDX-License-Identifier: MIT

import Foundation

public enum BotSkillChangeAction: String, Codable, Sendable, CaseIterable {
    case write
    case delete
}

public struct BotSkillChangeAuthor: Sendable, Equatable {
    public var kind: String
    public var botID: String?
    public var sessionID: String?

    public init(kind: String, botID: String? = nil, sessionID: String? = nil) {
        self.kind = kind
        self.botID = botID
        self.sessionID = sessionID
    }
}

/// One successful skill file mutation from the App/plugin skill surface
/// (G-4 `skill.changed`). The plugin remains the only authority that writes
/// `/dsh/home/skills`; this records the durable carrier and optional derivation.
public struct BotSkillWriteRequest: Sendable, Equatable {
    public static let eventType = "skill.changed"
    public static let schema = "bot-skill-change/v1"

    public var name: String
    public var file: String
    public var revision: Int
    public var action: BotSkillChangeAction
    /// Raw UTF-8 file bytes hash for write; nil for delete.
    public var contentSHA256: String?
    public var bytes: Int?
    public var previousSHA256: String?
    public var author: BotSkillChangeAuthor
    public var atMS: Int64
    public var sources: [BotDerivationSource]

    public init(name: String, file: String, revision: Int,
                action: BotSkillChangeAction, contentSHA256: String?,
                bytes: Int?, previousSHA256: String?, author: BotSkillChangeAuthor,
                atMS: Int64, sources: [BotDerivationSource]) {
        self.name = name
        self.file = file
        self.revision = revision
        self.action = action
        self.contentSHA256 = contentSHA256
        self.bytes = bytes
        self.previousSHA256 = previousSHA256
        self.author = author
        self.atMS = atMS
        self.sources = sources
    }
}

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
    func invalidate(sourceRefs: [String], reason: BotInvalidationReason,
                    botID: String?) async throws -> BotInvalidationResult
    func prepareDerivation(artifact: BotDerivedRef,
                           sources: [BotDerivationSource]) async throws -> BotJSONValue
    func recordSkillWrite(_ write: BotSkillWriteRequest) async throws -> BotDerivedRef
}

/// Read boundary. `currentState` returns the G-1 derivation view; the historical
/// name `BotDerivedState` is a typealias so callers can use either.
public protocol BotProvenanceQuerying: Sendable {
    func forwardTrace(sourceRef: String) async throws -> [BotDerivedRef]
    func forwardTrace(sourceRef: String, botID: String?) async throws -> [BotDerivedRef]
    func reverseTrace(derivedRef: BotDerivedRef) async throws -> [BotDerivation]
    func reverseTrace(derivedRef: BotDerivedRef, botID: String?) async throws -> [BotDerivation]
    func currentState(for derivedRef: BotDerivedRef) async throws -> BotDerivationView
    func currentStates(for derivedRefs: [BotDerivedRef]) async throws
        -> [BotDerivedRef: BotDerivationView]
    func trace(_ record: String) async throws -> [BotDerivationView]
    func trace(_ record: String, botID: String?) async throws -> [BotDerivationView]
    func sourceStatuses(for artifact: BotDerivedRef) async throws -> [BotSourceStatus]
    func sourceStatuses(for artifact: BotDerivedRef, botID: String?) async throws
        -> [BotSourceStatus]
    func currentState(for artifact: BotDerivedRef, botID: String?) async throws
        -> BotDerivationView
    func sourceStatuses(for refs: [String]) async throws -> [String: BotSourceStatus]
    func sourceStatuses(for refs: [String], botID: String?) async throws
        -> [String: BotSourceStatus]
    func generation() async throws -> BotProvenanceGeneration
    func latestSkillChange(name: String) async throws -> BotSkillChangeSnapshot?
    func routineDerivationSources(botID: String, sessionID: String) async throws
        -> [BotDerivationSource]
    func derivedRefs(forEventID eventID: String) async throws -> [BotDerivedRef]
    func derivedRef(forEventID eventID: String) async throws -> BotDerivedRef?
}

public actor BotProvenanceService: BotProvenanceRecording, BotProvenanceQuerying {
    private let eventLog: any BotEventLog
    private let evidenceResolver: (any BotProvenanceEvidenceResolving)?
    private let rechecker: (any BotProvenanceRechecking)?
    private let skillRechecker: (any BotSkillRechecking)?
    private var eventBuffer: [BotEvent] = []
    private var bufferHead = 0
    private var snapshotCache: BotProvenanceSnapshot?
    private var cachedEventIDs: [String: Int] = [:]

    public init(eventLog: any BotEventLog,
                resolver: (any BotProvenanceEvidenceResolving)? = nil,
                rechecker: (any BotProvenanceRechecking)? = nil,
                skillRechecker: (any BotSkillRechecking)? = nil) {
        self.eventLog = eventLog
        self.evidenceResolver = resolver
        self.rechecker = rechecker
        self.skillRechecker = skillRechecker
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

    public func prepareDerivation(artifact: BotDerivedRef,
                                  sources: [BotDerivationSource]) async throws
        -> BotJSONValue {
        let canonical = try Self.validated(
            BotDerivation(artifact: artifact, sources: sources))
        let snapshot = try await refresh()
        var filled: [BotDerivationSource] = []
        for source in canonical.sources {
            guard let canonicalRef = BotRecordReference.canonicalize(source.record) else {
                throw BotProvenanceError.invalidDerivation("invalid source reference")
            }
            let resource = source.resource
                ?? snapshot.observationResourceByRef[canonicalRef]
            let isObservation = source.sourceVersion != nil
                || snapshot.observationResourceByRef[canonicalRef] != nil
                || snapshot.eventFacts[canonicalRef]?.isObservation == true
            if isObservation, resource == nil {
                throw BotProvenanceError.invalidDerivation(
                    "observation source \(canonicalRef) has no stable resource identity")
            }
            filled.append(BotDerivationSource(
                record: canonicalRef, role: source.role, resource: resource,
                sourceVersion: source.sourceVersion, grantId: source.grantId))
        }
        return try Self.jsonValue(BotDerivation(
            artifact: canonical.artifact, sources: filled, basis: canonical.basis))
    }

    public func recordSkillWrite(_ write: BotSkillWriteRequest) async throws
        -> BotDerivedRef {
        let name = write.name
        guard name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#,
                         options: .regularExpression) != nil,
              name.unicodeScalars.count <= 64,
              write.file == "\(name).md" else {
            throw BotProvenanceError.invalidDerivation("invalid skill name/file")
        }
        guard write.revision >= 1 else {
            throw BotProvenanceError.invalidDerivation("skill revision must be >= 1")
        }
        func validSHA(_ value: String?) -> Bool {
            guard let value, value.hasPrefix("sha256:") else { return false }
            let hex = value.dropFirst(7)
            return hex.count == 64
                && hex.allSatisfy({ "0123456789abcdef".contains($0) })
        }
        switch write.action {
        case .write:
            guard validSHA(write.contentSHA256), let bytes = write.bytes,
                  (0...2_097_152).contains(bytes) else {
                throw BotProvenanceError.invalidDerivation(
                    "skill write requires raw content sha256 and bytes")
            }
            if let previous = write.previousSHA256, !validSHA(previous) {
                throw BotProvenanceError.invalidDerivation("invalid previous sha256")
            }
        case .delete:
            guard validSHA(write.previousSHA256), write.contentSHA256 == nil else {
                throw BotProvenanceError.invalidDerivation(
                    "skill delete requires previous_sha256 and no content")
            }
        }
        let eventId = "skill-changed:\(name):\(write.revision):\(write.action.rawValue)"
        let snapshot = try await refresh()
        if cachedEventIDs[eventId] != nil {
            return BotDerivedRef(kind: .skill, id: name, version: write.revision)
        }
        let latest = snapshot.assertions.keys
            .filter { $0.kind == .skill && $0.id == name }
            .compactMap(\.version).max()
        let expected = (latest ?? 0) + 1
        guard write.revision == expected else {
            throw BotProvenanceError.invalidDerivation(
                "skill revision must be \(expected), got \(write.revision)")
        }
        var data: [String: BotJSONValue] = [
            "schema": .string(BotSkillWriteRequest.schema),
            "action": .string(write.action.rawValue),
            "author": .object({
                var author: [String: BotJSONValue] = [
                    "kind": .string(write.author.kind),
                ]
                if let botID = write.author.botID {
                    author["bot_id"] = .string(botID)
                }
                if let sessionID = write.author.sessionID {
                    author["session_id"] = .string(sessionID)
                }
                return author
            }()),
            "at_ms": .number(Double(max(0, write.atMS))),
        ]
        var skill: [String: BotJSONValue] = [
            "name": .string(name),
            "file": .string(write.file),
            "revision": .number(Double(write.revision)),
        ]
        if write.action == .write {
            skill["content_sha256"] = .string(write.contentSHA256 ?? "")
            skill["bytes"] = .number(Double(write.bytes ?? 0))
            if let previous = write.previousSHA256 {
                skill["previous_sha256"] = .string(previous)
            }
        } else {
            skill["previous_sha256"] = .string(write.previousSHA256 ?? "")
        }
        data["skill"] = .object(skill)
        if !write.sources.isEmpty {
            data["derivation"] = try await prepareDerivation(
                artifact: BotDerivedRef(
                    kind: .skill, id: name, version: write.revision),
                sources: write.sources)
        }
        let event = BotEvent(
            type: BotSkillWriteRequest.eventType,
            eventId: eventId,
            time: max(0, write.atMS),
            origin: .local(source: "ipc"),
            traceId: "trace-\(eventId)",
            principal: BotPrincipal(
                botId: write.author.botID, sessionId: write.author.sessionID,
                kind: "ipc"),
            causationId: nil, correlationId: nil, ignorable: true,
            data: .object(data))
        let seq = try await eventLog.append(event)
        guard seq >= 1 else {
            throw BotProvenanceError.invalidDerivation(
                "skill.changed was not persisted as a durable event")
        }
        _ = seq
        return BotDerivedRef(kind: .skill, id: name, version: write.revision)
    }

    public func latestSkillChange(name: String) async throws
        -> BotSkillChangeSnapshot? {
        let snapshot = try await refresh()
        let latest = snapshot.assertions.keys
            .filter { $0.kind == .skill && $0.id == name }
            .compactMap(\.version).max()
        guard let latest,
              let assertion = snapshot.assertions[
                BotDerivedRef(kind: .skill, id: name, version: latest)]?.last,
              let seq = Int(assertion.carrierRecord
                .replacingOccurrences(of: "record://event/", with: "")),
              let data = try await eventData(forCommitSeq: seq),
              let skill = data["skill"]?.objectValue,
              let file = skill["file"]?.stringValue else { return nil }
        let at = Int64(data["at_ms"]?.intValue ?? 0)
        return BotSkillChangeSnapshot(
            name: name, file: file, revision: latest,
            action: data["action"]?.stringValue ?? "write",
            contentSHA256: skill["content_sha256"]?.stringValue,
            previousSHA256: skill["previous_sha256"]?.stringValue,
            bytes: skill["bytes"]?.intValue,
            carrier: assertion.carrierRecord, atMS: at)
    }

    /// Derivation sources for a routine-run memory write: the durable
    /// `routine.run_started` is role `trigger` (causal only), and the latest
    /// routine-definition snapshot for the same routine is role `basis` (the
    /// saved instruction is real content). If either layer is missing we return
    /// only what really exists; a trigger without a content source must remain
    /// unknown/no-derivation rather than become current.
    public func routineDerivationSources(botID: String, sessionID: String) async throws
        -> [BotDerivationSource] {
        let snapshot = try await refresh()
        let head = snapshot.generation.headCommitSeq
        guard head > 0 else { return [] }
        let window = 500
        let events = try await eventLog.events(
            after: max(0, head - window), limit: window)
        guard let started = events.reversed().first(where: {
            $0.type == "routine.run_started"
                && $0.principal.sessionId == sessionID
                && (botID.isEmpty || $0.principal.botId == botID)
        }), let startedSeq = started.commitSeq,
              let routineId = started.data["routineId"]?.stringValue,
              !routineId.isEmpty else { return [] }
        var result: [BotDerivationSource] = [
            BotDerivationSource(record: "record://event/\(startedSeq)", role: .trigger)
        ]
        // The routine definition snapshot is the saved instruction that caused
        // this run; it is a content basis, not a second trigger. Scan newest
        // first so an updated definition wins without replaying all events.
        for event in events.reversed() {
            guard event.type == "routine.defined" || event.type == "routine.updated",
                  event.principal.botId == botID,
                  let seq = event.commitSeq,
                  event.data["botId"]?.stringValue == botID,
                  event.data["document"]?["routines"]?.arrayValue?
                    .contains(where: { $0["id"]?.stringValue == routineId }) == true else {
                continue
            }
            result.append(BotDerivationSource(
                record: "record://event/\(seq)", role: .basis))
            break
        }
        return result
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

    public func invalidate(sourceRefs: [String], reason: BotInvalidationReason,
                           botID: String?) async throws -> BotInvalidationResult {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        let facts = await facts(for: scoped)
        return scoped.invalidated(
            sourceRefs: sourceRefs, reason: reason, facts: facts)
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

    public func sourceStatuses(for artifact: BotDerivedRef,
                               botID: String?) async throws -> [BotSourceStatus] {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        let facts = await facts(for: scoped)
        return scoped.sourceStatuses(for: artifact, facts: facts)
    }

    public func forwardTrace(sourceRef: String,
                             botID: String?) async throws -> [BotDerivedRef] {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        let facts = await facts(for: scoped)
        return scoped.trace(sourceRef, facts: facts).map(\.artifact)
    }

    public func reverseTrace(derivedRef: BotDerivedRef,
                             botID: String?) async throws -> [BotDerivation] {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        return scoped.reverseTrace(for: derivedRef)
    }

    public func trace(_ record: String,
                      botID: String?) async throws -> [BotDerivationView] {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        let facts = await facts(for: scoped)
        return scoped.trace(record, facts: facts)
    }

    public func currentState(for artifact: BotDerivedRef,
                             botID: String?) async throws -> BotDerivationView {
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        let facts = await facts(for: scoped)
        return scoped.view(for: artifact, facts: facts)
    }

    public func sourceStatuses(for refs: [String]) async throws -> [String: BotSourceStatus] {
        let snapshot = try await refresh()
        let facts = await facts(for: snapshot, extraRefs: refs)
        return snapshot.sourceStatuses(for: refs, facts: facts)
    }

    public func sourceStatuses(for refs: [String],
                               botID: String?) async throws -> [String: BotSourceStatus] {
        guard let botID, !botID.isEmpty else { return [:] }
        let snapshot = try await refresh()
        let scoped = snapshot.scoped(botID: botID)
        // Arbitrary refs have no artifact baseline. Only serve refs that the
        // scoped assertions actually reference; an unrelated/foreign ref must
        // not become a current source merely because the legacy eventFacts map
        // contains it.
        let allowed = Set(scoped.bySource.keys)
        let scopedRefs = refs.filter { allowed.contains(
            BotRecordReference.canonicalize($0) ?? $0) }
        let facts = await facts(for: scoped, extraRefs: scopedRefs)
        return scoped.sourceStatuses(for: scopedRefs, facts: facts)
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

    private func eventData(forCommitSeq seq: Int) async throws -> BotJSONValue? {
        let batch = try await eventLog.events(after: max(0, seq - 1), limit: 1)
        guard let event = batch.first, event.commitSeq == seq else { return nil }
        return event.data
    }

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
    private func sourceProviderMustNotRun(
        _ source: BotDerivationSource,
        facts: [String: BotProvenanceResolvedFacts],
        snapshot: BotProvenanceSnapshot
    ) -> Bool {
        let ref = BotRecordReference.canonicalize(source.record) ?? source.record
        guard let fact = facts[ref] else { return true }
        if !fact.resolved || fact.erased { return true }
        return snapshot.isGrantKnownRevoked(source.grantId)
    }

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
                            skillRecheckOutcome: nil, scanLimitExceeded: false)
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
        if let skillRechecker {
            for assertion in snapshot.assertions.values.joined()
            where assertion.artifact.kind == .skill && !assertion.isDeleted {
                guard let seq = Int(assertion.carrierRecord
                        .replacingOccurrences(of: "record://event/", with: "")),
                      var fact = facts[assertion.carrierRecord] else { continue }
                // Recheck the file bytes for the latest skill revision only.
                let latest = snapshot.assertions[assertion.artifact]?.last
                guard latest?.carrierSeq == assertion.carrierSeq else { continue }
                // Known-invalid lineage: do not read the file at all. The
                // invalid source/upstream stays the deciding state.
                if assertion.sources.contains(where: {
                    sourceProviderMustNotRun($0, facts: facts, snapshot: snapshot)
                }) {
                    fact.skillRecheckOutcome = .skipped
                    facts[assertion.carrierRecord] = fact
                    continue
                }
                guard let data = try? await eventData(forCommitSeq: seq),
                      let skill = data["skill"]?.objectValue,
                      let name = skill["name"]?.stringValue,
                      let file = skill["file"]?.stringValue,
                      let digest = skill["content_sha256"]?.stringValue else { continue }
                fact.skillRecheckOutcome = await skillRechecker.recheckSkill(
                    name: name, file: file, expectedSHA256: digest)
                facts[assertion.carrierRecord] = fact
            }
        }
        if let rechecker {
            var recheckedKeys = Set<String>()
            for assertion in snapshot.assertions.values.joined() {
                for source in assertion.sources {
                    guard let baseline = source.sourceVersion else { continue }
                    let ref = BotRecordReference.canonicalize(source.record) ?? source.record
                    // Do not read the provider for a source already known to be
                    // unresolved/erased/revoked. The view must say so from
                    // durable facts, not from a fresh read of invalid data.
                    guard let storedFact = facts[ref],
                          !sourceProviderMustNotRun(
                            source, facts: facts, snapshot: snapshot),
                          storedFact.isObservation,
                          let resource = source.resource ?? storedFact.resource else {
                        continue
                    }
                    var fact = storedFact
                    let key = ref + "\u{1F}" + String(describing: baseline)
                    guard recheckedKeys.insert(key).inserted else { continue }
                    let outcome = await rechecker.recheck(
                        resource: resource, baseline: baseline, botID: assertion.botID)
                    fact.recheckOutcomesByBaseline[baseline] = outcome
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
