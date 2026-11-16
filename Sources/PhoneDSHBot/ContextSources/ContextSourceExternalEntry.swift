// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Legal external entries into the App: an App-owned URL, an NSUserActivity,
/// a user-shared item, or a user paste. This is not a general URL/content
/// scanner: only declared schemes/activity types are accepted, query strings are
/// dropped from the observation, and paste is read only when the UI calls the
/// paste entry after a user action.
public final class ExternalEntrySource: BotContextSource, BotContextSourceStreaming,
                                        BotContextSourceRechecking, @unchecked Sendable {
    public let kind: BotContextSourceKind = .externalEntry
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private let allowedSchemes: Set<String>
    private let allowedActivityTypes: Set<String>
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?

    public init(allowedSchemes: Set<String> = ["phonedsh"],
                allowedActivityTypes: Set<String> = ["dev.phone-dsh.probe.context-entry"],
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowedActivityTypes = allowedActivityTypes
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization { .authorized }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock()
        activeRevision = permissionRevision
        self.emit = emit
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        activeRevision = nil
        emit = nil
        buffer.clear()
        lock.unlock()
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    @discardableResult
    public func accept(url: URL) throws -> BotContextObservation {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            throw BotContextSourceError.invalidRequest("URL scheme is not an App-owned entry")
        }
        let host = String((components.host ?? "").prefix(120))
        let path = String(components.path.prefix(300))
        // Query and fragment are deliberately discarded: OAuth/deep-link
        // parameters can contain one-shot secrets and are not context facts.
        let material = "\(scheme)://\(host)\(path)"
        let fingerprint = Self.sha256(material)
        let observation = try BotContextObservation(
            id: "external-url:\(fingerprint):\(now())",
            source: .externalEntry,
            kind: .externalURL,
            observedAt: now(),
            permissionRevision: try currentRevision(),
            sourceVersion: .known(.contentSHA256, value: "sha256:\(fingerprint)", observedAt: now()),
            uncertainty: BotContextUncertainty(
                level: .low, reason: "url-query-and-fragment-dropped"),
            delivery: .os,
            payload: .object([
                "scheme": .string(scheme),
                "host": .string(host),
                "path": .string(path),
            ]),
            dedupeKey: "external-url:\(fingerprint):\(bucket(now()))",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "url:\(fingerprint)"))
        return try deliver(observation)
    }

    @discardableResult
    public func accept(userActivity: NSUserActivity) throws -> BotContextObservation {
        let type = userActivity.activityType
        guard allowedActivityTypes.contains(type) else {
            throw BotContextSourceError.invalidRequest("activity type is not an App-owned entry")
        }
        var payload: [String: BotJSONValue] = [
            "activityType": .string(String(type.prefix(200))),
        ]
        if let host = userActivity.webpageURL?.host {
            payload["webpageHost"] = .string(String(host.prefix(120)))
        }
        let material = type + "\u{0}" + (userActivity.webpageURL?.host ?? "")
        let fingerprint = Self.sha256(material)
        let observation = try BotContextObservation(
            id: "external-activity:\(fingerprint):\(now())",
            source: .externalEntry,
            kind: .externalUserActivity,
            observedAt: now(),
            permissionRevision: try currentRevision(),
            sourceVersion: .known(.contentSHA256, value: "sha256:\(fingerprint)", observedAt: now()),
            uncertainty: BotContextUncertainty(
                level: .low, reason: "user-activity-userInfo-not-copied"),
            delivery: .os,
            payload: .object(payload),
            dedupeKey: "external-activity:\(fingerprint):\(bucket(now()))",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "activity:\(fingerprint)"))
        return try deliver(observation)
    }

    @discardableResult
    public func accept(sharedItem selection: BotContextUserSelection) throws -> BotContextObservation {
        let observation = try BotContextObservation(
            id: "external-share:\(selection.sha256):\(now())",
            source: .externalEntry,
            kind: .externalShareItem,
            observedAt: now(),
            permissionRevision: try currentRevision(),
            sourceVersion: .fileBytes("sha256:\(selection.sha256)", observedAt: now()),
            uncertainty: BotContextUncertainty(level: .low, completeness: .complete),
            delivery: .os,
            payload: .object([
                "itemKind": .string(selection.kind.rawValue),
                "name": .string(selection.name),
                "mimeType": .string(selection.mimeType),
                "byteCount": .number(Double(selection.byteCount)),
            ]),
            dedupeKey: "external-share:\(selection.sha256)",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "share:\(selection.sha256)"))
        return try deliver(observation)
    }

    /// The App calls this only from an explicit user paste action. There is no
    /// launch-time or background pasteboard read in this module.
    @discardableResult
    public func accept(pastedText: String) throws -> BotContextObservation {
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 20_000 else {
            throw BotContextSourceError.invalidRequest("pasted text must be 1...20000 scalars")
        }
        let fingerprint = Self.sha256(trimmed)
        let observation = try BotContextObservation(
            id: "external-paste:\(fingerprint):\(now())",
            source: .externalEntry,
            kind: .externalPaste,
            observedAt: now(),
            permissionRevision: try currentRevision(),
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .medium, reason: "user-pasted-text-has-no-provenance"),
            delivery: .os,
            payload: .object(["text": .string(trimmed)]),
            dedupeKey: "external-paste:\(fingerprint):\(bucket(now()))",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "paste:\(fingerprint)"))
        return try deliver(observation)
    }

    /// Real r5 recheck: an external entry is an immutable user action; there is
    /// no later provider for the same event. The file digest lives in
    /// `sourceVersion`, not in a model-visible body.
    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        guard (try? currentRevision()) == permissionRevision else {
            return .denied("revoked-generation")
        }
        return .notPerformed("external-entry-is-immutable")
    }

    private func currentRevision() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let activeRevision else {
            throw BotContextSourceError.revoked(.externalEntry)
        }
        return activeRevision
    }

    private func deliver(_ observation: BotContextObservation) throws -> BotContextObservation {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink, observation.permissionRevision == revision else {
            throw BotContextSourceError.revoked(.externalEntry)
        }
        buffer.append(observation)
        sink(observation)
        return observation
    }

    private func bucket(_ timestamp: Int64) -> Int64 { timestamp / 60_000 }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A simulator/debug-only driver that can inject a context event without touching
/// a real framework. It always stamps `.injected`; a caller cannot upgrade it to
/// `.os`. The registry registers it with `.injected` provenance and rejects any
/// observation that claims otherwise.
public final class BotContextInjectionDriver: BotContextSource, BotContextSourceStreaming,
                                              BotContextSourceRechecking, @unchecked Sendable {
    public let kind: BotContextSourceKind
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?
    private var recheckProbe: BotContextRecheckProbe = .notPerformed("injected-source")

    public init(kind: BotContextSourceKind,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.kind = kind
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization { .authorized }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock()
        activeRevision = permissionRevision
        self.emit = emit
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        activeRevision = nil
        emit = nil
        buffer.clear()
        lock.unlock()
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    /// Test/simulator control for the r5 state machine. The probe is explicit;
    /// the driver never pretends it queried a real OS source.
    public func setRecheckProbe(_ probe: BotContextRecheckProbe) {
        lock.lock()
        recheckProbe = probe
        lock.unlock()
    }

    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        lock.lock()
        let revision = activeRevision
        let probe = recheckProbe
        lock.unlock()
        guard revision == permissionRevision else { return .denied("revoked-generation") }
        return probe
    }

    /// Injects one event. The kind is chosen by the simulator script, never by a
    /// product rule in this module (no weekly-report/airport special case).
    @discardableResult
    public func inject(kind observationKind: BotContextObservationKind,
                       payload: BotJSONValue = .object([:]),
                       sourceVersion: BotContextSourceVersion? = nil,
                       uncertainty: BotContextUncertainty = BotContextUncertainty(
                        level: .medium, reason: "simulator-injected", completeness: .partial),
                       wakeRequested: Bool = true) throws -> BotContextObservation {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink else {
            throw BotContextSourceError.revoked(kind)
        }
        let stamp = now()
        let observation = try BotContextObservation(
            id: "injected:\(kind.rawValue):\(observationKind.rawValue):\(stamp)",
            source: kind,
            kind: observationKind,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: sourceVersion ?? .unversioned(),
            uncertainty: uncertainty,
            delivery: .injected,
            payload: payload,
            dedupeKey: "injected:\(kind.rawValue):\(observationKind.rawValue):\(stamp)",
            wakeRequested: wakeRequested,
            resource: try? BotContextResource(
                kind: .contextSource, key: "injected:\(kind.rawValue)"))
        buffer.append(observation)
        sink(observation)
        return observation
    }
}
