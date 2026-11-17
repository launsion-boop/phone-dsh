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
    /// Test-only adapter overrides; empty in production. Used by the lifecycle
    /// pause/resume test, not a permission bypass.
    public var sourceOverrides: [BotContextSourceKind: any BotContextSource]

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                consentStore: any BotContextSourceConsentPersisting = UserDefaultsBotContextSourceConsentStore(),
                audit: any BotContextAuditRecording = BotContextAuditLog(),
                eventLog: (any BotEventLog)? = nil,
                locationFences: [BotContextGeofenceSpec] = [],
                allowedExternalSchemes: Set<String> = ["phonedsh"],
                allowedActivityTypes: Set<String> = ["dev.phone-dsh.probe.context-entry"],
                injectedSources: Set<BotContextSourceKind> = [],
                sourceOverrides: [BotContextSourceKind: any BotContextSource] = [:]) {
        self.now = now
        self.consentStore = consentStore
        self.audit = audit
        self.eventLog = eventLog
        self.locationFences = locationFences
        self.allowedExternalSchemes = allowedExternalSchemes
        self.allowedActivityTypes = allowedActivityTypes
        self.injectedSources = injectedSources
        self.sourceOverrides = sourceOverrides
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
    /// Sendable snapshot of the real consent generations, for the decision
    /// context permission revision. It is sampled from the same ledger the
    /// registry gates reads with; a consent change therefore changes the
    /// revision even when no BotGrant was issued.
    public let consentRevision: @Sendable () async -> String

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
    private var confirmedGeofences: [BotContextGeofenceSpec]
    private var started = false
    private var lifecycleGeneration: UInt64 = 0
    private var stopTask: Task<Void, Never>?
    private var stopSequence: UInt64 = 0
    private var registrationTask: Task<Void, Error>?

    public init(dependencies: BotContextSourcesDependencies = BotContextSourcesDependencies()) {
        self.dependencies = dependencies
        let ledger = BotContextConsentLedger(store: dependencies.consentStore, now: dependencies.now)
        self.ledger = ledger
        self.consentRevision = {
            let states = await ledger.states()
            return states.map {
                "\($0.source.rawValue):\($0.permissionRevision):\($0.authorization.rawValue):\($0.osAuthorization?.rawValue ?? "-")"
            }.sorted().joined(separator: ",")
        }
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
            let storedFences = dependencies.locationFences.isEmpty
                ? BotContextSourcesGeofenceStore.load()
                : dependencies.locationFences
            location = LocationRegionSource(fences: storedFences, now: dependencies.now)
        }
        let power: PowerIdleSource? = injected.contains(.power)
            ? nil : PowerIdleSource(now: dependencies.now)
        if injected.contains(.power) {
            injections[.power] = BotContextInjectionDriver(kind: .power, now: dependencies.now)
        }

        self.confirmedGeofences = dependencies.locationFences.isEmpty
            ? BotContextSourcesGeofenceStore.load()
            : dependencies.locationFences
        self.injections = injections
        self.externalEntry = external
        self.selectedMedia = selectedMedia
        self.ownNotifications = ownNotifications
        self.contacts = contacts
        self.calendar = calendar
        self.location = location
        self.registrations = [
            (.calendar, calendar.map { $0 as any BotContextSource }, .os),
            (.contacts, contacts.map { $0 as any BotContextSource }, .os),
            (.selectedMedia, selectedMedia.map { $0 as any BotContextSource }, .os),
            (.locationFence, location.map { $0 as any BotContextSource }, .os),
            (.power, power.map { $0 as any BotContextSource }, .os),
            (.ownNotification, ownNotifications.map { $0 as any BotContextSource }, .os),
            (.externalEntry, external.map { $0 as any BotContextSource }, .os),
        ]
    }

    /// Loads the consent document, restores subscriptions and wires the wake
    /// relay. A monotonic lifecycle token serializes overlapping start/stop:
    /// a late old start can never mark the assembly started or restart adapters
    /// after a newer stop/start decision, and the latest start eventually wins.
    public func start(onWake: @escaping @Sendable (WakeSignal) -> Void) async throws {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        while let stopping = stopTask {
            await stopping.value
        }
        guard generation == lifecycleGeneration else { return }
        if started { return }
        try await ensureRegistered()
        guard generation == lifecycleGeneration else { return }
        _ = await ledger.load()
        guard generation == lifecycleGeneration else { return }
        // stopAll() clears adapters but not ledger subscriptions; restore only
        // this assembly's active subscriptions on the latest start.
        let snapshot = await ledger.snapshot()
        for (botID, sources) in snapshot.subscriptions {
            guard generation == lifecycleGeneration else { return }
            try? await registry.subscribe(botID: botID, sources: Array(sources))
        }
        guard generation == lifecycleGeneration else { return }
        for (kind, source, _) in registrations where source != nil {
            guard generation == lifecycleGeneration else { return }
            guard let source else { continue }
            let effective = dependencies.sourceOverrides[kind] ?? source
            let status = await effective.authorization()
            guard generation == lifecycleGeneration else { return }
            await registry.noteOSAuthorizationChange(source: kind, status: status)
        }
        guard generation == lifecycleGeneration else { return }
        await registry.setWakeHandler { [weak wakeRelay] wake in
            guard let wakeRelay else { return }
            Task { await wakeRelay.emit(wake) }
        }
        await wakeRelay.start(onSignal: onWake)
        guard generation == lifecycleGeneration else { return }
        started = true
    }

    private func ensureRegistered() async throws {
        if let existing = registrationTask {
            try await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let alreadyRegistered = Set(await self.registry.registeredSources())
            for (kind, source, provenance) in self.registrations
                where !alreadyRegistered.contains(kind) {
                do {
                    if let override = self.dependencies.sourceOverrides[kind] {
                        try await self.registry.register(override, provenance: provenance)
                    } else if let injection = self.injections[kind] {
                        try await self.registry.register(injection, provenance: .injected)
                    } else if let source {
                        try await self.registry.register(source, provenance: provenance)
                    } else {
                        throw BotContextSourceError.unsupported(
                            "\(kind.rawValue) has no adapter in this build")
                    }
                } catch {
                    // One unavailable native adapter must not hide the others
                    // from the settings page.
                    NSLog("BOT_CONTEXT_SOURCE_REGISTRATION_FAILED=%@ error=%@",
                          kind.rawValue, String(describing: error))
                }
            }
        }
        registrationTask = task
        do {
            try await task.value
        } catch {
            registrationTask = nil
            throw error
        }
    }

    public func stopAll() async {
        lifecycleGeneration &+= 1
        started = false
        let task = Task { [weak self] in
            guard let self else { return }
            await self.wakeRelay.stop()
            await self.registry.stopAll()
        }
        stopSequence &+= 1
        let sequence = stopSequence
        stopTask = task
        await task.value
        if stopSequence == sequence { stopTask = nil }
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

    /// Real G-1 r5 recheck for the requested sources. Used by the decision-time
    /// material/source panel; a revoked source returns refresh-denied without
    /// an adapter call.
    public func recheck(botID: String,
                        sources: [BotContextSourceKind] = []) async -> [BotContextRecheck] {
        await registry.recheck(botID: botID, sources: sources)
    }

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

    /// Per-Bot subscription state for the settings switch. It never means the
    /// OS/App source consent alone.
    public func isSubscribed(botID: String, source: BotContextSourceKind) async -> Bool {
        await registry.isSubscribed(botID: botID, source: source)
    }

    /// Turn off only this Bot's subscription; other Bots and the global
    /// consent/generation are untouched. Use `revoke(source:)` for a global
    /// permission revoke.
    public func unsubscribe(botID: String, source: BotContextSourceKind) async {
        do {
            try await registry.unsubscribe(botID: botID, sources: [source])
        } catch {
            // A settings switch is best-effort; `load()` re-reads the truth.
        }
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
        let state = await registry.authorization(for: source)
        #if DEBUG
        let registered = await registry.registeredSources()
        NSLog("BOT_CONTEXT_AUTH source=%@ started=%@ registered=%@ state=%@",
              source.rawValue, String(started), String(describing: registered),
              String(describing: state))
        #endif
        return state
    }

    /// Updates the user-confirmed fences. The caller supplies only confirmed
    /// places; no coordinate is persisted by this module.
    /// Single persistence owner read API for the settings UI. The value is the
    /// in-memory confirmed set loaded from/saved to the one product key.
    public var geofences: [BotContextGeofenceSpec] {
        confirmedGeofences
    }

    public func setGeofences(_ fences: [BotContextGeofenceSpec]) async throws {
        // Save the user's confirmed configuration first. Without Always/location
        // source started, updateFences rejects with .revoked and cannot register
        // OS regions; that must not discard the configuration. No region is
        // registered and no event is fabricated until the source is active.
        BotContextSourcesGeofenceStore.save(fences)
        confirmedGeofences = fences
        guard let location else { return }
        do {
            try await location.updateFences(fences)
        } catch BotContextSourceError.revoked(.locationFence) {
            // Saved, waiting for the user to enable the source/permission.
            return
        }
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

    /// G-1 r13 file baseline for a user-selected media/share observation. The
    /// caller passes the normalized VFS path/file id when it has one; the digest
    /// stays metadata and is never copied into a model-visible body.
    public func fileBaseline(for observation: BotContextObservation,
                             ownerBotID: String,
                             resourceKey: String? = nil) -> BotContextFileBaseline? {
        observation.fileBaseline(ownerBotID: ownerBotID, resourceKey: resourceKey)
    }

    /// Simulator/debug only. The driver stamps `delivery=injected`; the registry
    /// rejects it if it claims `os`.
    @discardableResult
    func inject(kind source: BotContextSourceKind,
                       observationKind: BotContextObservationKind,
                       payload: PhoneDSHBot.BotJSONValue = .object([:]),
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
