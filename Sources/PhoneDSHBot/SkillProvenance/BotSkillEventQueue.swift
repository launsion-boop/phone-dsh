// SPDX-License-Identifier: MIT

import Foundation

/// One bounded, content-free producer diagnostic. The durable skill event is
/// still L's `skill.changed`; this ring exists only so a failed observer or
/// runtime write is visible instead of being swallowed.
public struct BotSkillDiagnostic: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case recorded
        case failed
        case skipped
    }

    public var action: String
    public var key: String
    public var outcome: Outcome
    public var detail: String?
    public var atMS: Int64

    public init(action: String, key: String, outcome: Outcome,
                detail: String?, atMS: Int64) {
        self.action = action
        self.key = key
        self.outcome = outcome
        self.detail = detail
        self.atMS = atMS
    }
}

/// Serializes observer/runtime skill mutations per actual producer. `enqueue`
/// is synchronous on the caller thread, so a fast write→delete preserves the
/// callback order while the producer work remains async. Failures are logged
/// and also retained in a bounded 64-entry readable ring; they are never
/// silently retried.
public final class BotSkillEventQueue: @unchecked Sendable {
    public static let diagnosticCapacity = 64

    private let producer: BotSkillProvenanceProducer
    private let lock = NSLock()
    private var tail: Task<Void, Never> = Task {}
    private var suppressedUserFiles: Set<String> = []
    private var diagnostics: [BotSkillDiagnostic] = []
    private var observerSuppressions: [String: [(operationID: String, expiresAtMS: Int64)]] = [:]
    private let now: @Sendable () -> Int64

    public init(producer: BotSkillProvenanceProducer,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.producer = producer
        self.now = now
    }

    /// Synchronous FIFO enqueue. The operation is chained after the previous
    /// one under the lock, so callback order is preserved even when the
    /// producer awaits.
    public func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        _ = enqueueTask(operation)
    }

    /// Enqueue and wait for this mutation to finish before the caller returns.
    /// The runtime write path uses this so a successful tool result cannot be
    /// observed before its `skill.changed` carrier exists.
    public func enqueueAndWait(_ operation: @escaping @Sendable () async -> Void) async {
        await enqueueTask(operation).value
    }

    @discardableResult
    private func enqueueTask(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        let previous = tail
        let next = Task {
            await previous.value
            await operation()
        }
        tail = next
        lock.unlock()
        return next
    }

    /// Suppress the filesystem observer for one feature-admin operation. The
    /// applied record is injected through `userWrite/Delete(sources:)`; the
    /// observer must not append a second, unsourced event. Entries are bounded
    /// by TTL and removed by operation id or by the matching observed change.
    public func suppressObserverMutation(fileName: String, action: String,
                                         operationID: String,
                                         ttlMS: Int64 = 60_000) {
        let key = "\(action):\(fileName)"
        let expiry = Int64(Date().timeIntervalSince1970 * 1_000) + max(1, ttlMS)
        lock.lock()
        observerSuppressions[key, default: []].append((operationID, expiry))
        lock.unlock()
    }

    public func clearObserverSuppression(operationID: String) {
        lock.lock()
        observerSuppressions = observerSuppressions.compactMapValues { entries in
            let kept = entries.filter { $0.operationID != operationID }
            return kept.isEmpty ? nil : kept
        }
        lock.unlock()
    }

    private func consumeObserverSuppression(fileName: String, action: String) -> Bool {
        let key = "\(action):\(fileName)"
        let wall = Int64(Date().timeIntervalSince1970 * 1_000)
        lock.lock()
        var entries = observerSuppressions[key] ?? []
        entries.removeAll { $0.expiresAtMS <= wall }
        let consumed = !entries.isEmpty
        if consumed { entries.removeFirst() }
        observerSuppressions[key] = entries.isEmpty ? nil : entries
        lock.unlock()
        return consumed
    }

    public func observeUserWrite(_ name: String) async {
        if consumeObserverSuppression(fileName: name, action: "write") {
            record(action: "observer-write", key: name, outcome: .skipped,
                   detail: "suppressed feature-admin operation")
            return
        }
        await userWrite(name)
    }

    public func observeUserDelete(_ name: String) async {
        if consumeObserverSuppression(fileName: name, action: "delete") {
            record(action: "observer-delete", key: name, outcome: .skipped,
                   detail: "suppressed feature-admin operation")
            return
        }
        await userDelete(name)
    }

    public func userWrite(_ name: String,
                          sources: [BotDerivationSource] = []) async {
        do {
            _ = try await producer.recordUserDshWrite(fileName: name, sources: sources)
            record(action: "user-write", key: name, outcome: .recorded, detail: nil)
        } catch {
            record(action: "user-write", key: name, outcome: .failed,
                   detail: String(describing: error))
            NSLog("BOT_SKILL_PRODUCER_FAILED action=user-write name=%@ error=%@",
                  name, String(describing: error))
        }
    }

    public func userDelete(_ name: String,
                           sources: [BotDerivationSource] = []) async {
        do {
            _ = try await producer.recordUserDshDelete(fileName: name, sources: sources)
            record(action: "user-delete", key: name, outcome: .recorded, detail: nil)
        } catch {
            record(action: "user-delete", key: name, outcome: .failed,
                   detail: String(describing: error))
            NSLog("BOT_SKILL_PRODUCER_FAILED action=user-delete name=%@ error=%@",
                  name, String(describing: error))
        }
    }

    public func botDelete(vfs: String, botID: String) async {
        do {
            _ = try await producer.recordBotDelete(
                vfsPath: vfs, botID: botID, sessionID: nil)
            record(action: "project-delete", key: vfs, outcome: .recorded, detail: nil)
        } catch {
            record(action: "project-delete", key: vfs, outcome: .failed,
                   detail: String(describing: error))
            NSLog("BOT_SKILL_PRODUCER_FAILED action=project-delete path=%@ error=%@",
                  vfs, String(describing: error))
        }
    }

    /// Runtime write/edit after a successful tool result. This replaces the
    /// former `try? recordBotWrite`; failures are visible, not silent.
    public func runtimeWrite(vfs: String, botID: String, sessionID: String?,
                             sources: [BotDerivationSource] = []) async {
        do {
            _ = try await producer.recordBotWrite(
                vfsPath: vfs, botID: botID, sessionID: sessionID,
                sources: sources)
            record(action: "runtime-write", key: vfs, outcome: .recorded, detail: nil)
        } catch {
            record(action: "runtime-write", key: vfs, outcome: .failed,
                   detail: String(describing: error))
            NSLog("BOT_SKILL_PRODUCER_FAILED action=runtime-write path=%@ error=%@",
                  vfs, String(describing: error))
        }
    }

    public func diagnosticsSnapshot() -> [BotSkillDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return diagnostics
    }

    private func record(action: String, key: String,
                        outcome: BotSkillDiagnostic.Outcome, detail: String?) {
        lock.lock(); defer { lock.unlock() }
        diagnostics.append(BotSkillDiagnostic(
            action: action, key: key, outcome: outcome,
            detail: detail.map { String($0.prefix(160)) }, atMS: now()))
        if diagnostics.count > Self.diagnosticCapacity {
            diagnostics.removeFirst(diagnostics.count - Self.diagnosticCapacity)
        }
    }
}
