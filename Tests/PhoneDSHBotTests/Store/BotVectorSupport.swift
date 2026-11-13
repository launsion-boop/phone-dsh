// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PhoneDSHBot

/// Replays one declarative store/action vector case against the real
/// `SQLiteDomainStore` actor. The JSON files under
/// `spec/bot/v1/golden/*.phone.json` are the shared contract; this file only
/// interprets their operations.
final class BotVectorRunner {
    private(set) var store: SQLiteDomainStore?
    let fileURL: URL
    let clock: Int64
    let leaseTTLms: Int64
    let ephemeralCapacity: Int

    private var leases: [String: BotEffectLease] = [:]
    private var inboxCounters: [String: VectorCounter] = [:]

    init(fileURL: URL, clock: Int64, leaseTTLms: Int64, ephemeralCapacity: Int) {
        self.fileURL = fileURL
        self.clock = clock
        self.leaseTTLms = leaseTTLms
        self.ephemeralCapacity = ephemeralCapacity
    }

    func openIfNeeded() throws {
        guard store == nil else { return }
        store = try SQLiteDomainStore(
            fileURL: fileURL, now: { [clock] in clock },
            leaseTTLms: leaseTTLms, ephemeralCapacity: ephemeralCapacity)
    }

    func close() async {
        if let store {
            try? await store.close()
        }
        store = nil
    }

    func requireStore() throws -> SQLiteDomainStore {
        guard let store else {
            throw VectorError("store is not open")
        }
        return store
    }

    // MARK: - case execution

    func run(_ testCase: [String: Any], name: String) async throws {
        let steps = testCase["steps"] as? [[String: Any]] ?? []
        if let setup = testCase["setup"] as? [String: Any] {
            try VectorSQLite.makeSetupDatabase(setup, at: fileURL)
        }
        do {
            try openIfNeeded()
        } catch {
            if let expected = testCase["openError"] as? String {
                XCTAssertEqual(VectorErrorCode.of(error), expected, "\(name) open error")
                if let contains = testCase["openErrorContains"] as? String {
                    let detail = VectorErrorDetail.of(error)
                    XCTAssertTrue(detail.contains(contains),
                                  "\(name) open error detail \(detail) does not contain \(contains)")
                }
            } else {
                throw error
            }
            // A failed open may still be inspected on disk. Only read-only
            // inspection is meaningful after the store refused to open.
            for (index, step) in steps.enumerated() {
                let op = step["op"] as? String ?? "?"
                let label = "\(name).afterOpenError.steps[\(index)].\(op)"
                guard op == "raw" || op == "sql" else {
                    XCTFail("\(label): only raw/sql steps may follow a failed open")
                    continue
                }
                do {
                    let observation = try await runStep(step, label: label)
                    try assertObservation(step["expect"], observation, label: label)
                } catch {
                    let expect = step["expect"] as? [String: Any]
                    if let expected = expect?["error"] as? String {
                        XCTAssertEqual(VectorErrorCode.of(error), expected, "\(label) error")
                    } else {
                        XCTFail("\(label): unexpected error \(error)")
                    }
                }
            }
            await close()
            return
        }
        if let expected = testCase["openError"] as? String {
            XCTFail("\(name): expected open error \(expected), open succeeded")
            return
        }
        for (index, step) in steps.enumerated() {
            let label = "\(name).steps[\(index)].\(step["op"] as? String ?? "?")"
            do {
                let observation = try await runStep(step, label: label)
                try assertObservation(step["expect"], observation, label: label)
            } catch {
                let expect = step["expect"] as? [String: Any]
                if let expected = expect?["error"] as? String {
                    XCTAssertEqual(VectorErrorCode.of(error), expected, "\(label) error")
                    if expected.hasPrefix("simulatedCrash:abort-")
                        || expected.hasPrefix("schemaTooNew")
                        || expected.hasPrefix("commitGap") {
                        store = nil
                    }
                } else {
                    XCTFail("\(label): unexpected error \(error)")
                }
            }
        }
        await close()
    }

    func runStep(_ step: [String: Any], label: String) async throws -> [String: Any] {
        switch step["op"] as? String {
        case "append":
            let event = try decodeEvent(step["event"])
            let sequence = try await requireStore().append(event)
            return ["sequence": sequence]

        case "appendBatch":
            let events = try (step["events"] as? [Any] ?? []).map { try decodeEvent($0) }
            let sequences = try await requireStore().appendBatch(events)
            return ["sequences": sequences]

        case "events":
            let after = step["after"] as? Int ?? 0
            let limit = step["limit"] as? Int ?? 256
            let events = try await requireStore().events(after: after, limit: limit)
            return [
                "sequences": events.compactMap(\.commitSeq),
                "eventIds": events.map(\.eventId),
                "types": events.map(\.type),
                "batchIndices": events.map { event -> Any in
                    if let batch = event.batch { return batch.index }
                    return NSNull()
                },
                "batchTotal": events.first?.batch.map { $0.total as Any } ?? NSNull(),
                "batchIdsEqual": Set(events.compactMap { $0.batch?.id }).count <= 1,
            ]

        case "head":
            return ["head": try await requireStore().headCommitSeq()]

        case "payload":
            let data = try decodeJSON(step["data"])
            let bytes = try BotEventEnvelopeCodec().encodeData(data)
            let text = String(decoding: bytes, as: UTF8.self)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return ["canonical": text, "sha256": digest, "size": bytes.count]

        case "ephemeralAppend":
            let events = try (step["events"] as? [Any] ?? []).map { try decodeEvent($0) }
            var sequences: [Int] = []
            for event in events {
                sequences.append(try await requireStore().append(event))
            }
            let buffer = try await requireStore().ephemeralEvents(limit: ephemeralCapacity)
            return [
                "sequences": sequences,
                "buffer": buffer.map(\.eventId),
                "dropped": try await requireStore().droppedEphemeralCount(),
                "head": try await requireStore().headCommitSeq(),
            ]

        case "reopen":
            await close()
            try openIfNeeded()
            return ["head": try await requireStore().headCommitSeq()]

        case "sql":
            await close()
            try VectorSQLite.exec(step["statement"] as? String ?? "", at: fileURL)
            return ["ok": true]

        case "raw":
            await close()
            let rows = try VectorSQLite.query(step["query"] as? String ?? "", at: fileURL)
            return ["rows": rows]

        case "armCrash":
            try await requireStore().armCrashPoint(step["point"] as? String ?? "")
            return [:]

        case "event":
            let id = step["eventId"] as? String ?? ""
            guard let event = try await requireStore().event(withId: id) else {
                return ["exists": false]
            }
            return ["exists": true,
                    "commitSeq": event.commitSeq.map { $0 as Any } ?? NSNull(),
                    "type": event.type]

        case "eventData":
            let sequence = step["commitSeq"] as? Int ?? -1
            let events = try await requireStore().events(after: sequence - 1, limit: 1)
            guard let event = events.first else {
                return ["exists": false]
            }
            let key = step["dataKey"] as? String ?? ""
            return ["exists": true, "value": jsonCompatible(event.data[key] ?? .null)]

        case "effectEnqueue":
            let effect = try decodeEffect(step["effect"])
            let key = try await requireStore().enqueue(effect)
            return ["effectKey": key, "head": try await requireStore().headCommitSeq()]

        case "effectLease":
            let owner = step["owner"] as? String ?? ""
            let now = int64(step["now"], default: clock)
            let lease = try await requireStore().lease(owner: owner, now: now)
            return leaseObservation(lease)

        case "effectLeaseNext":
            let owner = step["owner"] as? String ?? ""
            let now = int64(step["now"], default: clock)
            let ttl = int64(step["ttlMs"], default: leaseTTLms)
            let lease = try await requireStore().leaseNext(owner: owner, now: now, ttlMs: ttl)
            if let lease, let expectedKey = step["effectKey"] as? String {
                XCTAssertEqual(lease.effectKey, expectedKey, "\(label) leased another effect")
            }
            return leaseObservation(lease)

        case "effectRenew":
            let lease = try leaseFor(step)
            let now = int64(step["now"], default: clock)
            let ttl = (step["ttlMs"] as? NSNumber).map { $0.int64Value }
            let renewed = try await requireStore().renew(lease, now: now, ttlMs: ttl)
            leases[renewed.effectKey] = renewed
            return ["attempt": renewed.attempt, "generation": renewed.generation,
                    "leaseExpiresAt": renewed.leaseExpiresAt,
                    "leaseOwner": renewed.leaseOwner]

        case "effectAck":
            let lease = try leaseFor(step)
            try await requireStore().ack(lease, resultRef: step["resultRef"] as? String)
            let record = try await requireStore().effect(lease.effectKey)
            return ["state": record?.state.rawValue ?? NSNull(),
                    "head": try await requireStore().headCommitSeq()]

        case "effectFail":
            let lease = try leaseFor(step)
            try await requireStore().fail(
                lease, errorClass: step["errorClass"] as? String ?? "",
                reason: step["reason"] as? String ?? "")
            let record = try await requireStore().effect(lease.effectKey)
            return [
                "state": record?.state.rawValue ?? NSNull(),
                "head": try await requireStore().headCommitSeq(),
                "attempt": record.map { $0.attempt as Any } ?? NSNull(),
                "attempts": record.map { $0.attempts as Any } ?? NSNull(),
                "notBefore": record?.effect.notBefore.map { $0 as Any } ?? NSNull(),
            ]

        case "effectRelease":
            let lease = try leaseFor(step)
            _ = try await requireStore().release(lease)
            let record = try await requireStore().effect(lease.effectKey)
            return [
                "state": record?.state.rawValue ?? NSNull(),
                "head": try await requireStore().headCommitSeq(),
                "attempt": record.map { $0.attempt as Any } ?? NSNull(),
                "attempts": record.map { $0.attempts as Any } ?? NSNull(),
                "notBefore": record?.effect.notBefore.map { $0 as Any } ?? NSNull(),
            ]

        case "effectMarkReconciliation":
            let key = step["effectKey"] as? String ?? ""
            try await requireStore().markNeedsReconciliation(
                key, reason: step["reason"] as? String ?? "")
            let record = try await requireStore().effect(key)
            return ["state": record?.state.rawValue ?? NSNull(),
                    "head": try await requireStore().headCommitSeq()]

        case "effectAckReconciled":
            let key = step["effectKey"] as? String ?? ""
            try await requireStore().ackReconciled(
                effectKey: key,
                generation: step["generation"] as? Int ?? 0,
                attempt: step["attempt"] as? Int ?? 0,
                resultRef: step["resultRef"] as? String)
            let record = try await requireStore().effect(key)
            return ["state": record?.state.rawValue ?? NSNull(),
                    "head": try await requireStore().headCommitSeq()]

        case "effectCancel":
            let key = step["effectKey"] as? String ?? ""
            try await requireStore().requestCancel(key, reason: step["reason"] as? String ?? "")
            let record = try await requireStore().effect(key)
            return ["state": record?.state.rawValue ?? NSNull(),
                    "head": try await requireStore().headCommitSeq()]

        case "effectConfirmCancel":
            let lease = try leaseFor(step)
            try await requireStore().confirmCancel(lease, reason: step["reason"] as? String ?? "")
            let record = try await requireStore().effect(lease.effectKey)
            return ["state": record?.state.rawValue ?? NSNull(),
                    "head": try await requireStore().headCommitSeq()]

        case "effectRecord", "effect":
            let key = step["effectKey"] as? String ?? ""
            guard let record = try await requireStore().effect(key) else {
                return ["exists": false]
            }
            return [
                "exists": true,
                "state": record.state.rawValue,
                "attempt": record.attempt,
                "attempts": record.attempts,
                "generation": record.generation,
                "enqueuedCommitSeq": record.enqueuedCommitSeq,
                "leaseOwner": record.leaseOwner.map { $0 as Any } ?? NSNull(),
                "resultRef": record.resultRef.map { $0 as Any } ?? NSNull(),
                "reconciliationReason": record.reconciliationReason.map { $0 as Any } ?? NSNull(),
                "lastError": record.lastError.map { $0 as Any } ?? NSNull(),
                "notBefore": record.effect.notBefore.map { $0 as Any } ?? NSNull(),
                "errorClass": record.errorClass.map { $0 as Any } ?? NSNull(),
            ]

        case "effects":
            let records = try await requireStore().effects()
            return [
                "keys": records.map(\.effectKey),
                "states": records.map(\.state.rawValue),
                "enqueuedCommitSeq": records.map(\.enqueuedCommitSeq),
            ]

        case "effectInbox":
            let receiver = step["receiver"] as? String ?? ""
            let key = step["effectKey"] as? String ?? ""
            let lease = try leaseFor(step)
            let expectedResult = step["resultRef"] as? String ?? ""
            let box = try SQLiteBotEffectInbox(
                store: try requireStore(), receiver: receiver, now: { [clock] in clock })
            let counterKey = "\(receiver)\u{0}\(key)"
            let counter = inboxCounters[counterKey] ?? VectorCounter()
            inboxCounters[counterKey] = counter
            let repeatCount = step["repeat"] as? Int ?? 1
            var deduped = 0
            var result: String?
            for _ in 0..<repeatCount {
                let applied = try await box.apply(lease) { _ in
                    counter.increment()
                    return expectedResult
                }
                if applied.deduped { deduped += 1 }
                if result == nil { result = applied.resultRef }
            }
            let executions = counter.value
            return ["dedupedCount": deduped, "executions": executions,
                    "resultRef": result.map { $0 as Any } ?? NSNull()]

        case "action":
            let action = try decodeAction(step["action"])
            let plan = try decodePlan(step["plan"])
            let before = try await requireStore().headCommitSeq()
            let result = try await requireStore().performAndRecord(action: action, plan: plan)
            let after = try await requireStore().headCommitSeq()
            let events = try await requireStore().events(after: before, limit: 256)
            var observation: [String: Any] = [
                "status": result.status,
                "head": after,
                "eventTypes": events.map(\.type),
                "sequences": events.compactMap(\.commitSeq),
            ]
            if let eventID = result.eventID { observation["eventID"] = eventID }
            if let reason = result.reason { observation["reason"] = reason }
            return observation

        case "nonce":
            let bot = step["botID"] as? String ?? ""
            let nonce = step["nonce"] as? String ?? ""
            if let eventID = try await requireStore().eventID(botID: bot, nonce: nonce) {
                return ["eventID": eventID]
            }
            return ["exists": false]

        default:
            throw VectorError("unknown operation \(step["op"] ?? "?")")
        }
    }

    // MARK: - decode helpers

    func decodeEvent(_ value: Any?) throws -> BotEvent {
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(BotEvent.self, from: data)
    }

    func decodeJSON(_ value: Any?) throws -> BotJSONValue {
        if value == nil || value is NSNull {
            return .null
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try BotJSONValue.parse(data)
    }

    func decodeEffect(_ value: Any?) throws -> BotEffect {
        let object = value as? [String: Any] ?? [:]
        return BotEffect(
            effectKey: object["effectKey"] as? String ?? "",
            kind: object["kind"] as? String ?? "generic",
            operation: object["operation"] as? String ?? "",
            target: object["target"] as? String,
            canonicalResource: object["canonicalResource"] as? String ?? "",
            argsDigest: object["argsDigest"] as? String ?? "",
            payloadDigest: object["payloadDigest"] as? String,
            logicalKey: object["logicalKey"] as? String ?? "",
            idempotent: object["idempotent"] as? Bool ?? false,
            retryPolicy: object["retryPolicy"] as? String,
            maxAttempts: object["maxAttempts"] as? Int,
            generation: object["generation"] as? Int ?? 1,
            notBefore: (object["notBefore"] as? NSNumber)?.int64Value)
    }

    func decodeAction(_ value: Any?) throws -> BotUserAction {
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(BotUserAction.self, from: data)
    }

    func decodePlan(_ value: Any?) throws -> BotUserActionPlan {
        let object = value as? [String: Any] ?? [:]
        let event = try decodeEvent(object["event"])
        let effects = try (object["effects"] as? [Any] ?? []).map { try decodeEffect($0) }
        return BotUserActionPlan(event: event, effects: effects)
    }

    func leaseFor(_ step: [String: Any]) throws -> BotEffectLease {
        if let object = step["lease"] as? [String: Any] {
            return BotEffectLease(
                effectKey: object["effectKey"] as? String ?? "",
                attempt: object["attempt"] as? Int ?? 0,
                leaseOwner: object["leaseOwner"] as? String ?? "",
                leaseExpiresAt: int64(object["leaseExpiresAt"], default: 0),
                generation: object["generation"] as? Int ?? 0)
        }
        let key = step["effectKey"] as? String ?? ""
        guard let lease = leases[key] else {
            throw VectorError("no lease recorded for \(key)")
        }
        return lease
    }

    func leaseObservation(_ lease: BotEffectLease?) -> [String: Any] {
        guard let lease else {
            return ["lease": NSNull()]
        }
        leases[lease.effectKey] = lease
        return [
            "attempt": lease.attempt,
            "generation": lease.generation,
            "leaseOwner": lease.leaseOwner,
            "leaseExpiresAt": lease.leaseExpiresAt,
        ]
    }

    func assertObservation(_ expect: Any?, _ observation: [String: Any], label: String) throws {
        guard let expect = expect as? [String: Any] else { return }
        for (key, expected) in expect {
            if key == "lastErrorContains" {
                let text = (observation["lastError"] as? String) ?? ""
                XCTAssertTrue(text.contains(expected as? String ?? ""),
                              "\(label): lastError \(text) does not contain \(expected)")
                continue
            }
            if key == "lastErrorNotContains" {
                let text = (observation["lastError"] as? String) ?? ""
                XCTAssertFalse(text.contains(expected as? String ?? ""),
                               "\(label): lastError \(text) unexpectedly contains \(expected)")
                continue
            }
            let actual = observation[key] ?? NSNull()
            XCTAssertTrue(jsonEqual(expected, actual),
                          "\(label): \(key) expected \(expected), got \(actual)")
        }
    }

    func jsonCompatible(_ value: BotJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(jsonCompatible)
        case let .object(values): return values.mapValues(jsonCompatible)
        }
    }

    func int64(_ value: Any?, default fallback: Int64) -> Int64 {
        (value as? NSNumber)?.int64Value ?? fallback
    }

    func jsonEqual(_ expected: Any, _ actual: Any) -> Bool {
        if expected is NSNull || actual is NSNull {
            return expected is NSNull && actual is NSNull
        }
        if let left = expected as? NSNumber, let right = actual as? NSNumber {
            let leftBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightBool = CFGetTypeID(right) == CFBooleanGetTypeID()
            if leftBool || rightBool {
                return left.boolValue == right.boolValue
            }
            return left.doubleValue == right.doubleValue
        }
        if let left = expected as? String, let right = actual as? String {
            return left == right
        }
        if let left = expected as? [Any], let right = actual as? [Any] {
            return left.count == right.count
                && zip(left, right).allSatisfy { jsonEqual($0, $1) }
        }
        if let left = expected as? [String: Any], let right = actual as? [String: Any] {
            return left.keys.allSatisfy { jsonEqual(left[$0]!, right[$0] ?? NSNull()) }
        }
        return String(describing: expected) == String(describing: actual)
    }
}

struct VectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum VectorErrorCode {
    static func of(_ error: Error) -> String {
        if let error = error as? BotEventValidationError {
            return error.code
        }
        if let error = error as? SQLiteDomainStoreError {
            switch error {
            case .closed: return "closed"
            case .invalidConfiguration: return "invalidConfiguration"
            case .invalidCursor: return "invalidCursor"
            case let .commitGap(expected, actual): return "commitGap:\(expected):\(actual)"
            case .corrupted: return "corrupted"
            case let .schemaTooNew(version): return "schemaTooNew:\(version)"
            case .sqlite: return "sqlite"
            case .unknownEffect: return "unknownEffect"
            case .staleLease: return "staleLease"
            case .invalidTransition: return "invalidTransition"
            case let .simulatedCrash(point): return "simulatedCrash:\(point)"
            }
        }
        if let error = error as? VectorError {
            return error.description
        }
        return String(describing: error)
    }
}

enum VectorErrorDetail {
    static func of(_ error: Error) -> String {
        if let storeError = error as? SQLiteDomainStoreError,
           case let .corrupted(detail) = storeError {
            return detail
        }
        return String(describing: error)
    }
}

final class VectorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

enum VectorSQLite {
    static func makeSetupDatabase(_ setup: [String: Any], at file: URL) throws {
        let version = (setup["userVersion"] as? NSNumber)?.intValue ?? 2
        try withDatabase(file) { handle in
            var sql = """
                CREATE TABLE bot_events (
                    commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
                    event_id TEXT NOT NULL UNIQUE,
                    event_type TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                """
            if version >= 2 {
                sql += """
                    CREATE TABLE bot_user_action_nonces (
                        bot_id TEXT NOT NULL,
                        nonce TEXT NOT NULL,
                        event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id),
                        created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
                        PRIMARY KEY(bot_id, nonce)
                    );
                    """
            }
            try exec(sql, handle: handle)

            let codec = BotEventEnvelopeCodec()
            for value in setup["events"] as? [Any] ?? [] {
                let event = try JSONDecoder().decode(
                    BotEvent.self, from: JSONSerialization.data(withJSONObject: value))
                let payload = try codec.encode(event)
                try insertEvent(event, payload: payload, handle: handle)
            }
            for value in setup["nonces"] as? [Any] ?? [] {
                let nonce = value as? [String: Any] ?? [:]
                try insertNonce(nonce, handle: handle)
            }
            try exec("PRAGMA user_version=\(version)", handle: handle)
        }
    }

    static func query(_ sql: String, at file: URL) throws -> [[Any]] {
        try withDatabase(file) { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw VectorError(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [Any] = []
                for index in 0..<sqlite3_column_count(statement) {
                    if sqlite3_column_type(statement, index) == SQLITE_NULL {
                        row.append(NSNull())
                    } else if let text = sqlite3_column_text(statement, index) {
                        row.append(String(cString: text))
                    } else {
                        row.append(NSNull())
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    static func exec(_ sql: String, at file: URL) throws {
        try withDatabase(file) { handle in
            try exec(sql, handle: handle)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func withDatabase<T>(_ file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let open = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard open == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw VectorError(message)
        }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }

    private static func exec(_ sql: String, handle: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite \(result)"
            sqlite3_free(error)
            throw VectorError(message)
        }
    }

    private static func insertEvent(_ event: BotEvent, payload: Data, handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VectorError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(event.commitSeq ?? 0))
        sqlite3_bind_text(statement, 2, event.eventId, -1, transient)
        sqlite3_bind_text(statement, 3, event.type, -1, transient)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(payload.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorError(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private static func insertNonce(_ nonce: [String: Any], handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq)
            VALUES (?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VectorError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, nonce["botId"] as? String ?? "", -1, transient)
        sqlite3_bind_text(statement, 2, nonce["nonce"] as? String ?? "", -1, transient)
        sqlite3_bind_text(statement, 3, nonce["eventId"] as? String ?? "", -1, transient)
        sqlite3_bind_int64(statement, 4, Int64((nonce["createdCommitSeq"] as? NSNumber)?.int64Value ?? 0))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorError(String(cString: sqlite3_errmsg(handle)))
        }
    }
}

enum BotVectorFixture {
    static func load(_ name: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/bot/v1/golden/\(name)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let object else {
            throw VectorError("\(name) is not an object")
        }
        let valid = object["valid"] as? [[String: Any]] ?? []
        let invalid = object["invalid"] as? [[String: Any]] ?? []
        guard !valid.isEmpty, !invalid.isEmpty else {
            throw VectorError("\(name) must carry valid and invalid cases")
        }
        return valid + invalid
    }

    static func fileURL(for testCase: [String: Any], directory: URL) -> URL {
        let name = (testCase["name"] as? String ?? "case")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
    }
}
