// SPDX-License-Identifier: MIT

import Foundation

/// One connector's opaque cursor value.
///
/// The frozen `connector-cursor` schema has two shapes: Gmail's decimal
/// `historyId` string and GitHub's `{since, lastModified}` object. The held
/// `connector-update` interval endpoints use the connector's *advancing*
/// value only (Gmail historyId / GitHub since); GitHub's `lastModified` is a
/// conditional-request token, never an interval endpoint.
public enum ConnectorCursorValue: Sendable, Equatable {
    case gmail(historyId: String)
    case github(since: String, lastModified: String?)

    public var connector: ConnectorKind {
        switch self {
        case .gmail: return .gmail
        case .github: return .github
        }
    }

    /// The held-item `cursorFrom`/`cursorTo` endpoint.
    public var intervalEndpoint: String {
        switch self {
        case .gmail(let historyId): return historyId
        case .github(let since, _): return since
        }
    }
}

/// One durable connector cursor record (contract `connector-cursor.schema.json`).
/// The store is app-global per signed-in account and connector; the record does
/// not repeat the account.
public struct ConnectorCursorState: Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case established
        case reset
    }

    public enum LastError: String, Codable, Sendable, Equatable {
        case cursorInvalid = "cursor-invalid"
        case cursorRegressed = "cursor-regressed"
        case scanFailed = "scan-failed"
    }

    public var version: Int
    public var connector: ConnectorKind
    public var cursor: ConnectorCursorValue
    public var updatedAt: Int64
    public var status: Status
    public var lastError: LastError?

    public init(connector: ConnectorKind, cursor: ConnectorCursorValue,
                updatedAt: Int64, status: Status = .established,
                lastError: LastError? = nil) {
        self.version = 1
        self.connector = connector
        self.cursor = cursor
        self.updatedAt = updatedAt
        self.status = status
        self.lastError = lastError
    }
}

public enum ConnectorCursorError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Strict codec for the frozen cursor document. Every member is checked
/// against the schema (closed objects, required members, patterns, ranges);
/// an unknown version/connector/status/lastError, an extra member, or a cursor
/// whose shape does not match its connector is rejected, never guessed.
public enum ConnectorCursorCodec {
    static let gmailPattern = try! NSRegularExpression(pattern: "^[0-9]{1,20}$")
    static let sincePattern = try! NSRegularExpression(
        pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    static let httpDatePattern = try! NSRegularExpression(
        pattern: "^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$")
    static let maxCursorLength = 512

    private static let topKeys: Set<String> = [
        "version", "connector", "cursor", "updatedAt", "status", "lastError",
    ]
    private static let githubCursorKeys: Set<String> = ["since", "lastModified"]

    public static func isValidHistoryId(_ value: String) -> Bool {
        matches(gmailPattern, value)
    }

    public static func isValidSince(_ value: String) -> Bool {
        matches(sincePattern, value)
    }

    public static func isValidHTTPDate(_ value: String) -> Bool {
        matches(httpDatePattern, value)
    }

    public static func decode(_ data: Data) throws -> ConnectorCursorState {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectorCursorError.invalid("not-json")
        }
        guard let document = object as? [String: Any] else {
            throw ConnectorCursorError.invalid("not-object")
        }
        let keys = Set(document.keys)
        guard keys.isSubset(of: topKeys) else {
            throw ConnectorCursorError.invalid("unknown-member")
        }
        guard let version = integer(document["version"]), version == 1 else {
            throw ConnectorCursorError.invalid("version")
        }
        guard let connectorText = document["connector"] as? String,
              let connector = ConnectorKind(rawValue: connectorText) else {
            throw ConnectorCursorError.invalid("connector")
        }
        guard let cursorObject = document["cursor"] else {
            throw ConnectorCursorError.invalid("cursor")
        }
        let cursor = try decodeValue(cursorObject, connector: connector)
        guard let updatedAt = integer(document["updatedAt"]), updatedAt >= 0 else {
            throw ConnectorCursorError.invalid("updatedAt")
        }
        guard let statusText = document["status"] as? String,
              let status = ConnectorCursorState.Status(rawValue: statusText) else {
            throw ConnectorCursorError.invalid("status")
        }
        var lastError: ConnectorCursorState.LastError?
        if let raw = document["lastError"] {
            guard let text = raw as? String,
                  let parsed = ConnectorCursorState.LastError(rawValue: text) else {
                throw ConnectorCursorError.invalid("lastError")
            }
            lastError = parsed
        }
        return ConnectorCursorState(connector: connector, cursor: cursor,
                                    updatedAt: updatedAt, status: status,
                                    lastError: lastError)
    }

    public static func encode(_ state: ConnectorCursorState) throws -> Data {
        guard state.version == 1 else {
            throw ConnectorCursorError.invalid("version")
        }
        var document: [String: Any] = [
            "version": state.version,
            "connector": state.connector.rawValue,
            "updatedAt": state.updatedAt,
            "status": state.status.rawValue,
        ]
        switch state.cursor {
        case .gmail(let historyId):
            guard state.connector == .gmail, isValidHistoryId(historyId) else {
                throw ConnectorCursorError.invalid("cursor")
            }
            document["cursor"] = historyId
        case .github(let since, let lastModified):
            guard state.connector == .github, isValidSince(since) else {
                throw ConnectorCursorError.invalid("cursor")
            }
            if let lastModified, !isValidHTTPDate(lastModified) {
                throw ConnectorCursorError.invalid("lastModified")
            }
            let cursorObject: [String: Any] = [
                "since": since,
                "lastModified": lastModified.map { $0 as Any } ?? NSNull(),
            ]
            document["cursor"] = cursorObject
        }
        if let lastError = state.lastError {
            document["lastError"] = lastError.rawValue
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// Decodes a bare cursor value (schema `cursor` member) for the connector.
    public static func decodeValue(_ value: Any, connector: ConnectorKind) throws
    -> ConnectorCursorValue {
        switch connector {
        case .gmail:
            guard let historyId = value as? String, isValidHistoryId(historyId) else {
                throw ConnectorCursorError.invalid("gmail-cursor")
            }
            return .gmail(historyId: historyId)
        case .github:
            guard let object = value as? [String: Any],
                  Set(object.keys) == githubCursorKeys else {
                throw ConnectorCursorError.invalid("github-cursor")
            }
            guard let since = object["since"] as? String, isValidSince(since) else {
                throw ConnectorCursorError.invalid("github-since")
            }
            let lastModified: String?
            if object["lastModified"] is NSNull {
                lastModified = nil
            } else if let text = object["lastModified"] as? String,
                      isValidHTTPDate(text) {
                lastModified = text
            } else {
                throw ConnectorCursorError.invalid("github-last-modified")
            }
            return .github(since: since, lastModified: lastModified)
        }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded(.towardZero) == double,
              double >= Double(Int64.min), double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

/// The two cursor outcomes the scanner must tell apart: a valid stored record,
/// no record at all, or a record that cannot be used (corrupt / wrong shape /
/// unknown version). The last case resets to the upstream head silently.
public enum ConnectorCursorLoad: Sendable, Equatable {
    case absent
    case stored(ConnectorCursorState)
    case corrupt
}

/// The pure cursor transition of one scan (contract §3.3.2):
/// - first scan establishes the head only;
/// - Gmail historyId advances / GitHub `since` advances → emit an update;
/// - GitHub `lastModified` alone changes → update the record, emit nothing;
/// - an unusable or regressed cursor resets to the head, emits nothing.
public struct ConnectorScanDecision: Sendable, Equatable {
    public var record: ConnectorCursorState
    public var emitConnectorUpdate: Bool

    public init(record: ConnectorCursorState, emitConnectorUpdate: Bool) {
        self.record = record
        self.emitConnectorUpdate = emitConnectorUpdate
    }
}

public enum ConnectorScanTransition {
    public static func decide(connector: ConnectorKind,
                              stored: ConnectorCursorLoad,
                              head: ConnectorCursorValue,
                              now: Int64) -> ConnectorScanDecision {
        let established = ConnectorCursorState(
            connector: connector, cursor: head, updatedAt: now)
        guard head.connector == connector else {
            return ConnectorScanDecision(
                record: ConnectorCursorState(
                    connector: connector, cursor: head, updatedAt: now,
                    status: .reset, lastError: .cursorInvalid),
                emitConnectorUpdate: false)
        }
        switch stored {
        case .absent:
            return ConnectorScanDecision(record: established, emitConnectorUpdate: false)
        case .corrupt:
            return ConnectorScanDecision(
                record: ConnectorCursorState(
                    connector: connector, cursor: head, updatedAt: now,
                    status: .reset, lastError: .cursorInvalid),
                emitConnectorUpdate: false)
        case .stored(let previous):
            guard previous.connector == connector else {
                return ConnectorScanDecision(
                    record: ConnectorCursorState(
                        connector: connector, cursor: head, updatedAt: now,
                        status: .reset, lastError: .cursorInvalid),
                    emitConnectorUpdate: false)
            }
            switch (previous.cursor, head) {
            case (.gmail(let old), .gmail(let new)):
                guard let oldValue = UInt64(old), let newValue = UInt64(new) else {
                    return reset(head: head, now: now, connector: connector,
                                 error: .cursorInvalid)
                }
                if newValue < oldValue {
                    return reset(head: head, now: now, connector: connector,
                                 error: .cursorRegressed)
                }
                return ConnectorScanDecision(record: established,
                                             emitConnectorUpdate: newValue > oldValue)
            case (.github(let oldSince, _), .github(let newSince, _)):
                if newSince < oldSince {
                    return reset(head: head, now: now, connector: connector,
                                 error: .cursorRegressed)
                }
                return ConnectorScanDecision(record: established,
                                             emitConnectorUpdate: newSince > oldSince)
            default:
                return reset(head: head, now: now, connector: connector,
                             error: .cursorInvalid)
            }
        }
    }

    private static func reset(head: ConnectorCursorValue, now: Int64,
                              connector: ConnectorKind,
                              error: ConnectorCursorState.LastError) -> ConnectorScanDecision {
        ConnectorScanDecision(
            record: ConnectorCursorState(
                connector: connector, cursor: head, updatedAt: now,
                status: .reset, lastError: error),
            emitConnectorUpdate: false)
    }
}
