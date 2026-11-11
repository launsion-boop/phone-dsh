// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// A read-only held-inbox notice describing the terminal result of a device
/// task. The goal and result are device/model data: `WakeInboxItem` only
/// carries them into the next main turn, and this type never grants a tool or
/// a reply path back to the device.
///
/// `PhoneDSHBot` deliberately does not depend on `PhoneDSHDeviceTasks`; the App
/// maps a `DeviceTaskSettlement` into this value at the composition boundary.
public struct DeviceTaskResultNotice: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable, CaseIterable {
        case completed
        case denied
        case unavailable
        case expired
        case failed
        case unknownOutcome = "unknown_outcome"
    }

    public static let kind = "device-task-result"

    public let deviceID: String
    public let deviceDisplayName: String
    public let taskID: String
    public let idempotencyKey: String
    public let goal: String
    public let status: Status
    public let result: String
    public let createdAt: Int64

    public init(deviceID: String, deviceDisplayName: String, taskID: String,
                idempotencyKey: String, goal: String, status: Status,
                result: String, createdAt: Int64) {
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.taskID = taskID
        self.idempotencyKey = idempotencyKey
        self.goal = goal
        self.status = status
        self.result = result
        self.createdAt = createdAt
    }

    /// Lowercase SHA-256 of UTF-8 device ID, one NUL byte, then UTF-8
    /// idempotency key. It is the stable identity of one task's result.
    public var digest: String {
        var data = Data(deviceID.utf8)
        data.append(0)
        data.append(contentsOf: idempotencyKey.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var itemID: String { Self.kind + "-" + digest }
    public var requestID: String { "device-task:" + digest }

    public var title: String { String(deviceDisplayName.prefix(80)) }

    /// Goal summary and result. The final character cap also covers a caller
    /// that supplies an oversized result directly; the journal already bounds
    /// normal completed/failed text.
    public var text: String {
        let goalSummary = String(goal.prefix(120))
        let raw = "Goal: \(goalSummary)\nResult: \(result)"
        return String(raw.prefix(1200))
    }

    public func wakeInboxItem() throws -> WakeInboxItem {
        try WakeInboxItem(id: itemID, kind: Self.kind, title: title, text: text,
                          requestId: requestID, createdAt: createdAt,
                          taskId: taskID, status: status.rawValue)
    }
}
