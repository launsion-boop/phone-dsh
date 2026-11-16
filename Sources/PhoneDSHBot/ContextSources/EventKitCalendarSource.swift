// SPDX-License-Identifier: MIT

#if canImport(EventKit)
import CryptoKit
import EventKit
import Foundation

/// EventKit calendar source. It observes the authorized calendars only, emits a
/// bounded upcoming snapshot and a change signal, and never writes to the
/// calendar (calendar creation remains a separate, approval-gated tool).
public final class EventKitCalendarSource: BotContextSource, BotContextSourceStreaming,
                                           BotContextSourceRequesting, BotContextSourceDiagnosing,
                                           BotContextSourceRechecking, @unchecked Sendable {
    public let kind: BotContextSourceKind = .calendar
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private let lookahead: TimeInterval
    private let maximumEvents: Int
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?

    public init(lookahead: TimeInterval = 7 * 24 * 60 * 60,
                maximumEvents: Int = 50,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.lookahead = max(60, lookahead)
        self.maximumEvents = min(max(1, maximumEvents), 100)
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    public func authorizationDiagnostic() async -> String? {
        "\(EKEventStore.authorizationStatus(for: .event).rawValue)"
    }

    public func requestAuthorization() async -> BotSourceAuthorization {
        let current = Self.map(EKEventStore.authorizationStatus(for: .event))
        // Already authorized (or denied/restricted) needs no second TCC prompt.
        // Requesting again while authorized is invalid on some OS/simulator
        // builds and used to leave App consent unset even though the OS grant
        // existed. Only notDetermined (or a write-only upgrade) may prompt.
        switch current {
        case .authorized, .denied, .restricted, .revoked:
            return current
        case .notDetermined, .limited:
            break
        }
        let store = EKEventStore()
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        guard EKEventStore.authorizationStatus(for: .event).allowsEvents else {
            throw BotContextSourceError.unsupported("calendar access is not authorized")
        }
        let store = EKEventStore()
        lock.lock()
        self.store = store
        activeRevision = permissionRevision
        self.emit = emit
        lock.unlock()
        let added = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
                self?.handleStoreChanged()
            }
        lock.lock()
        observer = added
        lock.unlock()
        emitUpcomingSnapshot(reason: "start")
    }

    public func stop() async {
        lock.lock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        store = nil
        activeRevision = nil
        emit = nil
        buffer.clear()
        lock.unlock()
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    private func handleStoreChanged() {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink else { return }
        let stamp = now()
        // EKEventStoreChanged says "something changed"; iOS does not name the
        // changed event. The observation must say that rather than inventing
        // which event or contact changed.
        if let observation = try? BotContextObservation(
            id: "calendar:changed:\(stamp)",
            source: .calendar,
            kind: .calendarChanged,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .high,
                reason: "eventkit-change-notification-cannot-name-changed-events",
                completeness: .partial),
            delivery: .os,
            payload: .object(["changed": .bool(true)]),
            dedupeKey: "calendar:changed:\(stamp / 60_000)",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "calendar:changed")) {
            buffer.append(observation)
            sink(observation)
        }
        emitUpcomingSnapshot(reason: "change")
    }

    private func emitUpcomingSnapshot(reason: String) {
        lock.lock()
        guard let store, let revision = activeRevision, let sink = emit else {
            lock.unlock()
            return
        }
        let start = Date()
        let end = start.addingTimeInterval(lookahead)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        lock.unlock()

        let page = events.prefix(maximumEvents)
        let items = page.map(Self.eventPayload)
        let stamp = now()
        let digest = Self.digest(items)
        let completeness: BotContextCompleteness = events.count > maximumEvents ? .partial : .complete
        guard let observation = try? BotContextObservation(
            id: "calendar:upcoming:\(stamp):\(items.count)",
            source: .calendar,
            kind: .calendarUpcoming,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .known(.contentSHA256, value: "sha256:\(digest)", observedAt: stamp),
            uncertainty: BotContextUncertainty(
                level: .low,
                reason: "eventkit-sync-recurrence-and-window",
                completeness: completeness),
            delivery: .os,
            payload: .object([
                "windowStart": .string(Self.iso8601(start)),
                "windowEnd": .string(Self.iso8601(end)),
                "count": .number(Double(events.count)),
                "events": .array(items),
                "reason": .string(reason),
            ]),
            dedupeKey: "calendar:upcoming:\(stamp / 3_600_000):\(items.count)",
            wakeRequested: false,
            resource: try? BotContextResource(
                kind: .contextSource, key: "calendar:upcoming")) else { return }
        buffer.append(observation)
        sink(observation)
    }

    private static func map(_ status: EKAuthorizationStatus) -> BotSourceAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .limited
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Real r5 recheck: query EventKit again and hash the same bounded event
    /// fields. No new observation is emitted here; the caller gets the current
    /// revision and decides current/changed/unknown.
    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        lock.lock()
        let revision = activeRevision
        let store = store
        lock.unlock()
        guard revision == permissionRevision else { return .denied("revoked-generation") }
        guard EKEventStore.authorizationStatus(for: .event).allowsEvents else {
            return .denied("calendar-not-authorized")
        }
        guard let store else { return .notPerformed("calendar-adapter-not-started") }
        let start = Date()
        let end = start.addingTimeInterval(lookahead)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let items = events.prefix(maximumEvents).map(Self.eventPayload)
        let digest = Self.digest(items)
        return .version(.known(.contentSHA256, value: "sha256:\(digest)", observedAt: now()))
    }

    private static func eventPayload(_ event: EKEvent) -> BotJSONValue {
        var entry: [String: BotJSONValue] = [
            "id": .string(String(event.eventIdentifier.prefix(200))),
            "title": .string(String((event.title ?? "").prefix(200))),
            "start": .string(iso8601(event.startDate)),
            "end": .string(iso8601(event.endDate)),
            "allDay": .bool(event.isAllDay),
            "calendar": .string(String(event.calendar.title.prefix(120))),
        ]
        if let modified = event.lastModifiedDate {
            entry["version"] = .object([
                "basis": .string("last-modified"),
                "value": .string("last-modified:\(Int64(modified.timeIntervalSince1970 * 1_000))"),
            ])
        } else {
            entry["version"] = .object(["reason": .string("source-unversioned")])
        }
        if let location = event.location, !location.isEmpty {
            entry["location"] = .string(String(location.prefix(200)))
        }
        return .object(entry)
    }

    private static func digest(_ items: [BotJSONValue]) -> String {
        let value = BotJSONValue.object(["events": .array(items)])
        guard let data = try? value.encoded() else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension EKAuthorizationStatus {
    var allowsEvents: Bool {
        self == .fullAccess || self == .authorized
    }
}
#endif
