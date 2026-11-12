// SPDX-License-Identifier: MIT
import Foundation
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
    /// The device returned a completed reply (its raw `status: completed` object).
    case completed(requestID: UUID, reply: JSONValue)
    /// The device is still running this request; query again, never replay.
    case running(requestID: UUID)
    /// The board refused upload/commit before running anything (rule 7).
    case notExecuted(requestID: UUID, stage: String, status: String)
    /// The outcome is unknown; only a query may follow (rule 1/2).
    case outcomeUnknown(requestID: UUID, message: String)
}

/// Admission rejection: another Link operation already owns this device.
/// Thrown *before* the journal intent is written, so the caller has no request
/// UUID and may retry with a new call (device-panel.md §3, ble-link.md
/// 「Link 调用准入」 rule 1).
public struct LinkBusy: Error, Equatable, Sendable {
    public init() {}
}

/// INTERFACE SKELETON frozen by the coordinator for parallel work (WP2 owns the
/// implementation). The only path from the panel and from `DeviceMCPServer` to
/// a Link tool: admission (busy first, before any journal write) → authorization
/// → durable intent → invoke/query.
@discardableResult
public func callLinkTool(
    deviceID: UUID,
    name: String,
    arguments: JSONValue,
    idempotencyKey: String,
    origin: LinkCallOrigin
) async throws -> LinkCallOutcome {
    fatalError("WP2: LinkToolCaller.swift callLinkTool not implemented")
}

/// Result query through the same admission point. The journal decides which
/// request UUIDs this host may ask about.
@discardableResult
public func queryLinkTool(
    deviceID: UUID,
    requestID: UUID,
    origin: LinkCallOrigin
) async throws -> LinkCallOutcome {
    fatalError("WP2: LinkToolCaller.swift queryLinkTool not implemented")
}
