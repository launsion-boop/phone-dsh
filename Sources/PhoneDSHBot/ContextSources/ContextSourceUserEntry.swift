// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import UserNotifications

/// One item the user explicitly selected or shared into the App.
///
/// It carries metadata and a content fingerprint only. The bytes stay in the
/// user's selected file / the attachment import path; this source never copies
/// a whole library or puts file bytes into the model context.
public struct BotContextUserSelection: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case image
        case file
        case text
    }

    public var kind: Kind
    public var name: String
    public var mimeType: String
    public var byteCount: Int64
    public var sha256: String
    /// Optional bounded user-visible label; never a path credential.
    public var displayName: String?

    public init(kind: Kind, name: String, mimeType: String, byteCount: Int64,
                sha256: String, displayName: String? = nil) throws {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let cleanMime = String(mimeType.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let cleanHash = sha256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanMime.isEmpty else {
            throw BotContextSourceError.invalidRequest("selected item requires name and mime type")
        }
        guard cleanHash.count == 64, cleanHash.allSatisfy({ $0.isHexDigit }) else {
            throw BotContextSourceError.invalidRequest("selected item requires a SHA-256 fingerprint")
        }
        guard byteCount >= 0, byteCount <= BotAttachmentPolicy.maxBytes else {
            throw BotContextSourceError.invalidRequest("selected item is outside the attachment size limit")
        }
        self.kind = kind
        self.name = cleanName
        self.mimeType = cleanMime
        self.byteCount = byteCount
        self.sha256 = cleanHash
        self.displayName = displayName.map { String($0.prefix(120)) }
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// In-App user-selected media (PHPicker / document picker). No photo-library
/// permission is requested and no enumeration exists on this type.
public final class SelectedMediaSource: BotContextSource, BotContextSourceStreaming, @unchecked Sendable {
    public let kind: BotContextSourceKind = .selectedMedia
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
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

    /// Real r5 recheck: selected media is an immutable user entry; there is no
    /// later provider query for the same selection. The digest itself is in
    /// `sourceVersion` (sha256:...), never in a model-visible body.
    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        lock.lock()
        let revision = activeRevision
        lock.unlock()
        guard revision == permissionRevision else { return .denied("revoked-generation") }
        return .notPerformed("user-selected-item-is-immutable")
    }

    /// Called only after the user picked/shared one item. The returned value has
    /// no owner; the registry binds it. `delivery` is `.os` because the user
    /// acted through a real native picker, not a test driver.
    @discardableResult
    public func accept(_ selection: BotContextUserSelection) throws -> BotContextObservation {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink else {
            throw BotContextSourceError.revoked(.selectedMedia)
        }
        let observation = try BotContextObservation(
            id: "selected-media:\(selection.sha256):\(now())",
            source: .selectedMedia,
            kind: .mediaSelected,
            observedAt: now(),
            permissionRevision: revision,
            sourceVersion: .known(.contentSHA256, value: "sha256:\(selection.sha256)", observedAt: now()),
            uncertainty: BotContextUncertainty(level: .low, completeness: .complete),
            delivery: .os,
            payload: .object([
                "itemKind": .string(selection.kind.rawValue),
                "name": .string(selection.name),
                "mimeType": .string(selection.mimeType),
                "byteCount": .number(Double(selection.byteCount)),
            ]),
            dedupeKey: "selected-media:\(selection.sha256)",
            wakeRequested: true)
        buffer.append(observation)
        sink(observation)
        return observation
    }
}

/// The App's own notification responses and delivered items. iOS exposes no API
/// for other apps' notifications, so this source only ever sees notifications
/// this App scheduled.
public final class OwnNotificationSource: BotContextSource, BotContextSourceStreaming,
                                          BotContextSourceRequesting, BotContextSourceDiagnosing,
                                          BotContextSourceRechecking, @unchecked Sendable {
    public let kind: BotContextSourceKind = .ownNotification
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current(),
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.center = center
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization {
        do {
            let settings = await center.notificationSettings()
            return Self.map(settings.authorizationStatus)
        } catch {
            return .notDetermined
        }
    }

    public func authorizationDiagnostic() async -> String? {
        let status = await authorization()
        return BotContextOSStatusWord.word(status)
    }

    public func requestAuthorization() async -> BotSourceAuthorization {
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        if granted { return .authorized }
        return await authorization()
    }

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

    /// The App's existing UNUserNotificationCenter delegate calls this for a
    /// real user response. It does not read other Apps' notifications.
    @discardableResult
    public func handleResponse(_ response: UNNotificationResponse) throws -> BotContextObservation {
        let request = response.notification.request
        let deepLink = (request.content.userInfo["deepLink"] as? String)
            .flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        var payload: [String: BotJSONValue] = [
            "actionIdentifier": .string(String(response.actionIdentifier.prefix(120))),
            "categoryIdentifier": .string(String(request.content.categoryIdentifier.prefix(120))),
            "requestIdentifier": .string(String(request.identifier.prefix(200))),
        ]
        if let deepLink, BotContextSecretScanner.containsSecret(deepLink) == false {
            payload["deepLink"] = .string(deepLink)
        }
        let observation = try BotContextObservation(
            id: "own-notification:\(request.identifier):\(now())",
            source: .ownNotification,
            kind: .ownNotificationResponse,
            observedAt: now(),
            permissionRevision: try currentRevision(),
            sourceVersion: .known(.providerVersion,
                                  value: "rev:\(String(request.identifier.prefix(200)))", observedAt: now()),
            uncertainty: BotContextUncertainty(
                level: .low, reason: "notification-response-time-is-not-the-original-event-time"),
            delivery: .os,
            payload: .object(payload),
            dedupeKey: "own-notification:\(request.identifier):\(response.actionIdentifier)",
            wakeRequested: true)
        return try deliver(observation)
    }

    /// Reads only this App's delivered notifications; callers use it when the
    /// user opens the notification surface. The body is deliberately not copied.
    public func deliveredObservations(limit: Int = 10) async -> [BotContextObservation] {
        let notifications = await withCheckedContinuation { (continuation: CheckedContinuation<[UNNotification], Never>) in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
        var result: [BotContextObservation] = []
        for notification in notifications.prefix(min(max(1, limit), 20)) {
            let request = notification.request
            guard let observation = try? BotContextObservation(
                id: "own-notification-delivered:\(request.identifier)",
                source: .ownNotification,
                kind: .ownNotificationDelivered,
                observedAt: now(),
                permissionRevision: try currentRevision(),
                sourceVersion: .known(.providerVersion,
                                      value: "rev:\(String(request.identifier.prefix(200)))", observedAt: now()),
                uncertainty: BotContextUncertainty(
                    level: .low, reason: "delivered-notification-list-is-a-current-snapshot"),
                delivery: .os,
                payload: .object([
                    "requestIdentifier": .string(String(request.identifier.prefix(200))),
                    "categoryIdentifier": .string(String(request.content.categoryIdentifier.prefix(120))),
                ]),
                dedupeKey: "own-notification-delivered:\(request.identifier)",
                wakeRequested: false) else { continue }
            result.append(observation)
        }
        return result
    }

    /// Real r5 recheck of the notification permission. A past response is
    /// immutable, so the producer cannot reconstruct a newer version; it says
    /// refresh-not-performed instead of current.
    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        guard (try? currentRevision()) == permissionRevision else {
            return .denied("revoked-generation")
        }
        guard (await authorization()).allowsReading else {
            return .denied("notifications-not-authorized")
        }
        return .notPerformed("notification-response-is-immutable")
    }

    private func currentRevision() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let activeRevision else {
            throw BotContextSourceError.revoked(.ownNotification)
        }
        return activeRevision
    }

    private func deliver(_ observation: BotContextObservation) throws -> BotContextObservation {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink, observation.permissionRevision == revision else {
            throw BotContextSourceError.revoked(.ownNotification)
        }
        buffer.append(observation)
        sink(observation)
        return observation
    }

    private static func map(_ status: UNAuthorizationStatus) -> BotSourceAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
#if os(iOS)
        case .ephemeral: return .authorized
#endif
        case .provisional: return .limited
        @unknown default: return .notDetermined
        }
    }
}
