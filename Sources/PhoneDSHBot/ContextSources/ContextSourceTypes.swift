// SPDX-License-Identifier: MIT

import Foundation

/// The independent, user-authorizable native context sources this module owns.
///
/// The set is closed by `spec/bot/v2/context-sources.md` (G-3A). A new source is
/// a contract change, not an extra enum case added by a feature branch.
public enum BotContextSourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case calendar
    case contacts
    case selectedMedia = "selected-media"
    case locationFence = "location-fence"
    case power
    case ownNotification = "own-notification"
    case externalEntry = "external-entry"

    public var requiresOSPermission: Bool {
        switch self {
        case .calendar, .contacts, .locationFence, .ownNotification:
            return true
        case .selectedMedia, .power, .externalEntry:
            return false
        }
    }
}

/// Effective authorization of one source.
public enum BotSourceAuthorization: String, Codable, Sendable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case limited
    case revoked

    public var allowsReading: Bool { self == .authorized || self == .limited }
    public var needsOSRequest: Bool { self == .notDetermined }

    /// The five states the frozen consent document can store.
    public var isConsentState: Bool {
        switch self {
        case .authorized, .limited, .denied, .revoked, .notDetermined: return true
        case .restricted: return false
        }
    }
}

/// Who changed consent. The frozen schema is `user|system|os`.
public enum BotSourceAuthorizationActor: String, Codable, Sendable {
    case user
    case system
    case os
}

/// One source's consent plus the generation every observation/read must carry.
public struct BotSourceAuthorizationState: Codable, Sendable, Equatable {
    public var source: BotContextSourceKind
    public var authorization: BotSourceAuthorization
    public var permissionRevision: Int
    public var updatedAt: Int64
    public var updatedBy: BotSourceAuthorizationActor
    public var osAuthorization: BotSourceAuthorization?
    public var detail: String?
    public var ownerBotID: String?

    public init(source: BotContextSourceKind,
                authorization: BotSourceAuthorization,
                permissionRevision: Int,
                updatedAt: Int64,
                updatedBy: BotSourceAuthorizationActor,
                osAuthorization: BotSourceAuthorization? = nil,
                detail: String? = nil,
                ownerBotID: String? = nil) {
        self.source = source
        self.authorization = authorization
        self.permissionRevision = max(0, permissionRevision)
        self.updatedAt = max(0, updatedAt)
        self.updatedBy = updatedBy
        self.osAuthorization = osAuthorization
        self.detail = detail.map { String($0.prefix(120)) }
        self.ownerBotID = ownerBotID.map { String($0.prefix(128)) }
    }

    public var generation: Int { permissionRevision }
}

/// Native observation kinds are an open string. Unknown values are retained and
/// marked unknown; they are never guessed into a known semantic.
public struct BotContextObservationKind: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = String(rawValue.prefix(80))
    }

    public init(_ rawValue: String) { self.init(rawValue: rawValue) }

    public var isKnown: Bool { Self.known.contains(self) }
    public var isValidFormat: Bool {
        rawValue.range(
            of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#,
            options: .regularExpression) != nil
    }

    public static let calendarUpcoming = BotContextObservationKind("calendar.upcoming")
    public static let calendarChanged = BotContextObservationKind("calendar.changed")
    public static let contactsChanged = BotContextObservationKind("contacts.changed")
    public static let mediaSelected = BotContextObservationKind("media.selected")
    public static let locationEntered = BotContextObservationKind("location.entered")
    public static let locationExited = BotContextObservationKind("location.exited")
    public static let locationFailed = BotContextObservationKind("location.failed")
    public static let powerChargingStarted = BotContextObservationKind("power.charging_started")
    public static let powerChargingStopped = BotContextObservationKind("power.charging_stopped")
    public static let powerLowPowerEnabled = BotContextObservationKind("power.low_power_enabled")
    public static let powerLowPowerDisabled = BotContextObservationKind("power.low_power_disabled")
    public static let appForeground = BotContextObservationKind("app.foreground")
    public static let appBackground = BotContextObservationKind("app.background")
    public static let ownNotificationResponse = BotContextObservationKind("own-notification.response")
    public static let ownNotificationDelivered = BotContextObservationKind("own-notification.delivered")
    public static let externalURL = BotContextObservationKind("external.url")
    public static let externalUserActivity = BotContextObservationKind("external.user-activity")
    public static let externalShareItem = BotContextObservationKind("external.share-item")
    public static let externalPaste = BotContextObservationKind("external.paste")

    public static let known: Set<BotContextObservationKind> = [
        .calendarUpcoming, .calendarChanged, .contactsChanged, .mediaSelected,
        .locationEntered, .locationExited, .locationFailed,
        .powerChargingStarted, .powerChargingStopped,
        .powerLowPowerEnabled, .powerLowPowerDisabled,
        .appForeground, .appBackground,
        .ownNotificationResponse, .ownNotificationDelivered,
        .externalURL, .externalUserActivity, .externalShareItem, .externalPaste,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty, value.unicodeScalars.count <= 80,
              value.range(of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#,
                          options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "context observation kind must match the frozen pattern")
        }
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Frozen source-version basis. Native sources map their real revision to one of
/// these; a source with no revision says why instead of sending a bare null.
public enum BotContextSourceVersionBasis: String, Codable, Sendable, CaseIterable {
    case contentSHA256 = "content-sha256"
    case etag
    case lastModified = "last-modified"
    case providerVersion = "provider-version"
}

public enum BotContextSourceVersionUnknownReason: String, Codable, Sendable, CaseIterable {
    case recordUnresolved = "record-unresolved"
    case recordErased = "record-erased"
    case recordWithoutContent = "record-without-content"
    case sourceUnversioned = "source-unversioned"
    case invalidReference = "invalid-reference"
}

public enum BotContextSourceVersion: Codable, Sendable, Equatable {
    case known(basis: BotContextSourceVersionBasis, value: String,
               observedAt: Int64?, basisRef: String?)
    case unknown(reason: BotContextSourceVersionUnknownReason,
                 observedAt: Int64?, basisRef: String?)

    public var isKnown: Bool { if case .known = self { return true }; return false }

    public static func known(_ basis: BotContextSourceVersionBasis, value: String,
                             observedAt: Int64? = nil) -> BotContextSourceVersion {
        .known(basis: basis, value: value, observedAt: observedAt, basisRef: nil)
    }

    public static func unversioned(_ reason: BotContextSourceVersionUnknownReason = .sourceUnversioned)
        -> BotContextSourceVersion {
        .unknown(reason: reason, observedAt: nil, basisRef: nil)
    }

    public var jsonValue: BotJSONValue {
        switch self {
        case .known(let basis, let value, let observedAt, let basisRef):
            var object: [String: BotJSONValue] = [
                "basis": .string(basis.rawValue),
                "value": .string(value),
            ]
            if let observedAt { object["observed_at_ms"] = .number(Double(observedAt)) }
            if let basisRef { object["basis_ref"] = .string(basisRef) }
            return .object(object)
        case .unknown(let reason, let observedAt, let basisRef):
            var object: [String: BotJSONValue] = ["reason": .string(reason.rawValue)]
            if let observedAt { object["observed_at_ms"] = .number(Double(observedAt)) }
            if let basisRef { object["basis_ref"] = .string(basisRef) }
            return .object(object)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case basis, value, observed_at_ms, basis_ref, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let observedAt = try container.decodeIfPresent(Int64.self, forKey: .observed_at_ms)
        let basisRef = try container.decodeIfPresent(String.self, forKey: .basis_ref)
        if let basis = try container.decodeIfPresent(String.self, forKey: .basis) {
            guard container.allKeys.allSatisfy({
                [.basis, .value, .observed_at_ms, .basis_ref].contains($0)
            }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .basis, in: container,
                    debugDescription: "known sourceVersion has unknown members")
            }
            guard let basisValue = BotContextSourceVersionBasis(rawValue: basis),
                  let value = try container.decodeIfPresent(String.self, forKey: .value),
                  !value.isEmpty, value.unicodeScalars.count <= 256 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "known sourceVersion requires a frozen basis and value")
            }
            try Self.validateBasisRef(basisRef, container: container)
            self = .known(basis: basisValue, value: value,
                          observedAt: observedAt, basisRef: basisRef)
            return
        }
        guard container.allKeys.allSatisfy({ [.reason, .observed_at_ms, .basis_ref].contains($0) }),
              let reason = try container.decodeIfPresent(String.self, forKey: .reason),
              let reasonValue = BotContextSourceVersionUnknownReason(rawValue: reason) else {
            throw DecodingError.dataCorruptedError(
                forKey: .reason, in: container,
                debugDescription: "unknown sourceVersion requires a frozen reason")
        }
        try Self.validateBasisRef(basisRef, container: container)
        self = .unknown(reason: reasonValue, observedAt: observedAt, basisRef: basisRef)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .known(let basis, let value, let observedAt, let basisRef):
            try container.encode(basis.rawValue, forKey: .basis)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(observedAt, forKey: .observed_at_ms)
            try container.encodeIfPresent(basisRef, forKey: .basis_ref)
        case .unknown(let reason, let observedAt, let basisRef):
            try container.encode(reason.rawValue, forKey: .reason)
            try container.encodeIfPresent(observedAt, forKey: .observed_at_ms)
            try container.encodeIfPresent(basisRef, forKey: .basis_ref)
        }
    }

    private static func validateBasisRef(
        _ value: String?, container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard let value else { return }
        let pattern = #"^record://(session/[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$"#
        guard value.unicodeScalars.count <= 128,
              value.range(of: pattern, options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .basis_ref, in: container,
                debugDescription: "basis_ref must be a canonical record reference")
        }
    }
}

public enum BotContextUncertaintyLevel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum BotContextCompleteness: String, Codable, Sendable, CaseIterable {
    case complete
    case partial
}

/// Every native observation carries its own uncertainty. The host supplies it;
/// the model cannot self-report or upgrade it.
public struct BotContextUncertainty: Codable, Sendable, Equatable {
    public var level: BotContextUncertaintyLevel
    public var reason: String?
    public var completeness: BotContextCompleteness

    public init(level: BotContextUncertaintyLevel,
                reason: String? = nil,
                completeness: BotContextCompleteness = .complete) {
        self.level = level
        self.reason = reason.map { String($0.prefix(160)) }
        self.completeness = completeness
    }

    private enum CodingKeys: String, CodingKey { case level, reason, completeness }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decode(BotContextUncertaintyLevel.self, forKey: .level)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        completeness = try container.decode(BotContextCompleteness.self, forKey: .completeness)
        guard reason == nil || !reason!.isEmpty, (reason?.unicodeScalars.count ?? 0) <= 160 else {
            throw DecodingError.dataCorruptedError(
                forKey: .reason, in: container,
                debugDescription: "uncertainty reason must be 1...160 scalars")
        }
    }
}

public enum BotContextObservationDelivery: String, Codable, Sendable, CaseIterable {
    case os
    case injected

    public var isReal: Bool { self == .os }
}

/// One native context observation. It is a fact candidate, not an instruction
/// and not a memory. The durable shape is `bot-context-observation/v1`; `id` is
/// an in-memory buffer identity only and is not stored on the wire.
public struct BotContextObservation: Codable, Sendable, Equatable, Identifiable {
    public static let schema = "bot-context-observation/v1"

    public var id: String
    public var source: BotContextSourceKind
    public var kind: BotContextObservationKind
    public var observedAt: Int64
    public var ownerBotID: String?
    public var sessionID: String?
    public var permissionRevision: Int
    public var sourceVersion: BotContextSourceVersion
    public var uncertainty: BotContextUncertainty
    public var delivery: BotContextObservationDelivery
    public var payload: BotJSONValue
    public var dedupeKey: String
    public var wakeRequested: Bool
    public var recordRef: String?

    public init(id: String,
                source: BotContextSourceKind,
                kind: BotContextObservationKind,
                observedAt: Int64,
                ownerBotID: String? = nil,
                sessionID: String? = nil,
                permissionRevision: Int,
                sourceVersion: BotContextSourceVersion,
                uncertainty: BotContextUncertainty,
                delivery: BotContextObservationDelivery,
                payload: BotJSONValue = .object([:]),
                dedupeKey: String,
                wakeRequested: Bool = false,
                recordRef: String? = nil) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDedupe = dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.unicodeScalars.count <= 200 else {
            throw BotContextSourceError.invalidObservation("id must be 1...200 characters")
        }
        guard !trimmedDedupe.isEmpty, trimmedDedupe.unicodeScalars.count <= 200 else {
            throw BotContextSourceError.invalidObservation("dedupeKey must be 1...200 characters")
        }
        guard kind.isValidFormat else {
            throw BotContextSourceError.invalidObservation("kind does not match the frozen pattern")
        }
        guard observedAt >= 0, permissionRevision >= 0 else {
            throw BotContextSourceError.invalidObservation("time/generation must be non-negative")
        }
        if let ownerBotID {
            guard !ownerBotID.isEmpty, ownerBotID.unicodeScalars.count <= 128 else {
                throw BotContextSourceError.invalidObservation("ownerBotID must be 1...128 characters")
            }
        }
        guard case .object(let object) = payload, object.count <= 32 else {
            throw BotContextSourceError.invalidObservation("payload must be an object with at most 32 members")
        }
        guard BotContextSecretScanner.readsSecret(payload) == false else {
            throw BotContextSourceError.credentialShapeRejected
        }
        if let recordRef {
            let pattern = #"^record://(session/[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$"#
            guard recordRef.unicodeScalars.count <= 128,
                  recordRef.range(of: pattern, options: .regularExpression) != nil else {
                throw BotContextSourceError.invalidObservation("recordRef is not a canonical record reference")
            }
        }
        self.id = trimmedID
        self.source = source
        self.kind = kind
        self.observedAt = observedAt
        self.ownerBotID = ownerBotID
        self.sessionID = sessionID
        self.permissionRevision = permissionRevision
        self.sourceVersion = sourceVersion
        self.uncertainty = uncertainty
        self.delivery = delivery
        self.payload = payload
        self.dedupeKey = trimmedDedupe
        self.wakeRequested = wakeRequested
        self.recordRef = recordRef
    }

    private enum CodingKeys: String, CodingKey {
        case schema, source, kind, observed_at_ms, owner_bot_id, consent_generation
        case source_version, uncertainty, delivery, payload, dedupe_key, wake_requested, record_ref
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.schema else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema, in: container,
                debugDescription: "unexpected context observation schema")
        }
        let dedupe = try container.decode(String.self, forKey: .dedupe_key)
        try self.init(
            id: dedupe,
            source: container.decode(BotContextSourceKind.self, forKey: .source),
            kind: container.decode(BotContextObservationKind.self, forKey: .kind),
            observedAt: container.decode(Int64.self, forKey: .observed_at_ms),
            ownerBotID: container.decodeIfPresent(String.self, forKey: .owner_bot_id),
            permissionRevision: container.decode(Int.self, forKey: .consent_generation),
            sourceVersion: container.decode(BotContextSourceVersion.self, forKey: .source_version),
            uncertainty: container.decode(BotContextUncertainty.self, forKey: .uncertainty),
            delivery: container.decode(BotContextObservationDelivery.self, forKey: .delivery),
            payload: container.decode(BotJSONValue.self, forKey: .payload),
            dedupeKey: dedupe,
            wakeRequested: container.decode(Bool.self, forKey: .wake_requested),
            recordRef: container.decodeIfPresent(String.self, forKey: .record_ref))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(observedAt, forKey: .observed_at_ms)
        try container.encodeIfPresent(ownerBotID, forKey: .owner_bot_id)
        try container.encode(permissionRevision, forKey: .consent_generation)
        try container.encode(sourceVersion, forKey: .source_version)
        try container.encode(uncertainty, forKey: .uncertainty)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(payload, forKey: .payload)
        try container.encode(dedupeKey, forKey: .dedupe_key)
        try container.encode(wakeRequested, forKey: .wake_requested)
        try container.encodeIfPresent(recordRef, forKey: .record_ref)
    }

    /// The exact durable event data object. `ownerBotID` must be host-bound.
    public func eventData(ownerBotID: String) throws -> BotJSONValue {
        guard !ownerBotID.isEmpty, ownerBotID.unicodeScalars.count <= 128 else {
            throw BotContextSourceError.invalidObservation("durable observation requires an owner")
        }
        var object: [String: BotJSONValue] = [
            "schema": .string(Self.schema),
            "source": .string(source.rawValue),
            "kind": .string(kind.rawValue),
            "observed_at_ms": .number(Double(observedAt)),
            "owner_bot_id": .string(ownerBotID),
            "consent_generation": .number(Double(permissionRevision)),
            "source_version": sourceVersion.jsonValue,
            "uncertainty": .object([
                "level": .string(uncertainty.level.rawValue),
                "completeness": .string(uncertainty.completeness.rawValue),
            ]),
            "delivery": .string(delivery.rawValue),
            "payload": payload,
            "dedupe_key": .string(dedupeKey),
            "wake_requested": .bool(wakeRequested),
        ]
        if let reason = uncertainty.reason {
            if case .object(var uncertaintyObject) = object["uncertainty"]! {
                uncertaintyObject["reason"] = .string(reason)
                object["uncertainty"] = .object(uncertaintyObject)
            }
        }
        if let recordRef { object["record_ref"] = .string(recordRef) }
        return .object(object)
    }

    public func bound(to botID: String, sessionID: String? = nil) throws -> BotContextObservation {
        try BotContextObservation(
            id: id, source: source, kind: kind, observedAt: observedAt,
            ownerBotID: botID, sessionID: sessionID ?? self.sessionID,
            permissionRevision: permissionRevision, sourceVersion: sourceVersion,
            uncertainty: uncertainty, delivery: delivery, payload: payload,
            dedupeKey: dedupeKey, wakeRequested: wakeRequested, recordRef: recordRef)
    }

    public var wakeReason: String {
        "context:\(source.rawValue):\(kind.rawValue)"
    }
}

public enum BotContextSourceError: Error, Sendable, Equatable, LocalizedError {
    case notAuthorized(BotContextSourceKind, permissionRevision: Int)
    case revoked(BotContextSourceKind)
    case unsupported(String)
    case unavailable(String)
    case invalidObservation(String)
    case credentialShapeRejected
    case staleCallback
    case invalidRequest(String)
    case notRegistered(BotContextSourceKind)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized(let source, let revision):
            return "context source \(source.rawValue) is not authorized at generation \(revision)"
        case .revoked(let source):
            return "context source \(source.rawValue) was revoked"
        case .unsupported(let reason):
            return "context source is unsupported: \(reason)"
        case .unavailable(let reason):
            return "context source is unavailable: \(reason)"
        case .invalidObservation(let reason):
            return "invalid context observation: \(reason)"
        case .credentialShapeRejected:
            return "context observation contains credential-shaped data"
        case .staleCallback:
            return "context source callback is from a revoked consent generation"
        case .invalidRequest(let reason):
            return "invalid context source request: \(reason)"
        case .notRegistered(let source):
            return "context source \(source.rawValue) is not registered"
        }
    }
}

/// A wake request. It carries identity, time and generation only; the
/// observation payload is read later through the authorized read view/record.
public struct BotContextWake: Codable, Sendable, Equatable {
    public var botID: String
    public var source: BotContextSourceKind
    public var kind: BotContextObservationKind
    public var observationID: String
    public var observedAt: Int64
    public var permissionRevision: Int
    public var dedupeKey: String

    public init(botID: String, source: BotContextSourceKind,
                kind: BotContextObservationKind, observationID: String,
                observedAt: Int64, permissionRevision: Int,
                dedupeKey: String) throws {
        guard !botID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !observationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observedAt >= 0, permissionRevision >= 0,
              !dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BotContextSourceError.invalidRequest(
                "wake requires bot, observation, time, generation and dedupe key")
        }
        self.botID = botID
        self.source = source
        self.kind = kind
        self.observationID = observationID
        self.observedAt = observedAt
        self.permissionRevision = permissionRevision
        self.dedupeKey = dedupeKey
    }

    public var reason: String {
        "context:\(source.rawValue):\(kind.rawValue)"
    }
}

/// Fail-closed credential shape check applied before a payload can be buffered,
/// recorded or handed to another module.
public enum BotContextSecretScanner {
    private static let patterns = [
        #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{14,}\b"#,
        #"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#,
        #"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\s*[:=]\s*[^\s]{4,}"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
    ]

    public static func readsSecret(_ value: BotJSONValue) -> Bool {
        switch value {
        case .string(let text):
            return containsSecret(text)
        case .array(let values):
            return values.contains(where: readsSecret)
        case .object(let object):
            return object.values.contains(where: readsSecret)
        case .number, .bool, .null:
            return false
        }
    }

    public static func containsSecret(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
