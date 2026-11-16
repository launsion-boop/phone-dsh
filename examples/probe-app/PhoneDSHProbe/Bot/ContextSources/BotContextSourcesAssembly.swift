// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhoneDSHBot
import UserNotifications
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The App-side dependency bundle C injects into the production composition.
///
/// `consentStore` is a port. The durable UserDefaults/file store is added only
/// after G-3 freezes the key/version; until then the composition can pass the
/// in-memory store and must not claim restart persistence.
public struct BotContextSourcesDependencies {
    public var now: @Sendable () -> Int64
    public var consentStore: any BotContextSourceConsentPersisting
    public var audit: any BotContextAuditRecording
    /// The host event log (`SQLiteDomainStore`) for the two frozen durable
    /// context event types. Production must pass it; nil is only for previews.
    public var eventLog: (any BotEventLog)?
    public var locationFences: [BotContextGeofenceSpec]
    public var allowedExternalSchemes: Set<String>
    public var allowedActivityTypes: Set<String>
    /// Simulator/debug only: register an injected driver instead of the real
    /// adapter for these sources. Empty in production.
    public var injectedSources: Set<BotContextSourceKind>

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                consentStore: any BotContextSourceConsentPersisting = UserDefaultsBotContextSourceConsentStore(),
                audit: any BotContextAuditRecording = BotContextAuditLog(),
                eventLog: (any BotEventLog)? = nil,
                locationFences: [BotContextGeofenceSpec] = [],
                allowedExternalSchemes: Set<String> = ["phonedsh"],
                allowedActivityTypes: Set<String> = ["dev.phone-dsh.probe.context-entry"],
                injectedSources: Set<BotContextSourceKind> = []) {
        self.now = now
        self.consentStore = consentStore
        self.audit = audit
        self.eventLog = eventLog
        self.locationFences = locationFences
        self.allowedExternalSchemes = allowedExternalSchemes
        self.allowedActivityTypes = allowedActivityTypes
        self.injectedSources = injectedSources
    }
}

/// The single App-facing factory for native context sources.
///
/// C owns the actual construction/call sites in `BotRuntimeComposition`; this
/// type exists so there is exactly one place that registers real adapters,
/// binds the wake relay, and exposes the consent/revoke/read methods. It never
/// opens a turn or posts a notification.
@MainActor
public final class BotContextSourcesAssembly {
    public let registry: BotContextSourceRegistry
    public let wakeRelay: BotContextWakeRelay

    private let ledger: BotContextConsentLedger
    private let dependencies: BotContextSourcesDependencies
    private let externalEntry: ExternalEntrySource?
    private let selectedMedia: SelectedMediaSource?
    private let ownNotifications: OwnNotificationSource?
    private let contacts: ContactsSource?
    private let calendar: EventKitCalendarSource?
    private let location: LocationRegionSource?
    private let injections: [BotContextSourceKind: BotContextInjectionDriver]
    private let registrations: [(BotContextSourceKind, (any BotContextSource)?, BotContextObservationDelivery)]
    private var started = false

    public init(dependencies: BotContextSourcesDependencies = BotContextSourcesDependencies()) {
        self.dependencies = dependencies
        let ledger = BotContextConsentLedger(store: dependencies.consentStore, now: dependencies.now)
        self.ledger = ledger
        let durableWriter = dependencies.eventLog.map {
            BotContextDurableWriter(eventLog: $0, now: dependencies.now)
        }
        self.registry = BotContextSourceRegistry(
            ledger: ledger, audit: dependencies.audit,
            observationRecorder: durableWriter, consentRecorder: durableWriter,
            now: dependencies.now)
        self.wakeRelay = BotContextWakeRelay()

        var injections: [BotContextSourceKind: BotContextInjectionDriver] = [:]
        var external: ExternalEntrySource?
        var selectedMedia: SelectedMediaSource?
        var ownNotifications: OwnNotificationSource?
        var contacts: ContactsSource?
        var calendar: EventKitCalendarSource?
        var location: LocationRegionSource?

        let injected = dependencies.injectedSources
        if injected.contains(.externalEntry) {
            injections[.externalEntry] = BotContextInjectionDriver(kind: .externalEntry, now: dependencies.now)
        } else {
            external = ExternalEntrySource(
                allowedSchemes: dependencies.allowedExternalSchemes,
                allowedActivityTypes: dependencies.allowedActivityTypes,
                now: dependencies.now)
        }
        if injected.contains(.selectedMedia) {
            injections[.selectedMedia] = BotContextInjectionDriver(kind: .selectedMedia, now: dependencies.now)
        } else {
            selectedMedia = SelectedMediaSource(now: dependencies.now)
        }
        if injected.contains(.ownNotification) {
            injections[.ownNotification] = BotContextInjectionDriver(kind: .ownNotification, now: dependencies.now)
        } else if let center = Self.notificationCenterIfAvailable() {
            ownNotifications = OwnNotificationSource(center: center, now: dependencies.now)
        }
        if injected.contains(.contacts) {
            injections[.contacts] = BotContextInjectionDriver(kind: .contacts, now: dependencies.now)
        } else {
            contacts = ContactsSource(now: dependencies.now)
        }
        if injected.contains(.calendar) {
            injections[.calendar] = BotContextInjectionDriver(kind: .calendar, now: dependencies.now)
        } else {
            calendar = EventKitCalendarSource(now: dependencies.now)
        }
        if injected.contains(.locationFence) {
            injections[.locationFence] = BotContextInjectionDriver(kind: .locationFence, now: dependencies.now)
        } else {
            location = LocationRegionSource(fences: dependencies.locationFences, now: dependencies.now)
        }
        let power: PowerIdleSource? = injected.contains(.power)
            ? nil : PowerIdleSource(now: dependencies.now)
        if injected.contains(.power) {
            injections[.power] = BotContextInjectionDriver(kind: .power, now: dependencies.now)
        }

        self.injections = injections
        self.externalEntry = external
        self.selectedMedia = selectedMedia
        self.ownNotifications = ownNotifications
        self.contacts = contacts
        self.calendar = calendar
        self.location = location
        self.registrations = [
            (.calendar, calendar as (any BotContextSource)?, .os),
            (.contacts, contacts as (any BotContextSource)?, .os),
            (.selectedMedia, selectedMedia as (any BotContextSource)?, .os),
            (.locationFence, location as (any BotContextSource)?, .os),
            (.power, power as (any BotContextSource)?, .os),
            (.ownNotification, ownNotifications as (any BotContextSource)?, .os),
            (.externalEntry, external as (any BotContextSource)?, .os),
        ]
    }

    /// Loads the consent document and wires the wake relay. C calls this once
    /// after the production composition is ready.
    public func start(onWake: @escaping @Sendable (WakeSignal) -> Void) async throws {
        guard !started else { return }
        let alreadyRegistered = Set(await registry.registeredSources())
        for (kind, source, provenance) in registrations where !alreadyRegistered.contains(kind) {
            if let injection = injections[kind] {
                try await registry.register(injection, provenance: .injected)
            } else if let source {
                try await registry.register(source, provenance: provenance)
            } else {
                throw BotContextSourceError.unsupported("\(kind.rawValue) has no adapter in this build")
            }
        }
        _ = await ledger.load()
        for (kind, source, _) in registrations where source != nil {
            guard let source else { continue }
            let status = await source.authorization()
            await registry.noteOSAuthorizationChange(source: kind, status: status)
        }
        await registry.setWakeHandler { [weak wakeRelay] wake in
            guard let wakeRelay else { return }
            Task { await wakeRelay.emit(wake) }
        }
        await wakeRelay.start(onSignal: onWake)
        started = true
    }

    public func stopAll() async {
        started = false
        await wakeRelay.stop()
        await registry.stopAll()
    }

    /// UI/composition read path: never throws. An unstarted assembly, an
    /// unauthorized/revoked source or a missing subscription returns an empty
    /// list with a stable reason instead of leaking an error string or old
    /// content.
    public func readObservations(for botID: String, since: Int64? = nil,
                                 sources: [BotContextSourceKind] = []) async -> BotContextObservationRead {
        guard started else {
            return BotContextObservationRead(
                status: .notStarted, reason: BotContextObservationReadReason.assemblyNotStarted)
        }
        do {
            let observations = try await registry.observations(
                for: botID, since: since, sources: sources)
            return BotContextObservationRead(
                status: .ok,
                reason: observations.isEmpty
                    ? BotContextObservationReadReason.noObservations
                    : "ok",
                observations: observations)
        } catch let error as BotContextSourceError {
            switch error {
            case .notAuthorized:
                return BotContextObservationRead(
                    status: .notAuthorized,
                    reason: BotContextObservationReadReason.sourceNotAuthorized)
            case .revoked:
                return BotContextObservationRead(
                    status: .revoked,
                    reason: BotContextObservationReadReason.sourceRevoked)
            case .notRegistered:
                return BotContextObservationRead(
                    status: .unavailable,
                    reason: BotContextObservationReadReason.sourceUnavailable)
            default:
                return BotContextObservationRead(
                    status: .unavailable,
                    reason: BotContextObservationReadReason.readFailed)
            }
        } catch {
            return BotContextObservationRead(
                status: .unavailable,
                reason: BotContextObservationReadReason.readFailed)
        }
    }

    public func isStarted() -> Bool { started }

    /// Frozen read view for the source panel/decision material. It never
    /// returns a payload; active items carry a record ref instead.
    public func observationView(for botID: String, since: Int64? = nil,
                                sources: [BotContextSourceKind] = []) async -> BotContextObservationView {
        await registry.observationView(for: botID, since: since, sources: sources)
    }

    /// Mirrors Apple authorization changes (Settings, system prompt, Focus) into
    /// the consent ledger. C calls this on App foreground / after returning from
    /// Settings. An OS denial revokes and stops the adapter; an OS re-grant never
    /// resurrects a source the user explicitly revoked.
    public func refreshOSAuthorizations() async {
        for (kind, source, _) in registrations {
            guard let source else { continue }
            let status = await source.authorization()
            await registry.noteOSAuthorizationChange(source: kind, status: status)
        }
    }

    @discardableResult
    public func requestConsent(source: BotContextSourceKind,
                               botID: String) async throws -> BotSourceAuthorizationState {
        try await registry.requestConsent(source: source, botID: botID)
    }

    public func revoke(source: BotContextSourceKind, reason: String = "user-revoked") async {
        await registry.revoke(source: source, by: .user, reason: reason)
    }

    public func subscribe(botID: String, sources: [BotContextSourceKind]) async throws {
        try await registry.subscribe(botID: botID, sources: sources)
    }

    public func observations(for botID: String, since: Int64? = nil,
                             sources: [BotContextSourceKind] = []) async throws -> [BotContextObservation] {
        try await registry.observations(for: botID, since: since, sources: sources)
    }

    public func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
        await registry.authorization(for: source)
    }

    /// Updates the user-confirmed fences. The caller supplies only confirmed
    /// places; no coordinate is persisted by this module.
    public func setGeofences(_ fences: [BotContextGeofenceSpec]) async throws {
        guard let location else {
            throw BotContextSourceError.unsupported("the location adapter is not registered")
        }
        try await location.updateFences(fences)
    }

    // MARK: - Legal external entries (C wires these call sites)

    @discardableResult
    public func handleOpenURL(_ url: URL) async -> Bool {
        guard let externalEntry else { return false }
        do {
            _ = try externalEntry.accept(url: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func handleUserActivity(_ activity: NSUserActivity) async -> Bool {
        guard let externalEntry else { return false }
        do {
            _ = try externalEntry.accept(userActivity: activity)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func handleNotificationResponse(_ response: UNNotificationResponse) async -> Bool {
        guard let ownNotifications else { return false }
        do {
            _ = try ownNotifications.handleResponse(response)
            return true
        } catch {
            return false
        }
    }

    /// Called only from an explicit user paste action. This method is the only
    /// place in the module that reads the pasteboard.
    @discardableResult
    public func handleUserPaste() async -> Bool {
#if canImport(UIKit)
        guard let externalEntry, let text = UIPasteboard.general.string else { return false }
        do {
            _ = try externalEntry.accept(pastedText: text)
            return true
        } catch {
            return false
        }
#else
        return false
#endif
    }

    @discardableResult
    public func handlePastedText(_ text: String) async -> Bool {
        guard let externalEntry else { return false }
        do {
            _ = try externalEntry.accept(pastedText: text)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func acceptSelectedFile(botID: String, at url: URL,
                                   displayName: String? = nil) async throws -> BotContextObservation {
        guard await registry.authorization(for: .selectedMedia)?.authorization.allowsReading == true,
              let selectedMedia else {
            throw BotContextSourceError.notAuthorized(.selectedMedia, permissionRevision: 0)
        }
        // The direct adapter call must still be inside a live Bot subscription;
        // the check does not consume a buffered observation.
        guard await registry.isSubscribed(botID: botID, source: .selectedMedia) else {
            throw BotContextSourceError.notAuthorized(.selectedMedia, permissionRevision: 0)
        }
        let (size, fingerprint) = try Self.fingerprint(fileAt: url)
        let selection = try BotContextUserSelection(
            kind: Self.isImage(url: url) ? .image : .file,
            name: url.lastPathComponent,
            mimeType: Self.mimeType(for: url),
            byteCount: size,
            sha256: fingerprint,
            displayName: displayName)
        return try selectedMedia.accept(selection)
    }

    @discardableResult
    public func acceptSharedItem(botID: String,
                                 name: String,
                                 mimeType: String,
                                 byteCount: Int64,
                                 sha256: String) async throws -> BotContextObservation {
        guard await registry.authorization(for: .externalEntry)?.authorization.allowsReading == true,
              let externalEntry else {
            throw BotContextSourceError.notAuthorized(.externalEntry, permissionRevision: 0)
        }
        guard await registry.isSubscribed(botID: botID, source: .externalEntry) else {
            throw BotContextSourceError.notAuthorized(.externalEntry, permissionRevision: 0)
        }
        let selection = try BotContextUserSelection(
            kind: mimeType.hasPrefix("image/") ? .image : .file,
            name: name, mimeType: mimeType, byteCount: byteCount, sha256: sha256)
        return try externalEntry.accept(sharedItem: selection)
    }

    @discardableResult
    public func readContacts(botID: String, query: String,
                             limit: Int = 20) async throws -> BotContextObservation {
        try await registry.readContacts(botID: botID, query: query, limit: limit)
    }

    /// Simulator/debug only. The driver stamps `delivery=injected`; the registry
    /// rejects it if it claims `os`.
    @discardableResult
    public func inject(kind source: BotContextSourceKind,
                       observationKind: BotContextObservationKind,
                       payload: BotJSONValue = .object([:]),
                       sourceVersion: BotContextSourceVersion? = nil,
                       uncertainty: BotContextUncertainty = BotContextUncertainty(
                        level: .medium, reason: "simulator-injected", completeness: .partial),
                       wakeRequested: Bool = true) async throws -> BotContextObservation {
        guard let driver = injections[source] else {
            throw BotContextSourceError.unsupported("\(source.rawValue) is not an injected source")
        }
        return try driver.inject(
            kind: observationKind, payload: payload, sourceVersion: sourceVersion,
            uncertainty: uncertainty, wakeRequested: wakeRequested)
    }

    // MARK: - Helpers

    private static func notificationCenterIfAvailable() -> UNUserNotificationCenter? {
        // A hostless macOS test process has no application bundle; constructing
        // the center there crashes. The iOS App always has a bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    private static func fingerprint(fileAt url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= BotAttachmentPolicy.maxBytes else {
                throw BotContextSourceError.invalidRequest("selected file exceeds the attachment size limit")
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (total, digest)
    }

    private static func isImage(url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased())
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
