// SPDX-License-Identifier: MIT

import Foundation

/// Minimal N-side interpretation of the root ruling: a cloud-scheduled routine
/// is refused only when its own persisted `derivation.sources` names a real
/// `context.observed` record (content role) whose current consent is no longer
/// readable. No title/keyword guessing, no dependency map, no schema change.
///
/// - No derivation or no context record → `nil` (no proven dependency; the
///   routine is not stopped).
/// - Unknown/unresolvable record → `nil` (not evidence of revocation).
/// - A revoked/denied source that this routine actually used → `.revoked` for
///   this routine only; another goal is never touched.
///
/// F suppression is deliberately absent: it only holds proactive candidates at
/// the delivery exit and must not stop a scheduled routine.
public actor BotRoutineSourceDependencyResolver {
    private let store: SQLiteDomainStore
    private let botID: String
    private let authorization: @Sendable (String) async -> Bool
    private let scanLimit: Int

    public init(store: SQLiteDomainStore, botID: String,
                scanLimit: Int = 10_000,
                authorization: @escaping @Sendable (String) async -> Bool) {
        self.store = store
        self.botID = botID
        self.scanLimit = max(1, scanLimit)
        self.authorization = authorization
    }

    public func refusal(for routine: Routine) async -> CloudScheduleReason? {
        let sources = await dependencySources(for: routine)
        for source in sources {
            if await authorization(source) == false {
                return .revoked
            }
        }
        return nil
    }

    /// Records referenced by this routine's own derivation, restricted to
    /// `context.observed` carriers with a content role.
    func dependencySources(for routine: Routine) async -> [String] {
        let events: [BotEvent]
        do {
            events = try await store.events(after: 0, limit: scanLimit)
        } catch {
            return []
        }
        var sources: Set<String> = []
        for event in events {
            guard case .object(let data) = event.data,
                  case .object(let derivation)? = data["derivation"],
                  case .object(let artifact)? = derivation["artifact"],
                  artifact["kind"]?.stringValue == "routine",
                  artifact["id"]?.stringValue == routine.id,
                  case .array(let refs)? = derivation["sources"] else { continue }
            for ref in refs {
                guard let role = ref["role"]?.stringValue,
                      ["evidence", "basis", "creator"].contains(role),
                      let raw = ref["record"]?.stringValue,
                      let seq = Self.eventSequence(raw),
                      let sourceEvent = events.first(where: { $0.commitSeq == seq }),
                      sourceEvent.type == "context.observed",
                      case .object(let observation) = sourceEvent.data,
                      let sourceRaw = observation["source"]?.stringValue,
                      !sourceRaw.isEmpty else { continue }
                sources.insert(sourceRaw)
            }
        }
        return sources.sorted()
    }

    static func eventSequence(_ record: String) -> Int? {
        let prefix = "record://event/"
        guard record.hasPrefix(prefix) else { return nil }
        return Int(record.dropFirst(prefix.count))
    }
}

/// Whether a cloud `authorization_ref` still names a durable record that was
/// not physically erased. This is the frozen precondition the root ruling asks
/// the cloud path to recheck before executing a routine.
public enum BotCloudAuthorizationRefState: Sendable, Equatable {
    case valid
    case missing
    case unresolved
    case erased
}

public actor BotCloudAuthorizationResolver {
    private let store: SQLiteDomainStore
    private let scanLimit: Int

    public init(store: SQLiteDomainStore, scanLimit: Int = 10_000) {
        self.store = store
        self.scanLimit = max(1, scanLimit)
    }

    public func state(of ref: String?) async -> BotCloudAuthorizationRefState {
        guard let ref else { return .missing }
        guard let seq = BotRoutineSourceDependencyResolver.eventSequence(ref) else {
            return .unresolved
        }
        let events: [BotEvent]
        do {
            events = try await store.events(after: 0, limit: scanLimit)
        } catch {
            return .unresolved
        }
        guard events.contains(where: { $0.commitSeq == seq }) else { return .unresolved }
        for event in events where event.type == "erasure" {
            guard case .object(let data) = event.data,
                  case .array(let erased)? = data["erasedEvents"] else { continue }
            if erased.contains(where: { $0["record"]?.stringValue == ref }) {
                return .erased
            }
        }
        return .valid
    }
}

/// Cloud-scheduling authorization with the two frozen preconditions:
/// 1. the routine-local opt-in exists;
/// 2. its `authorization_ref` still resolves to a non-erased record.
///
/// `sourceDependency` is the optional N hook for a **real persisted basis**;
/// passing nil means "no N dependency check", not "N verified". F suppression is
/// deliberately not here: it only holds proactive candidates at the delivery
/// exit and never stops a scheduled routine.
public struct BotCloudScheduleConsentAuthorizer: CloudScheduleAuthorizing {
    public typealias RefCheck = @Sendable (String?) async -> Bool
    public typealias SourceDependency = @Sendable (Routine) async -> CloudScheduleReason?

    private let base: any CloudScheduleAuthorizing
    private let refCheck: RefCheck
    private let sourceDependency: SourceDependency?

    public init(base: any CloudScheduleAuthorizing = CloudScheduleAuthorizer(),
                refCheck: @escaping RefCheck,
                sourceDependency: SourceDependency? = nil) {
        self.base = base
        self.refCheck = refCheck
        self.sourceDependency = sourceDependency
    }

    public func refusal(for routine: Routine) async -> CloudScheduleReason? {
        if let refusal = await base.refusal(for: routine) { return refusal }
        guard await refCheck(routine.cloudSchedule?.authorizationRef) else {
            return .revoked
        }
        guard let sourceDependency else { return nil }
        return await sourceDependency(routine)
    }
}
