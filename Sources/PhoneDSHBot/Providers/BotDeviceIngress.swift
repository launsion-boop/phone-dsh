// SPDX-License-Identifier: MIT

import Foundation

public enum BotDeviceIngressDisposition: String, Sendable {
    case ready
    case buffered
    case duplicate
}

public struct BotDeviceIngressReceipt: Sendable, Equatable {
    public let eventID: String
    public let disposition: BotDeviceIngressDisposition

    public init(eventID: String, disposition: BotDeviceIngressDisposition) {
        self.eventID = eventID
        self.disposition = disposition
    }
}

public protocol BotDeviceMessageDelivering: Actor {
    func deliverDeviceMessages() async throws
}

/// Durable, transport-independent device ingress.
///
/// Ordering domains are `(device_id, epoch, seq)`. A delivered-seq watermark is
/// persisted in the WakeInbox snapshot; only the new contiguous tail is
/// enqueued, so reopening never replays accepted history. A gap that waits too
/// long (or buffers too many out-of-order messages) is skipped with a durable
/// user-visible `ui.notice` carrying `data.kind = "device.gap"`.
public actor BotDeviceIngress {
    public typealias WakeHandler = @Sendable (WakeSignal) -> Void

    private struct DeviceMessageKey: Hashable {
        let deviceID: String
        let epoch: Int64
        let msgID: String
    }

    private struct Accepted {
        let envelope: BotDeviceEnvelope
        let transport: BotDeviceTransport
        let displayName: String
        let receivedAt: Int64
    }

    public let store: SQLiteDomainStore
    public let inbox: WakeInbox
    public let botID: String

    private let now: @Sendable () -> Int64
    private let gapSkipAfterMs: Int64
    private let maxBufferedPerDevice: Int
    private let onWake: WakeHandler?
    private var accepted: [DeviceMessageKey: Accepted] = [:]
    private var sequenceOwners: [String: [Int64: [Int64: DeviceMessageKey]]] = [:]
    private var buffered: [String: [Int64: [Int64: Accepted]]] = [:]
    private var watermarks: [String: [Int64: Int64]] = [:]
    private var maxEpochs: [String: Int64] = [:]
    private var reserving: Set<DeviceMessageKey> = []
    private var reservedSequences: [String: [Int64: Set<Int64>]] = [:]
    private var loaded = false
    private var driver: (any BotDeviceMessageDelivering)?
    private var delivering = false

    public init(store: SQLiteDomainStore, botID: String = "main", inbox: WakeInbox? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                onWake: WakeHandler? = nil,
                gapSkipAfterMs: Int64 = 30_000,
                maxBufferedPerDevice: Int = 32) {
        self.store = store
        self.botID = botID
        self.inbox = inbox ?? WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        self.now = now
        self.onWake = onWake
        self.gapSkipAfterMs = max(0, gapSkipAfterMs)
        self.maxBufferedPerDevice = max(1, maxBufferedPerDevice)
    }

    public func attach(_ driver: any BotDeviceMessageDelivering) async throws {
        self.driver = driver
        try await recover()
    }

    public func detach() {
        driver = nil
    }

    public func receive(data: Data, transport: BotDeviceTransport,
                        expectedSessionID: String, displayName: String) async throws -> BotDeviceIngressReceipt {
        let envelope = try BotDeviceEnvelope(data: data, expectedSessionID: expectedSessionID)
        return try await receive(envelope, transport: transport,
                                 expectedSessionID: expectedSessionID, displayName: displayName)
    }

    public func receive(_ envelope: BotDeviceEnvelope, transport: BotDeviceTransport,
                        expectedSessionID: String, displayName: String) async throws -> BotDeviceIngressReceipt {
        try envelope.validateIngress(expectedSessionID: expectedSessionID)
        try await synchronize()
        return try await accept(envelope, transport: transport, displayName: displayName)
    }

    public func recover() async throws {
        try await synchronize()
        guard driver != nil else { return }
        _ = try await inbox.recover(kind: "device-event")
        try await restoreReadyItems()
        try await deliverAvailable()
    }

    public func deliverAvailable() async throws {
        guard let driver, !delivering else { return }
        delivering = true
        defer { delivering = false }
        for _ in 0..<WakeInbox.maxItems {
            let ready = try await readyPendingItems()
            guard !ready.isEmpty else { return }
            try await driver.deliverDeviceMessages()
        }
        let remaining = try await readyPendingItems()
        if !remaining.isEmpty {
            throw BotDeviceEnvelopeError.sequence("device delivery did not drain the ready inbox")
        }
    }

    private func accept(_ envelope: BotDeviceEnvelope, transport: BotDeviceTransport,
                        displayName: String) async throws -> BotDeviceIngressReceipt {
        let key = DeviceMessageKey(deviceID: envelope.deviceID, epoch: envelope.epoch, msgID: envelope.msgID)
        let eventID = envelope.eventID
        if let existing = accepted[key] {
            guard try existing.envelope.canonicalData() == envelope.canonicalData(),
                  existing.transport == transport else {
                throw BotDeviceEnvelopeError.conflict(eventID)
            }
            return BotDeviceIngressReceipt(eventID: eventID, disposition: .duplicate)
        }
        if let maxEpoch = maxEpochs[key.deviceID], key.epoch < maxEpoch {
            throw BotDeviceEnvelopeError.sequence("stale device epoch \(key.epoch) (current \(maxEpoch))")
        }
        if let owner = sequenceOwners[key.deviceID]?[key.epoch]?[envelope.seq] {
            guard owner == key else {
                throw BotDeviceEnvelopeError.conflict("duplicate device seq \(envelope.seq)")
            }
            return BotDeviceIngressReceipt(eventID: eventID, disposition: .duplicate)
        }
        if let watermark = watermarks[key.deviceID]?[key.epoch], envelope.seq <= watermark {
            throw BotDeviceEnvelopeError.sequence(
                "message seq \(envelope.seq) is at or below the delivered watermark \(watermark)")
        }
        // The actor is re-entrant at every await below. Reserve the key and seq
        // synchronously so two concurrent accepts cannot commit the same
        // device/epoch/seq before the first durable append returns.
        guard !reserving.contains(key),
              reservedSequences[key.deviceID]?[key.epoch]?.contains(envelope.seq) != true else {
            throw BotDeviceEnvelopeError.conflict("device message is already being accepted")
        }
        reserving.insert(key)
        reservedSequences[key.deviceID, default: [:]][key.epoch, default: []].insert(envelope.seq)
        defer {
            reserving.remove(key)
            reservedSequences[key.deviceID]?[key.epoch]?.remove(envelope.seq)
            if reservedSequences[key.deviceID]?[key.epoch]?.isEmpty == true {
                reservedSequences[key.deviceID]?.removeValue(forKey: key.epoch)
            }
            if reservedSequences[key.deviceID]?.isEmpty == true {
                reservedSequences.removeValue(forKey: key.deviceID)
            }
        }

        let sessionID = try await requireMainSession()
        let receivedAt = now()
        let event = try envelope.ingressEvent(
            botID: botID, mainSessionID: sessionID, transport: transport,
            displayName: displayName, receivedAt: receivedAt)
        // `store.append` is idempotent on `event_id`, so a duplicate commit by
        // another ingress instance returns the existing row instead of a
        // second one. Check first, then keep the UNIQUE violation as defense in
        // depth: the durable identity of a device message is the `bot_events`
        // `event_id` key `dev:<device>:<epoch>:<msg>` (there is no separate
        // device table). First writer wins.
        if let receipt = try await existingDeviceMessage(
            eventID: eventID, key: key, envelope: envelope, transport: transport,
            displayName: displayName, receivedAt: receivedAt) {
            return receipt
        }
        do {
            _ = try await store.append(event)
        } catch {
            if let receipt = try await existingDeviceMessage(
                eventID: eventID, key: key, envelope: envelope, transport: transport,
                displayName: displayName, receivedAt: receivedAt) {
                return receipt
            }
            throw error
        }
        let value = Accepted(
            envelope: envelope, transport: transport, displayName: displayName, receivedAt: receivedAt)
        accepted[key] = value
        sequenceOwners[key.deviceID, default: [:]][key.epoch, default: [:]][envelope.seq] = key
        if envelope.epoch > (maxEpochs[key.deviceID] ?? -1) {
            maxEpochs[key.deviceID] = envelope.epoch
        }
        buffered[key.deviceID, default: [:]][key.epoch, default: [:]][envelope.seq] = value
        let ready = try await releaseReadyItems(deviceID: key.deviceID)
        return BotDeviceIngressReceipt(
            eventID: eventID, disposition: ready.contains(eventID) ? .ready : .buffered)
    }

    /// Reads a message another writer committed first. Returns nil when the
    /// event id is not stored; throws `conflict` when the stored envelope or
    /// transport differs from the incoming delivery.
    private func existingDeviceMessage(
        eventID: String, key: DeviceMessageKey, envelope: BotDeviceEnvelope,
        transport: BotDeviceTransport, displayName: String, receivedAt: Int64
    ) async throws -> BotDeviceIngressReceipt? {
        guard let stored = try await store.event(withId: eventID) else { return nil }
        guard stored.type == "device.event",
              stored.principal.botId == botID,
              let storedTransport = stored.data["transport"]?.stringValue,
              storedTransport == transport.rawValue,
              let storedValue = stored.data["envelope"],
              let rawEnvelope = try? storedValue.encoded(),
              let storedEnvelope = try? BotDeviceEnvelope(data: rawEnvelope),
              (try? storedEnvelope.canonicalData()) == (try? envelope.canonicalData()) else {
            throw BotDeviceEnvelopeError.conflict(eventID)
        }
        let storedReceivedAt = stored.data["receivedAt"]?.intValue.map { Int64($0) }
        let value = Accepted(
            envelope: storedEnvelope, transport: transport,
            displayName: stored.data["displayName"]?.stringValue ?? displayName,
            receivedAt: storedReceivedAt ?? receivedAt)
        accepted[key] = value
        sequenceOwners[key.deviceID, default: [:]][key.epoch, default: [:]][storedEnvelope.seq] = key
        if storedEnvelope.epoch > (maxEpochs[key.deviceID] ?? -1) {
            maxEpochs[key.deviceID] = storedEnvelope.epoch
        }
        return BotDeviceIngressReceipt(eventID: eventID, disposition: .duplicate)
    }

    private func synchronize() async throws {
        if loaded { return }
        let storedCursors = try await inbox.deviceCursors()
        watermarks = storedCursors.mapValues { epochs in
            Dictionary(uniqueKeysWithValues: epochs.compactMap { key, value in
                Int64(key).map { ($0, value) }
            })
        }
        var cursor = 0
        while true {
            let events = try await store.events(after: cursor, limit: 500)
            for event in events where event.type == "device.event" && event.principal.botId == botID {
                guard event.principal.kind == "device",
                      event.eventId == event.traceId, event.eventId == event.correlationId,
                      case .local(let source) = event.origin,
                      let transportValue = event.data["transport"]?.stringValue,
                      let transport = BotDeviceTransport(rawValue: transportValue),
                      let envelopeValue = event.data["envelope"],
                      let rawEnvelope = try? envelopeValue.encoded(),
                      let envelope = try? BotDeviceEnvelope(data: rawEnvelope),
                      source == "device:\(transport.rawValue):\(envelope.deviceID)" else {
                    throw SQLiteDomainStoreError.corrupted("invalid device.event projection")
                }
                let key = DeviceMessageKey(
                    deviceID: envelope.deviceID, epoch: envelope.epoch, msgID: envelope.msgID)
                if accepted[key] != nil { continue }
                if let owner = sequenceOwners[key.deviceID]?[key.epoch]?[envelope.seq],
                   owner != key {
                    // A committed duplicate seq is corrupt input. Keep the first
                    // committed message and move on; one bad device must not
                    // wedge replay for every device.
                    continue
                }
                let receivedAt: Int64
                if let hostReceivedAt = event.data["receivedAt"]?.intValue {
                    receivedAt = Int64(hostReceivedAt)
                } else {
                    receivedAt = event.time
                }
                let displayName = event.data["displayName"]?.stringValue ?? envelope.deviceID
                let value = Accepted(
                    envelope: envelope, transport: transport,
                    displayName: displayName, receivedAt: receivedAt)
                accepted[key] = value
                sequenceOwners[key.deviceID, default: [:]][key.epoch, default: [:]][envelope.seq] = key
                if envelope.epoch > (maxEpochs[key.deviceID] ?? -1) {
                    maxEpochs[key.deviceID] = envelope.epoch
                }
                let watermark = watermarks[key.deviceID]?[key.epoch] ?? -1
                if envelope.seq > watermark {
                    buffered[key.deviceID, default: [:]][key.epoch, default: [:]][envelope.seq] = value
                }
            }
            guard events.count == 500, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        loaded = true
    }

    private func restoreReadyItems() async throws {
        for deviceID in Set(buffered.keys) {
            _ = try await releaseReadyItems(deviceID: deviceID)
        }
    }

    private func requireMainSession() async throws -> String {
        var cursor = 0
        var found: String?
        while true {
            let events = try await store.events(after: cursor, limit: 500)
            for event in events where event.type == "runtime.started"
                && event.principal.botId == botID && event.principal.kind == "chat" {
                found = event.data["sessionId"]?.stringValue ?? event.principal.sessionId
            }
            guard events.count == 500, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        guard let found, !found.isEmpty else { throw BotMCPError.unavailable("main Bot session is not started") }
        return found
    }

    private func releaseReadyItems(deviceID: String) async throws -> Set<String> {
        var released: Set<String> = []
        guard let epochs = buffered[deviceID] else { return released }
        for epoch in epochs.keys.sorted() {
            guard var pending = buffered[deviceID]?[epoch], !pending.isEmpty else { continue }
            let watermark = watermarks[deviceID]?[epoch]
            var expected: Int64
            if let watermark {
                guard watermark < Int64.max else { continue }
                expected = watermark + 1
            } else {
                expected = pending.keys.min() ?? 0
            }
            var forced = pending.count > maxBufferedPerDevice
            while true {
                if let value = pending[expected] {
                    let item = try value.envelope.heldItem(
                        transport: value.transport, displayName: value.displayName,
                        receivedAt: value.receivedAt)
                    _ = try await inbox.enqueue(item)
                    pending.removeValue(forKey: expected)
                    buffered[deviceID]?[epoch] = pending
                    setWatermark(deviceID: deviceID, epoch: epoch, seq: expected)
                    try await inbox.advanceDeviceCursor(
                        deviceID: deviceID, epoch: epoch, seq: expected)
                    released.insert(value.envelope.eventID)
                    onWake?(WakeSignal(
                        botId: botID, reason: "device:\(value.envelope.msgID)", at: now()))
                    if expected == Int64.max { break }
                    expected += 1
                    forced = pending.count > maxBufferedPerDevice
                    continue
                }
                guard let next = pending.keys.filter({ $0 > expected }).min(),
                      let nextValue = pending[next] else { break }
                let waitedMs = now() - nextValue.receivedAt
                guard forced || waitedMs >= gapSkipAfterMs else { break }
                let reason = forced ? "buffer-limit" : "timeout"
                try await recordGap(
                    deviceID: deviceID, epoch: epoch, fromSeq: expected, toSeq: next - 1,
                    reason: reason, transport: nextValue.transport)
                let skippedTo = next - 1
                setWatermark(deviceID: deviceID, epoch: epoch, seq: skippedTo)
                try await inbox.advanceDeviceCursor(
                    deviceID: deviceID, epoch: epoch, seq: skippedTo)
                expected = next
                forced = pending.count > maxBufferedPerDevice
            }
            if pending.isEmpty { buffered[deviceID]?.removeValue(forKey: epoch) }
        }
        if buffered[deviceID]?.isEmpty == true { buffered.removeValue(forKey: deviceID) }
        return released
    }

    private func setWatermark(deviceID: String, epoch: Int64, seq: Int64) {
        if let existing = watermarks[deviceID]?[epoch], existing >= seq { return }
        watermarks[deviceID, default: [:]][epoch] = seq
    }

    private func recordGap(deviceID: String, epoch: Int64, fromSeq: Int64, toSeq: Int64,
                           reason: String, transport: BotDeviceTransport) async throws {
        let sessionID = try await requireMainSession()
        let eventID = "device-gap:\(deviceID):\(epoch):\(fromSeq):\(toSeq)"
        let text = "设备 \(deviceID) 的消息缺口 seq \(fromSeq)–\(toSeq) 已跳过（\(reason)），后续消息继续交付。"
        let event = BotEvent(
            type: "ui.notice", eventId: eventID, time: now(),
            origin: .local(source: "device:\(transport.rawValue):\(deviceID)"),
            traceId: eventID,
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "device"),
            causationId: nil, correlationId: eventID,
            data: .object([
                "kind": .string("device.gap"),
                "tone": .string("warning"),
                "text": .string(text),
                "deviceID": .string(deviceID),
                "epoch": .number(Double(epoch)),
                "fromSeq": .number(Double(fromSeq)),
                "toSeq": .number(Double(toSeq)),
                "reason": .string(reason),
            ]))
        _ = try await store.append(event)
    }

    private func readyPendingItems() async throws -> [WakeInboxItem] {
        let pending = try await inbox.items().filter {
            $0.kind == "device-event" && $0.state == .pending
        }
        return pending.sorted {
            ($0.deviceID ?? "", $0.deviceEpoch ?? 0, $0.deviceSeq ?? 0, $0.id)
                < ($1.deviceID ?? "", $1.deviceEpoch ?? 0, $1.deviceSeq ?? 0, $1.id)
        }
    }
}
