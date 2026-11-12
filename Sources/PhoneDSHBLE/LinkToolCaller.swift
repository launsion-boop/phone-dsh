// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import PhoneDSHAgentCore

/// Who asked for this Link call. It only affects host-side display and logs;
/// it is not part of the Link wire or the journal on-disk format
/// (ble-link.md「Link 调用准入」, device-panel.md §3).
public enum LinkCallOrigin: Equatable, Sendable {
    case agent
    case user
}

/// The single terminal result of one admitted Link call or result query.
public enum LinkCallOutcome: Equatable, Sendable {
    /// The device returned a terminal reply: its raw
    /// `status: completed` / `failed` / `outcome_unknown` object.
    case completed(requestID: UUID, reply: JSONValue)
    /// The device is still running this request; query again, never replay.
    case running(requestID: UUID)
    /// The board refused upload/commit before running anything (rule 7).
    case notExecuted(requestID: UUID, stage: String, status: String)
    /// The call could not reach a terminal reply. Only a query may follow
    /// (rule 1/2); the message is the transport error, never a replay.
    case outcomeUnknown(requestID: UUID, message: String)
}

/// Admission rejection: another Link operation already owns this device.
/// Thrown *before* the journal intent is written, so the caller has no request
/// UUID and may retry with a new call (device-panel.md §3, ble-link.md
/// 「Link 调用准入」 rule 1).
public struct LinkBusy: Error, Equatable, Sendable {
    public init() {}
}

/// Where the app keeps the Link journal. The MCP server and the device panel
/// must use this one directory: `DeviceMCPServer.receiptDirectory` defaults to
/// the same Application Support root, and tests inject their own root instead.
enum LinkToolStorage {
    static var defaultReceiptDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ble-alert-receipts", isDirectory: true)
    }
    static var defaultJournal: LinkToolJournal {
        LinkToolJournal(directory: defaultReceiptDirectory.appendingPathComponent("link-intents", isDirectory: true))
    }
}

/// The only path from the device panel to a Link tool: admission (busy first,
/// before any journal write) → authorization → durable intent → invoke/query.
/// `DeviceMCPServer.ble_link_call` uses the same function; nothing may call
/// `BLEDeviceStore.invokeLink` on behalf of the panel or the Agent.
@discardableResult
public func callLinkTool(
    deviceID: UUID,
    name: String,
    arguments: JSONValue,
    idempotencyKey: String,
    origin: LinkCallOrigin
) async throws -> LinkCallOutcome {
    let store = await MainActor.run { BLEDeviceStore.shared }
    return try await callLinkTool(
        deviceID: deviceID, name: name, arguments: arguments,
        idempotencyKey: idempotencyKey, origin: origin,
        store: store, journal: LinkToolStorage.defaultJournal)
}

/// Isolated variant for `DeviceMCPServer` (which may be handed its own receipts
/// and store in tests). Shares the exact admission/journal sequence above.
@discardableResult
func callLinkTool(
    deviceID: UUID,
    name: String,
    arguments: JSONValue,
    idempotencyKey: String,
    origin: LinkCallOrigin,
    store: BLEDeviceStore,
    journal: LinkToolJournal
) async throws -> LinkCallOutcome {
    try await withLinkAdmission(store, deviceID) { admission in
        // Authorization still precedes the durable intent (ble-link.md rule 1/6).
        try await store.authorizeLink(deviceID, name: name, arguments: arguments)
        // Persist key/device/name/fingerprint/request UUID before uploading.
        let (intent, fresh) = try journal.prepare(
            key: idempotencyKey, deviceID: deviceID, name: name, arguments: arguments)
        let reply: JSONValue?
        do {
            if fresh {
                let wireKey = SHA256.hash(data: Data(idempotencyKey.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                reply = try await store.invokeAdmittedLink(
                    admission, requestID: intent.requestID, name: name,
                    arguments: arguments, key: wireKey)
            } else {
                // A repeated key only queries its recorded request; it never re-uploads.
                reply = try await store.queryAdmittedLink(admission, requestID: intent.requestID)
            }
        } catch let refused as LinkNotExecuted {
            return .notExecuted(
                requestID: intent.requestID, stage: refused.stage, status: refused.statusName)
        } catch {
            return .outcomeUnknown(
                requestID: intent.requestID, message: error.localizedDescription)
        }
        guard let reply else { return .running(requestID: intent.requestID) }
        return .completed(requestID: intent.requestID, reply: reply)
    }
}

/// Result query through the same admission point. The journal decides which
/// request UUIDs this host may ask about.
@discardableResult
public func queryLinkTool(
    deviceID: UUID,
    requestID: UUID,
    origin: LinkCallOrigin
) async throws -> LinkCallOutcome {
    let store = await MainActor.run { BLEDeviceStore.shared }
    return try await queryLinkTool(
        deviceID: deviceID, requestID: requestID, origin: origin,
        store: store, journal: LinkToolStorage.defaultJournal)
}

/// Isolated variant for `DeviceMCPServer` (see `callLinkTool` above).
@discardableResult
func queryLinkTool(
    deviceID: UUID,
    requestID: UUID,
    origin: LinkCallOrigin,
    store: BLEDeviceStore,
    journal: LinkToolJournal
) async throws -> LinkCallOutcome {
    try await withLinkAdmission(store, deviceID) { admission in
        // Rule 4: only this host's journal records for this device are queryable.
        // Unknown records and revoked grants throw their existing errors.
        let intent = try journal.find(deviceID: deviceID, requestID: requestID)
        try await store.authorizeLink(deviceID, name: intent.name, arguments: nil)
        let reply: JSONValue?
        do {
            reply = try await store.queryAdmittedLink(admission, requestID: requestID)
        } catch {
            return .outcomeUnknown(requestID: requestID, message: error.localizedDescription)
        }
        guard let reply else { return .running(requestID: requestID) }
        return .completed(requestID: requestID, reply: reply)
    }
}

/// Reserves the device slot atomically before anything durable happens and
/// releases it on every exit, including cancellation of the caller.
private func withLinkAdmission<T>(
    _ store: BLEDeviceStore,
    _ deviceID: UUID,
    _ body: (LinkAdmission) async throws -> T
) async throws -> T {
    let admission = try await store.admitLink(deviceID)
    do {
        let value = try await body(admission)
        await store.releaseLink(admission)
        return value
    } catch {
        await store.releaseLink(admission)
        throw error
    }
}
